import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// X25519 key exchange + ChaCha20-Poly1305 AEAD encryption
/// Ed25519 signing for sender authentication (MITM protection)
///
/// Encrypt+Sign flow:
///   1. sender signs plaintext with Ed25519 signing key
///   2. ephemeral keypair + recipient X25519 pubkey → shared secret → encrypt(plaintext + sig)
///
/// Decrypt+Verify flow:
///   1. recipient X25519 privkey + ephemeral pubkey → shared secret → decrypt
///   2. verify Ed25519 signature against sender's signing pubkey (from contacts)
class CryptoService {
  static final _x25519 = X25519();
  static final _chacha = Chacha20.poly1305Aead();
  static final _ed25519 = Ed25519();

  // ─── X25519 Key Generation ─────────────────────────────

  /// Returns { 'privateKey': hex, 'publicKey': hex }
  static Future<Map<String, String>> generateKeyPair() async {
    final keyPair = await _x25519.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    return {
      'privateKey': _bytesToHex(privateKeyBytes),
      'publicKey': _bytesToHex(publicKey.bytes),
    };
  }

  // ─── Ed25519 Signing Key Generation ───────────────────

  /// Returns { 'signingPrivateKey': hex, 'signingPublicKey': hex }
  static Future<Map<String, String>> generateSigningKeyPair() async {
    final keyPair = await _ed25519.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    return {
      'signingPrivateKey': _bytesToHex(privateKeyBytes),
      'signingPublicKey': _bytesToHex(publicKey.bytes),
    };
  }

  // ─── Encrypt + Sign ────────────────────────────────────

  /// Encrypt [plaintext] for [recipientPublicKeyHex]
  /// Sign with sender's [signingPrivateKeyHex]
  ///
  /// Payload layout:
  ///   [ephemeral pub (32)] + [nonce (12)] + [ciphertext + mac (N+16)]
  ///
  /// Inner plaintext encrypted = JSON { "msg": plaintext, "sig": hex(signature) }
  static Future<String> encryptAndSign(
    String plaintext,
    String recipientPublicKeyHex,
    String signingPrivateKeyHex,
  ) async {
    // 1. sign plaintext
    final sigBytes = await _sign(plaintext, signingPrivateKeyHex);
    final sigHex = _bytesToHex(sigBytes);

    // 2. bundle plaintext + signature
    final inner = jsonEncode({'msg': plaintext, 'sig': sigHex});

    // 3. ephemeral X25519 keypair
    final ephemeralKeyPair = await _x25519.newKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();

    // 4. recipient public key
    final recipientPublicKey = SimplePublicKey(
      _hexToBytes(recipientPublicKeyHex,expectedBytes: 32),
      type: KeyPairType.x25519,
    );

    // 5. X25519 shared secret → symmetric key
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientPublicKey,
    );
    final symKey = SecretKey(await sharedSecret.extractBytes());

    // 6. encrypt inner payload
    final nonce = _chacha.newNonce();
    final secretBox = await _chacha.encrypt(
      utf8.encode(inner),
      secretKey: symKey,
      nonce: nonce,
    );

    // 7. pack: [ephemeral pub (32)] + [nonce (12)] + [ciphertext + mac]
    final payload = Uint8List.fromList([
      ...ephemeralPublicKey.bytes,
      ...nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);

    return base64Url.encode(payload);
  }

  // ─── Decrypt + Verify ──────────────────────────────────

