import 'dart:ffi';
import 'dart:io';

typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

/// Small libc allocator used to keep this FFI layer dependency-free.
final class NativeMemory {
  NativeMemory._()
    : _library = Platform.isAndroid
          ? DynamicLibrary.open('libc.so')
          : DynamicLibrary.process() {
    _malloc = _library.lookupFunction<_MallocNative, _MallocDart>('malloc');
    _free = _library.lookupFunction<_FreeNative, _FreeDart>('free');
  }

  static final NativeMemory instance = NativeMemory._();

  final DynamicLibrary _library;
  late final _MallocDart _malloc;
  late final _FreeDart _free;

  Pointer<T> allocate<T extends NativeType>(int byteCount, {bool zero = true}) {
    if (byteCount <= 0) {
      throw RangeError.value(byteCount, 'byteCount', 'must be positive');
    }
    final pointer = _malloc(byteCount);
    if (pointer == nullptr) {
      throw StateError('native allocation of $byteCount bytes failed');
    }
    if (zero) {
      pointer.cast<Uint8>().asTypedList(byteCount).fillRange(0, byteCount, 0);
    }
    return pointer.cast<T>();
  }

  void free(Pointer pointer) {
    if (pointer != nullptr) {
      _free(pointer.cast<Void>());
    }
  }
}
