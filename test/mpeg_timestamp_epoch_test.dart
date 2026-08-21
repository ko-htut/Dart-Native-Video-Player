import 'package:flutter_test/flutter_test.dart';
import 'package:ndvy_player/src/mpeg_timestamp_epoch.dart';

void main() {
  test('ordinary timestamps retain exact values across 33-bit rollover', () {
    final timeline = MpegTimestampEpochRebaser();

    expect(
      timeline.rebase(mpegTimestampModulus - 1800),
      mpegTimestampModulus - 1800,
    );
    expect(timeline.rebase(1800), mpegTimestampModulus + 1800);
  });

  test('new epoch uses the later EXTINF schedule and emitted cadence', () {
    final timeline = MpegTimestampEpochRebaser();
    timeline.noteEmitted(timeline.rebase(90000));
    timeline.noteEmitted(timeline.rebase(93600));

    final epoch = timeline.beginEpoch(
      discontinuitySequence: 8,
      elapsedDuration90k: 180000,
    );

    expect(epoch.scheduledStart90k, 270000);
    expect(epoch.cadenceFloor90k, 97200);
    expect(epoch.timelineStart90k, 270000);
    expect(timeline.rebase(0), 270000);
    expect(timeline.rebase(3600), 273600);
    expect(epoch.sourceStart90k, 0);
  });

  test('cadence floor prevents a short declared schedule from regressing', () {
    final timeline = MpegTimestampEpochRebaser();
    timeline.noteEmitted(timeline.rebase(10000));
    timeline.noteEmitted(timeline.rebase(13600));

    final epoch = timeline.beginEpoch(
      discontinuitySequence: 1,
      elapsedDuration90k: 1,
    );

    expect(epoch.scheduledStart90k, 10001);
    expect(epoch.cadenceFloor90k, 17200);
    expect(epoch.timelineStart90k, 17200);
    expect(timeline.rebase(0), 17200);
  });

  test('shared video epoch retains AAC offset after a timestamp reset', () {
    final video = MpegTimestampEpochRebaser();
    final audio = MpegTimestampEpochRebaser();
    video.noteEmitted(video.rebase(90000));
    video.noteEmitted(video.rebase(93600));
    audio.noteEmitted(audio.rebase(90900));
    audio.noteEmitted(audio.rebase(94500));

    final epoch = video.beginEpoch(
      discontinuitySequence: 4,
      elapsedDuration90k: 90000,
    );
    final firstVideo = video.rebase(50);
    audio.beginEpoch(discontinuitySequence: 4, sharedEpoch: epoch);
    final firstAudio = audio.rebase(950);

    expect(firstVideo, 180000);
    expect(firstAudio, 180900);
    expect(firstAudio - firstVideo, 900);
    expect(epoch.snapshot.sourceStart90k, 50);
  });

  test('rollover inside a rebased epoch remains continuous', () {
    final timeline = MpegTimestampEpochRebaser();
    timeline.noteEmitted(timeline.rebase(1000));
    final epoch = timeline.beginEpoch(
      discontinuitySequence: 2,
      elapsedDuration90k: 90000,
    );

    expect(timeline.rebase(mpegTimestampModulus - 1000), 91000);
    expect(epoch.sourceStart90k, mpegTimestampModulus - 1000);
    expect(timeline.rebase(1000), 93000);
  });
}
