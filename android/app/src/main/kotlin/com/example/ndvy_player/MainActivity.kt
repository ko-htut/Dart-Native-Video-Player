package com.example.ndvy_player

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.util.ArrayDeque
import kotlin.math.max

class MainActivity : FlutterActivity() {
    private var hardwareVideoChannel: MethodChannel? = null
    private var hardwareVideo: H264TextureDecoder? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            H264TextureDecoder.CHANNEL_NAME,
        )
        val decoder = H264TextureDecoder(flutterEngine.renderer, channel)
        hardwareVideoChannel = channel
        hardwareVideo = decoder
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(decoder.isSupported())
                "getCapabilities" -> result.success(decoder.capabilities())
                "configure" -> configureDecoder(decoder, call, result)
                "queueAccessUnit" -> queueAccessUnit(decoder, call, result)
                "setClock" -> {
                    val mediaTimeUs = call.argument<Number>("mediaTimeUs")?.toLong()
                    val playing = call.argument<Boolean>("playing")
                    if (mediaTimeUs == null || playing == null) {
                        result.error("bad-arguments", "Missing playback clock", null)
                    } else {
                        decoder.setClock(mediaTimeUs, playing)
                        result.success(null)
                    }
                }
                "flush" -> decoder.flush(result)
                "dispose" -> decoder.dispose(result)
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        hardwareVideoChannel?.setMethodCallHandler(null)
        hardwareVideoChannel = null
        hardwareVideo?.dispose(null)
        hardwareVideo = null
        super.onDestroy()
    }

    private fun configureDecoder(
        decoder: H264TextureDecoder,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        val codedWidth = call.argument<Int>("codedWidth")
        val codedHeight = call.argument<Int>("codedHeight")
        val sps = call.argument<ByteArray>("sps")
        val pps = call.argument<ByteArray>("pps")
        if (
            width == null || height == null || codedWidth == null ||
            codedHeight == null || sps == null || pps == null
        ) {
            result.error("bad-arguments", "Incomplete MediaCodec configuration", null)
            return
        }
        decoder.configure(width, height, codedWidth, codedHeight, sps, pps, result)
    }

    private fun queueAccessUnit(
        decoder: H264TextureDecoder,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val data = call.argument<ByteArray>("data")
        val ptsUs = call.argument<Number>("presentationTimeUs")?.toLong()
        val clockUs = call.argument<Number>("clockMediaTimeUs")?.toLong()
        val playing = call.argument<Boolean>("playing")
        if (data == null || ptsUs == null || clockUs == null || playing == null) {
            result.error("bad-arguments", "Incomplete H.264 access unit", null)
            return
        }
        decoder.queueAccessUnit(data, ptsUs, clockUs, playing, result)
    }
}

