import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../db/database_helper.dart';
import '../models/user_model.dart';
import '../services/crypto_service.dart';
import '../services/secure_key_storage.dart'; // NEW

class UserRepository {
  final _db = DatabaseHelper.instance;

  Future<UserModel?> getUser() async {
    final db = await _db.database;
    final rows = await db.query('user', where: 'id = ?', whereArgs: [1]);
    if (rows.isEmpty) return null;
    return UserModel.fromMap(rows.first);
  }

  /// Private keys now live in keychain — NOT in SQLite row.
  Future<String?> getPrivateKey() =>
      SecureKeyStorage.getPrivateKey();

  Future<String?> getSigningPrivateKey() =>
      SecureKeyStorage.getSigningPrivateKey();

  Future<UserModel> generateAndSave() async {
    final db = await _db.database;

    final encKp  = await CryptoService.generateKeyPair();
    final sigKp  = await CryptoService.generateSigningKeyPair();

    // ── private keys → keychain ──────────────────────────
    await SecureKeyStorage.savePrivateKey(encKp['privateKey']!);
    await SecureKeyStorage.saveSigningPrivateKey(sigKp['signingPrivateKey']!);

    // ── public keys → SQLite (not sensitive) ─────────────
    final user = UserModel(
      id: 1,
      privateKey: '',            // empty — stored in keychain now
      publicKey: encKp['publicKey']!,
      signingPrivateKey: '',     // empty — stored in keychain now
      signingPublicKey: sigKp['signingPublicKey']!,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    await db.insert(
      'user',
      user.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    return user.copyWithPrivateKeys(
      privateKey: encKp['privateKey']!,
      signingPrivateKey: sigKp['signingPrivateKey']!,
    );
  }

  Future<UserModel> resetKeys() async {
    final db = await _db.database;
    await db.delete('user', where: 'id = ?', whereArgs: [1]);
    await SecureKeyStorage.deleteAll(); // wipe keychain entries
    return generateAndSave();
  }
}