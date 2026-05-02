import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure keychain/keystore wrapper for private keys only.
/// Public keys + contacts stay in SQLite (not sensitive).
class SecureKeyStorage {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
    ),
    iOptions: IOSOptions(
      accessibility:
          KeychainAccessibility.first_unlock, // accessible after first unlock
    ),
  );

  static const _kPrivateKey = 'enc_private_key';
  static const _kSigningPrivateKey = 'sig_private_key';

  // ── write ──────────────────────────────────────────────

  static Future<void> savePrivateKey(String hex) =>
      _storage.write(key: _kPrivateKey, value: hex);

  static Future<void> saveSigningPrivateKey(String hex) =>
      _storage.write(key: _kSigningPrivateKey, value: hex);

  // ── read ───────────────────────────────────────────────

  static Future<String?> getPrivateKey() => _storage.read(key: _kPrivateKey);

  static Future<String?> getSigningPrivateKey() =>
      _storage.read(key: _kSigningPrivateKey);

  // ── delete (call on key reset) ─────────────────────────

  static Future<void> deleteAll() => _storage.deleteAll();
}
