// Android sealer (D-72). The 256-bit data key lives in the Android Keystore
// (wrapped by a hardware-backed, non-exportable AES key; see
// KeystorePlugin.kt). The app asks the platform for the unwrapped data key
// once at start, then seals with AES-256-GCM in Dart so the Sealer interface
// stays synchronous.
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'sealer.dart';

class AndroidSealer implements Sealer {
  static const _nonceLen = 12;
  static const _tagBits = 128;
  final Uint8List _key;
  final Uint8List _aad;
  final Random _rng = Random.secure();

  AndroidSealer(Uint8List key, {String purpose = 'aurora3-profile-v1'})
      : _key = Uint8List.fromList(key),
        _aad = Uint8List.fromList(purpose.codeUnits) {
    if (key.length != 32) throw SealerException('Android 密钥长度不对');
  }

  @override
  String get id => 'android-keystore';

  GCMBlockCipher _cipher(bool enc, Uint8List nonce) =>
      GCMBlockCipher(AESEngine())..init(enc, AEADParameters(KeyParameter(_key), _tagBits, nonce, _aad));

  @override
  Uint8List seal(Uint8List plain) {
    final nonce = Uint8List.fromList(List.generate(_nonceLen, (_) => _rng.nextInt(256)));
    final ct = _cipher(true, nonce).process(plain);
    return Uint8List.fromList([...nonce, ...ct]);
  }

  @override
  Uint8List unseal(Uint8List sealed) {
    if (sealed.length < _nonceLen + _tagBits ~/ 8) throw SealerException('加密数据太短');
    try {
      final nonce = Uint8List.sublistView(sealed, 0, _nonceLen);
      return _cipher(false, nonce).process(Uint8List.sublistView(sealed, _nonceLen));
    } on InvalidCipherTextException {
      throw SealerException('无法解密：数据被改动，或属于另一台设备');
    }
  }
}
