// Exercises WM_SIZE on this integration-test process, not a production window.
import 'dart:ffi' hide Size;
import 'dart:ui';

import 'native_wheel.dart';

final class _Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

class NativeTestWindow {
  final int handle = NativeWheel().window;
  final _user = DynamicLibrary.open('user32.dll');
  final _kernel = DynamicLibrary.open('kernel32.dll');
  late final _rect = _user
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<_Rect>),
        int Function(int, Pointer<_Rect>)
      >('GetWindowRect');
  late final _position = _user
      .lookupFunction<
        Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int)
      >('SetWindowPos');
  late final _alloc = _kernel
      .lookupFunction<
        Pointer<Void> Function(Uint32, IntPtr),
        Pointer<Void> Function(int, int)
      >('LocalAlloc');
  late final _free = _kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  late final Rect original = bounds;

  Rect get bounds {
    final pointer = _alloc(0x40, sizeOf<_Rect>()).cast<_Rect>();
    try {
      if (_rect(handle, pointer) == 0) {
        throw StateError('test window bounds unavailable');
      }
      final r = pointer.ref;
      return Rect.fromLTRB(
        r.left.toDouble(),
        r.top.toDouble(),
        r.right.toDouble(),
        r.bottom.toDouble(),
      );
    } finally {
      _free(pointer.cast());
    }
  }

  void resize(Size size) {
    final previous = original;
    // Do not activate, reorder or move the window; asynchronous on its UI thread.
    if (_position(
          handle,
          0,
          previous.left.round(),
          previous.top.round(),
          size.width.round(),
          size.height.round(),
          0x4000 | 0x0010 | 0x0004 | 0x0002,
        ) ==
        0) {
      throw StateError('test window resize failed');
    }
  }

  void restore() => resize(original.size);
}
