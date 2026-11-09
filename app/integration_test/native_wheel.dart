// Native Windows wheel input into THIS test window only. No external
// executable, focus guessing or interaction with the user's other windows.
import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

typedef _EnumCallback = Int32 Function(IntPtr, IntPtr);

final class _Point extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

class NativeWheel {
  final _user = DynamicLibrary.open('user32.dll');
  final _kernel = DynamicLibrary.open('kernel32.dll');
  late final _windowPid = _user
      .lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetWindowThreadProcessId');
  late final _visible = _user
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'IsWindowVisible',
      );
  late final _enumerate = _user
      .lookupFunction<
        Int32 Function(Pointer<NativeFunction<_EnumCallback>>, IntPtr),
        int Function(Pointer<NativeFunction<_EnumCallback>>, int)
      >('EnumWindows');
  late final _foreground = _user
      .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
  late final _setForeground = _user
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'SetForegroundWindow',
      );
  late final _key = _user
      .lookupFunction<
        Void Function(Uint8, Uint8, Uint32, IntPtr),
        void Function(int, int, int, int)
      >('keybd_event');
  late final _clientToScreen = _user
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<_Point>),
        int Function(int, Pointer<_Point>)
      >('ClientToScreen');
  late final _position = _user
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'SetCursorPos',
      );
  late final _mouse = _user
      .lookupFunction<
        Void Function(Uint32, Uint32, Uint32, Uint32, IntPtr),
        void Function(int, int, int, int, int)
      >('mouse_event');
  late final _allocate = _kernel
      .lookupFunction<
        Pointer<Void> Function(Uint32, IntPtr),
        Pointer<Void> Function(int, int)
      >('LocalAlloc');
  late final _free = _kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  late final int window = _findWindow();

  int _findWindow() {
    final process = _allocate(0x40, sizeOf<Uint32>()).cast<Uint32>();
    var found = 0;
    final callback = NativeCallable<_EnumCallback>.isolateLocal((int h, int _) {
      _windowPid(h, process);
      if (process.value == pid && _visible(h) != 0) {
        found = h;
        return 0;
      }
      return 1;
    }, exceptionalReturn: 0);
    try {
      _enumerate(callback.nativeFunction, 0);
    } finally {
      callback.close();
      _free(process.cast());
    }
    if (found == 0) throw StateError('the test process has no visible window');
    return found;
  }

  void focus() {
    // Windows will not grant foreground activation to an otherwise idle
    // background test process. An Alt key pair permits activation, as in the
    // existing real-keyboard test. No text is ever typed into another window.
    if (_foreground() == window) return;
    _key(0x12, 0, 0, 0);
    _key(0x12, 0, 2, 0);
    _setForeground(window);
  }

  void send(Offset logical, double dpr, {required bool up}) {
    if (_foreground() != window) {
      throw StateError('test window lost focus; native input refused');
    }
    final p = _allocate(0x40, sizeOf<_Point>()).cast<_Point>();
    try {
      p.ref.x = (logical.dx * dpr).round();
      p.ref.y = (logical.dy * dpr).round();
      if (_clientToScreen(window, p) == 0 || _position(p.ref.x, p.ref.y) == 0) {
        throw StateError('cannot place test pointer');
      }
      _mouse(0x0800, 0, 0, (up ? 120 : -120).toUnsigned(32), 0);
    } finally {
      _free(p.cast());
    }
  }
}