private class H264TextureDecoder(
    private val textures: TextureRegistry,
    private val channel: MethodChannel,
) {
    companion object {
        const val CHANNEL_NAME = "ndvy_player/h264_hardware"
        private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val MAX_PENDING_ACCESS_UNITS = 120
        private const val FRAME_EVENT_INTERVAL_NS = 200_000_000L
    }

    private data class PendingInput(
        val bytes: ByteArray,
        val presentationTimeUs: Long,
    )

    private data class HeldOutput(
        val index: Int,
        val presentationTimeUs: Long,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val codecThread = HandlerThread("ndvy-mediacodec").apply { start() }
    private val codecHandler = Handler(codecThread.looper)
    private val pendingInputs = ArrayDeque<PendingInput>()
    private val availableInputIndices = ArrayDeque<Int>()
    private val heldOutputs = ArrayDeque<HeldOutput>()

    private var producer: TextureRegistry.SurfaceProducer? = null
    private var codec: MediaCodec? = null
    private var decoderName = "MediaCodec"
    private var displayWidth = 0
    private var displayHeight = 0
    private var clockMediaTimeUs = 0L
    private var clockSystemTimeNs = 0L
    private var playing = false
    private var disposed = false
    private var lastFrameEventNs = Long.MIN_VALUE

    fun isSupported(): Boolean = capabilities()["supported"] == true

    fun capabilities(): Map<String, Any> = try {
        val codecInfo = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .firstOrNull { info ->
                !info.isEncoder && info.supportedTypes.any { type ->
                    type.equals(MIME, ignoreCase = true)
                }
            }
        if (codecInfo == null) {
            mapOf("supported" to false)
        } else {
            val video = codecInfo.getCapabilitiesForType(MIME).videoCapabilities
            val hardwareAccelerated = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                codecInfo.isHardwareAccelerated
            } else {
                val normalized = codecInfo.name.lowercase()
                !normalized.startsWith("omx.google.") &&
                    !normalized.startsWith("c2.android.")
            }
            mapOf(
                "supported" to true,
                "hardwareAccelerated" to hardwareAccelerated,
                "decoderName" to codecInfo.name,
                "maximumWidth" to video.supportedWidths.upper,
                "maximumHeight" to video.supportedHeights.upper,
                "maximumFrameRate" to video.supportedFrameRates.upper,
                "maximumBitrate" to video.bitrateRange.upper,
            )
        }
    } catch (_: Throwable) {
        mapOf("supported" to false)
    }

    fun configure(
        width: Int,
        height: Int,
        codedWidth: Int,
        codedHeight: Int,
        sps: ByteArray,
        pps: ByteArray,
        result: MethodChannel.Result,
    ) {
        if (
            width <= 0 || height <= 0 || codedWidth < width || codedHeight < height ||
            width > 4096 || height > 4096
        ) {
            result.error("bad-geometry", "Invalid H.264 geometry", null)
            return
        }
        if (disposed) {
            result.error("disposed", "Hardware decoder is disposed", null)
            return
        }

        val surfaceProducer = producer ?: textures.createSurfaceProducer().also {
            producer = it
        }
        surfaceProducer.setSize(width, height)
        val textureId = surfaceProducer.id()
        codecHandler.post {
            try {
                releaseCodec()
                displayWidth = width
                displayHeight = height
                val mediaFormat = MediaFormat.createVideoFormat(MIME, codedWidth, codedHeight)
                mediaFormat.setInteger(
                    MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
                )
                mediaFormat.setByteBuffer("csd-0", codecSpecificData(sps))
                mediaFormat.setByteBuffer("csd-1", codecSpecificData(pps))

                val candidate = MediaCodec.createDecoderByType(MIME)
                decoderName = candidate.name
                candidate.setCallback(codecCallback, codecHandler)
                candidate.setOnFrameRenderedListener(frameRenderedListener, codecHandler)
                candidate.configure(mediaFormat, surfaceProducer.surface, null, 0)
                candidate.start()
                codec = candidate
                postResult {
                    result.success(
                        mapOf(
                            "textureId" to textureId,
                            "width" to displayWidth,
                            "height" to displayHeight,
                            "decoderName" to decoderName,
                        ),
                    )
                }
            } catch (error: Throwable) {
                releaseCodec()
                postResult {
                    result.error("configure-failed", error.message, error.stackTraceToString())
                }
            }
        }
    }

    fun queueAccessUnit(
        data: ByteArray,
        presentationTimeUs: Long,
        mediaClockUs: Long,
        isPlaying: Boolean,
        result: MethodChannel.Result,
    ) {
        if (data.isEmpty()) {
            result.error("empty-access-unit", "H.264 access unit is empty", null)
            return
        }
        codecHandler.post {
            if (disposed) {
                postResult { result.error("disposed", "Hardware decoder is disposed", null) }
                return@post
            }
            if (codec == null) {
                postResult { result.error("not-configured", "MediaCodec is not configured", null) }
                return@post
            }
            if (pendingInputs.size >= MAX_PENDING_ACCESS_UNITS) {
                postResult {
                    result.error("input-backpressure", "MediaCodec input queue is full", null)
                }
                return@post
            }
            updateClock(mediaClockUs, isPlaying)
            pendingInputs.addLast(PendingInput(data, presentationTimeUs))
            drainInputs()
            postResult { result.success(null) }
        }
    }

    fun setClock(mediaTimeUs: Long, isPlaying: Boolean) {
        codecHandler.post { updateClock(mediaTimeUs, isPlaying) }
    }

    fun flush(result: MethodChannel.Result?) {
        codecHandler.post {
            try {
                pendingInputs.clear()
                availableInputIndices.clear()
                heldOutputs.clear()
                codec?.flush()
                codec?.start()
                postResult { result?.success(null) }
            } catch (error: Throwable) {
                notifyError(error)
                postResult {
                    result?.error("flush-failed", error.message, error.stackTraceToString())
                }
            }
        }
    }

    fun dispose(result: MethodChannel.Result?) {
        if (disposed) {
            result?.success(null)
            return
        }
        disposed = true
        codecHandler.post {
            releaseCodec()
            postResult {
                producer?.release()
                producer = null
                result?.success(null)
                codecThread.quitSafely()
            }
        }
    }

    private val codecCallback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
            availableInputIndices.addLast(index)
            drainInputs()
        }

        override fun onOutputBufferAvailable(
            codec: MediaCodec,
            index: Int,
            info: MediaCodec.BufferInfo,
        ) {
            if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0 || info.size == 0) {
                codec.releaseOutputBuffer(index, false)
                return
            }
            val output = HeldOutput(index, info.presentationTimeUs)
            if (!playing && output.presentationTimeUs > clockMediaTimeUs) {
                heldOutputs.addLast(output)
            } else {
                scheduleOutput(output)
            }
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
            val codedWidth = format.getInteger(MediaFormat.KEY_WIDTH)
            val codedHeight = format.getInteger(MediaFormat.KEY_HEIGHT)
            val cropLeft = integerOr(format, MediaFormat.KEY_CROP_LEFT, 0)
            val cropRight = integerOr(format, MediaFormat.KEY_CROP_RIGHT, codedWidth - 1)
            val cropTop = integerOr(format, MediaFormat.KEY_CROP_TOP, 0)
            val cropBottom = integerOr(format, MediaFormat.KEY_CROP_BOTTOM, codedHeight - 1)
            displayWidth = max(1, cropRight - cropLeft + 1)
            displayHeight = max(1, cropBottom - cropTop + 1)
            mainHandler.post { producer?.setSize(displayWidth, displayHeight) }
        }

        override fun onError(codec: MediaCodec, exception: MediaCodec.CodecException) {
            notifyError(exception)
        }
    }

    private val frameRenderedListener = MediaCodec.OnFrameRenderedListener {
            _, presentationTimeUs, nanoTime ->
        if (
            lastFrameEventNs == Long.MIN_VALUE ||
            nanoTime - lastFrameEventNs >= FRAME_EVENT_INTERVAL_NS
        ) {
            lastFrameEventNs = nanoTime
            mainHandler.post {
                channel.invokeMethod(
                    "frameRendered",
                    mapOf(
                        "presentationTimeUs" to presentationTimeUs,
                        "width" to displayWidth,
                        "height" to displayHeight,
                    ),
                )
            }
        }
    }

    private fun drainInputs() {
        val activeCodec = codec ?: return
        while (availableInputIndices.isNotEmpty() && pendingInputs.isNotEmpty()) {
            val index = availableInputIndices.removeFirst()
            val input = pendingInputs.removeFirst()
            try {
                val buffer = activeCodec.getInputBuffer(index)
                    ?: throw IllegalStateException("MediaCodec input buffer is unavailable")
                buffer.clear()
                if (buffer.remaining() < input.bytes.size) {
                    throw IllegalArgumentException(
                        "H.264 access unit ${input.bytes.size} exceeds codec input " +
                            "capacity ${buffer.remaining()}",
                    )
                }
                buffer.put(input.bytes)
                activeCodec.queueInputBuffer(
                    index,
                    0,
                    input.bytes.size,
                    input.presentationTimeUs,
                    0,
                )
            } catch (error: Throwable) {
                notifyError(error)
                return
            }
        }
    }

    private fun updateClock(mediaTimeUs: Long, isPlaying: Boolean) {
        clockMediaTimeUs = mediaTimeUs
        clockSystemTimeNs = System.nanoTime()
        playing = isPlaying
        if (isPlaying) {
            while (heldOutputs.isNotEmpty()) scheduleOutput(heldOutputs.removeFirst())
        } else {
            while (
                heldOutputs.isNotEmpty() &&
                heldOutputs.first.presentationTimeUs <= mediaTimeUs
            ) {
                scheduleOutput(heldOutputs.removeFirst())
            }
        }
    }

    private fun scheduleOutput(output: HeldOutput) {
        val activeCodec = codec ?: return
        try {
            val nowNs = System.nanoTime()
            val targetNs = if (playing) {
                max(
                    nowNs,
                    clockSystemTimeNs +
                        (output.presentationTimeUs - clockMediaTimeUs) * 1_000L,
                )
            } else {
                nowNs
            }
            activeCodec.releaseOutputBuffer(output.index, targetNs)
        } catch (error: Throwable) {
            notifyError(error)
        }
    }

    private fun releaseCodec() {
        pendingInputs.clear()
        availableInputIndices.clear()
        heldOutputs.clear()
        lastFrameEventNs = Long.MIN_VALUE
        val activeCodec = codec
        codec = null
        if (activeCodec != null) {
            try {
                activeCodec.stop()
            } catch (_: Throwable) {
                // A codec error may already have moved it out of Executing.
            }
            try {
                activeCodec.release()
            } catch (_: Throwable) {
                // Release is best effort during Activity or rendition teardown.
            }
        }
    }

    private fun notifyError(error: Throwable) {
        mainHandler.post {
            channel.invokeMethod(
                "decoderError",
                mapOf("message" to (error.message ?: error.javaClass.simpleName)),
            )
        }
    }

    private fun postResult(callback: () -> Unit) {
        mainHandler.post(callback)
    }

    private fun codecSpecificData(nal: ByteArray): ByteBuffer {
        val data = ByteArray(nal.size + 4)
        data[3] = 1
        nal.copyInto(data, destinationOffset = 4)
        return ByteBuffer.wrap(data)
    }

    private fun integerOr(format: MediaFormat, key: String, fallback: Int): Int =
        if (format.containsKey(key)) format.getInteger(key) else fallback
}