  /// Decrypt [ciphertext] (base64) using [privateKeyHex]
  /// Verify signature against sender's [senderSigningPublicKeyHex]
  ///
  /// Throws [CryptoException] on failure or tampered message
  /// Returns [DecryptResult] with plaintext and verification status
  static Future<DecryptResult> decryptAndVerify(
    String ciphertext,
    String privateKeyHex,
    String senderSigningPublicKeyHex,
  ) async {
    Uint8List payload;
    try {
      payload = base64Url.decode(ciphertext.trim());
    } catch (_) {
      throw CryptoException('Invalid format: not valid base64');
    }

    // minimum: 32 (ephemeral pub) + 12 (nonce) + 16 (mac) = 60 bytes
    if (payload.length < 60) {
      throw CryptoException('Invalid or corrupted message');
    }

    try {
      // unpack
      final ephemeralPubBytes = payload.sublist(0, 32);
      final nonce = payload.sublist(32, 44);
      final cipherAndMac = payload.sublist(44);
      final cipherBytes = cipherAndMac.sublist(0, cipherAndMac.length - 16);
      final macBytes = cipherAndMac.sublist(cipherAndMac.length - 16);

      // reconstruct X25519 private key
      final keyPair =
          await _x25519.newKeyPairFromSeed(_hexToBytes(privateKeyHex,expectedBytes: 32));

      // shared secret
      final ephemeralPublicKey = SimplePublicKey(
        ephemeralPubBytes,
        type: KeyPairType.x25519,
      );
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: keyPair,
        remotePublicKey: ephemeralPublicKey,
      );
      final symKey = SecretKey(await sharedSecret.extractBytes());

      // decrypt
      final secretBox = SecretBox(
        cipherBytes,
        nonce: nonce,
        mac: Mac(macBytes),
      );
      final plainBytes = await _chacha.decrypt(secretBox, secretKey: symKey);
      final inner = utf8.decode(plainBytes);

      // parse inner JSON
      final Map<String, dynamic> parsed;
      try {
        parsed = jsonDecode(inner) as Map<String, dynamic>;
      } catch (_) {
        throw CryptoException('Corrupted message structure');
      }

      final message = parsed['msg'] as String?;
      final sigHex = parsed['sig'] as String?;

      if (message == null || sigHex == null) {
        throw CryptoException('Missing message or signature field');
      }

      // verify Ed25519 signature
      final verified =
          await _verify(message, sigHex, senderSigningPublicKeyHex);

      return DecryptResult(plaintext: message, signatureValid: verified);
    } on SecretBoxAuthenticationError {
      throw CryptoException('Wrong key or message was tampered');
    } on CryptoException {
      rethrow;
    } catch (e) {
      throw CryptoException('Decryption failed: ${e.toString()}');
    }
  }

  // ─── Internal Sign / Verify ────────────────────────────

  static Future<List<int>> _sign(
      String message, String signingPrivateKeyHex) async {
    final privBytes = _hexToBytes(signingPrivateKeyHex,expectedBytes: 32);
    // Ed25519 seed = first 32 bytes of private key
    final keyPair = await _ed25519.newKeyPairFromSeed(privBytes);
    final signature =
        await _ed25519.sign(utf8.encode(message), keyPair: keyPair);
    return signature.bytes;
  }

  static Future<bool> _verify(
      String message, String sigHex, String signingPublicKeyHex) async {
    try {
      final pubBytes = _hexToBytes(signingPublicKeyHex,expectedBytes: 32);
      final sigBytes = _hexToBytes(sigHex,expectedBytes: 64);
      final publicKey = SimplePublicKey(pubBytes, type: KeyPairType.ed25519);
      final signature = Signature(sigBytes, publicKey: publicKey);
      return await _ed25519.verify(utf8.encode(message), signature: signature);
    } catch (_) {
      return false;
    }
  }

  // ─── Helpers ──────────────────────────────────────────

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _hexToBytes(String hex, {int? expectedBytes}) {
    if (hex.length % 2 != 0) throw CryptoException('Invalid hex key');
    if (expectedBytes != null && hex.length != expectedBytes * 2) {
      throw CryptoException(
          'Invalid key length: expected ${expectedBytes * 2} hex chars, got ${hex.length}');
    }
    return Uint8List.fromList(
      List.generate(
        hex.length ~/ 2,
        (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    );
  }
}

/// Result of decryptAndVerify
class DecryptResult {
  final String plaintext;

  /// true = signature matched sender's signing pubkey
  /// false = signature invalid (possible MITM or wrong sender)
  final bool signatureValid;

  DecryptResult({required this.plaintext, required this.signatureValid});
}

class CryptoException implements Exception {
  final String message;
  CryptoException(this.message);

  @override
  String toString() => message;
}
