import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class FingerprintService {
  /// SHA-256(encPubKey + sigPubKey) → "A3:F2:9C:11:..." (16 pairs shown)
  static String compute(String encPubKeyHex, String sigPubKeyHex) {
    final input = utf8.encode(encPubKeyHex + sigPubKeyHex);
    final digest = sha256.convert(input);
    return _formatFingerprint(Uint8List.fromList(digest.bytes));
  }

  /// Same but for own keys — identical algorithm, just your own keys
  static String computeOwn(String encPubKeyHex, String sigPubKeyHex) =>
      compute(encPubKeyHex, sigPubKeyHex);


  static String _formatFingerprint(Uint8List bytes) {
    return bytes
        .take(16) // 16 bytes = readable length
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
  }
}