// Windows DPAPI (CryptProtectData) for the current user, as v2's
// internal/client/dpapi_windows.go, with optional entropy added so a blob
// sealed by another program for the same user (v2 included) does not open.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'sealer.dart';

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptNative = Int32 Function(Pointer<_DataBlob> dataIn, Pointer<Utf16> descr, Pointer<_DataBlob> entropy,
    Pointer<Void> reserved, Pointer<Void> prompt, Uint32 flags, Pointer<_DataBlob> dataOut);
typedef _CryptDart = int Function(Pointer<_DataBlob> dataIn, Pointer<Utf16> descr, Pointer<_DataBlob> entropy,
    Pointer<Void> reserved, Pointer<Void> prompt, int flags, Pointer<_DataBlob> dataOut);

// CryptUnprotectData takes `LPWSTR *ppszDataDescr`; a null pointer either way.
typedef _UnprotectNative = Int32 Function(Pointer<_DataBlob> dataIn, Pointer<Pointer<Utf16>> descr,
    Pointer<_DataBlob> entropy, Pointer<Void> reserved, Pointer<Void> prompt, Uint32 flags, Pointer<_DataBlob> dataOut);
typedef _UnprotectDart = int Function(Pointer<_DataBlob> dataIn, Pointer<Pointer<Utf16>> descr,
    Pointer<_DataBlob> entropy, Pointer<Void> reserved, Pointer<Void> prompt, int flags, Pointer<_DataBlob> dataOut);

/// CRYPTPROTECT_UI_FORBIDDEN: fail instead of showing a prompt.
const int _uiForbidden = 0x1;

/// Seals data with DPAPI in the current user's scope (not the machine's):
/// only this Windows account on this machine can open it.
class DpapiSealer implements Sealer {
  static final _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _protect = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptProtectData', isLeaf: true);
  static final _unprotect =
      _crypt32.lookupFunction<_UnprotectNative, _UnprotectDart>('CryptUnprotectData', isLeaf: true);
  static final _localFree =
      _kernel32.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>(
          'LocalFree',
          isLeaf: true);
  static final _getLastError =
      _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLastError', isLeaf: true);

  /// Domain separation, not a secret: it is in the program for anyone to
  /// read. It keeps this program's blobs apart from other programs' blobs.
  final Uint8List _entropy;

  DpapiSealer({String purpose = 'aurora3-profile-v1'}) : _entropy = Uint8List.fromList(utf8.encode(purpose)) {
    if (!Platform.isWindows) throw SealerUnavailable('DPAPI 只在 Windows 上可用');
  }

  @override
  String get id => 'dpapi';

  @override
  Uint8List seal(Uint8List plain) => _run(plain, true);

  @override
  Uint8List unseal(Uint8List sealed) => _run(sealed, false);

  Uint8List _run(Uint8List input, bool protect) {
    return using((arena) {
      final inBuf = arena<Uint8>(input.isEmpty ? 1 : input.length);
      final entBuf = arena<Uint8>(_entropy.length);
      final blobs = arena<_DataBlob>(3); // in, entropy, out
      try {
        inBuf.asTypedList(input.length).setAll(0, input);
        entBuf.asTypedList(_entropy.length).setAll(0, _entropy);
        blobs[0]
          ..cbData = input.length
          ..pbData = inBuf;
        blobs[1]
          ..cbData = _entropy.length
          ..pbData = entBuf;
        blobs[2]
          ..cbData = 0
          ..pbData = nullptr;
        final pIn = blobs;
        final pEnt = blobs + 1;
        final pOut = blobs + 2;
        final ok = protect
            ? _protect(pIn, nullptr, pEnt, nullptr, nullptr, _uiForbidden, pOut)
            : _unprotect(pIn, nullptr, pEnt, nullptr, nullptr, _uiForbidden, pOut);
        if (ok == 0) {
          final code = _getLastError();
          throw SealerException(protect
              ? 'DPAPI 加密失败（错误 $code）'
              : 'DPAPI 解密失败（错误 $code）：数据属于其它 Windows 用户或其它电脑，或已被改动');
        }
        final out = blobs[2];
        if (out.pbData.address == 0) return Uint8List(0);
        try {
          return Uint8List.fromList(out.pbData.asTypedList(out.cbData));
        } finally {
          // Plaintext from CryptUnprotectData: wipe before handing it back.
          if (!protect) out.pbData.asTypedList(out.cbData).fillRange(0, out.cbData, 0);
          _localFree(out.pbData.cast());
        }
      } finally {
        // The plaintext copy given to CryptProtectData.
        inBuf.asTypedList(input.isEmpty ? 1 : input.length).fillRange(0, input.isEmpty ? 1 : input.length, 0);
      }
    });
  }
}
