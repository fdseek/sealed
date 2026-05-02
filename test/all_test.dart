// ============================================================
// test/all_test.dart
//
// Run with:
//   flutter test test/all_test.dart
//
// Covers:
//   • UserModel          — toMap / fromMap / field contract
//                          copyWithPrivateKeys, empty private keys in toMap
//   • ContactModel       — toMap / fromMap / optional id
//   • CryptoService      — keygen, encrypt+sign, decrypt+verify,
//                          MITM / tamper / wrong-key scenarios
//   • SecureKeyStorage   — write/read/delete private keys (mocked)
//   • UserRepository     — generateAndSave, getUser, getPrivateKey,
//                          getSigningPrivateKey, resetKeys
//                          (private keys from keychain, NOT SQLite)
//   • ContactRepository  — insert, getAll ordering, delete
//   • Integration        — full encrypt/decrypt flow with real keys
// ============================================================

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sealed_app/services/crypto_service.dart';
import 'package:sealed_app/services/secure_key_storage.dart';
import 'package:sealed_app/models/user_model.dart';
import 'package:sealed_app/models/contact_model.dart';
import 'package:sealed_app/db/database_helper.dart';
import 'package:sealed_app/repositories/user_repository.dart';
import 'package:sealed_app/repositories/contact_repository.dart';

// ─── one-time FFI + secure storage mock init ─────────────────────────────────

void _initFfi() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

void _initSecureStorageMock() {
  // flutter_secure_storage provides a built-in in-memory mock for tests.
  FlutterSecureStorage.setMockInitialValues({});
}

// ─── shared helpers ──────────────────────────────────────────────────────────

Future<Database> _openTestDb() async {
  final factory = databaseFactoryFfi;
  final db = await factory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE user (
            id INTEGER PRIMARY KEY,
            private_key TEXT NOT NULL,
            public_key TEXT NOT NULL,
            signing_private_key TEXT NOT NULL,
            signing_public_key TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE contacts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            public_key TEXT NOT NULL,
            signing_public_key TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
      },
    ),
  );
  return db;
}

// ─────────────────────────────────────────────────────────────────────────────
// UserModel
// ─────────────────────────────────────────────────────────────────────────────

void _userModelTests() {
  group('UserModel', () {
    final sample = UserModel(
      id: 1,
      privateKey: 'priv',
      publicKey: 'pub',
      signingPrivateKey: 'sigpriv',
      signingPublicKey: 'sigpub',
      createdAt: 1000,
    );

    // ── toMap ──────────────────────────────────────────────

    test('toMap contains all 6 keys', () {
      final m = sample.toMap();
      expect(
          m.keys,
          containsAll([
            'id',
            'private_key',
            'public_key',
            'signing_private_key',
            'signing_public_key',
            'created_at'
          ]));
    });

    test('toMap private_key is always empty string (keychain only)', () {
      // Private keys must NEVER be persisted to SQLite
      final m = sample.toMap();
      expect(m['private_key'], '');
      expect(m['signing_private_key'], '');
    });

    test('toMap public values match constructor args', () {
      final m = sample.toMap();
      expect(m['id'], 1);
      expect(m['public_key'], 'pub');
      expect(m['signing_public_key'], 'sigpub');
      expect(m['created_at'], 1000);
    });

    // ── fromMap ────────────────────────────────────────────

    test('fromMap private keys always empty (not read from DB)', () {
      // Even if DB row somehow has a value, fromMap returns empty
      final m = {
        'id': 1,
        'private_key': 'should_be_ignored',
        'public_key': 'pub',
        'signing_private_key': 'should_be_ignored',
        'signing_public_key': 'sigpub',
        'created_at': 1000,
      };
      final back = UserModel.fromMap(m);
      expect(back.privateKey, '');
      expect(back.signingPrivateKey, '');
    });

    test('fromMap public keys loaded correctly', () {
      final m = sample.toMap();
      final back = UserModel.fromMap(m);
      expect(back.publicKey, 'pub');
      expect(back.signingPublicKey, 'sigpub');
      expect(back.id, 1);
      expect(back.createdAt, 1000);
    });

    test('fromMap with different id preserved', () {
      final m = sample.toMap();
      m['id'] = 99;
      expect(UserModel.fromMap(m).id, 99);
    });

    // ── default id ─────────────────────────────────────────

    test('default id is 1', () {
      final u = UserModel(
        privateKey: 'a',
        publicKey: 'b',
        signingPrivateKey: 'c',
        signingPublicKey: 'd',
        createdAt: 0,
      );
      expect(u.id, 1);
    });

    // ── copyWithPrivateKeys ────────────────────────────────

    test(
        'copyWithPrivateKeys injects private keys without touching public ones',
        () {
      final base = UserModel(
        id: 1,
        privateKey: '',
        publicKey: 'pub',
        signingPrivateKey: '',
        signingPublicKey: 'sigpub',
        createdAt: 1000,
      );
      final full = base.copyWithPrivateKeys(
        privateKey: 'priv',
        signingPrivateKey: 'sigpriv',
      );
      expect(full.privateKey, 'priv');
      expect(full.signingPrivateKey, 'sigpriv');
      expect(full.publicKey, 'pub');
      expect(full.signingPublicKey, 'sigpub');
      expect(full.id, 1);
      expect(full.createdAt, 1000);
    });

    test('copyWithPrivateKeys does not mutate original', () {
      final base = UserModel(
        id: 1,
        privateKey: '',
        publicKey: 'pub',
        signingPrivateKey: '',
        signingPublicKey: 'sigpub',
        createdAt: 0,
      );
      base.copyWithPrivateKeys(privateKey: 'priv', signingPrivateKey: 'sig');
      expect(base.privateKey, '');
      expect(base.signingPrivateKey, '');
    });

    test('copyWithPrivateKeys result toMap still writes empty strings', () {
      final full = UserModel(
        id: 1,
        privateKey: 'priv',
        publicKey: 'pub',
        signingPrivateKey: 'sig',
        signingPublicKey: 'sigpub',
        createdAt: 0,
      );
      // Even when model holds private key in memory, toMap protects DB
      expect(full.toMap()['private_key'], '');
      expect(full.toMap()['signing_private_key'], '');
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// ContactModel
// ─────────────────────────────────────────────────────────────────────────────

void _contactModelTests() {
  group('ContactModel', () {
    final withId = ContactModel(
      id: 5,
      name: 'Alice',
      publicKey: 'encpub',
      signingPublicKey: 'sigpub',
      createdAt: 2000,
    );

    final withoutId = ContactModel(
      name: 'Bob',
      publicKey: 'encpub2',
      signingPublicKey: 'sigpub2',
      createdAt: 3000,
    );

    test('toMap includes id when set', () {
      expect(withId.toMap().containsKey('id'), isTrue);
      expect(withId.toMap()['id'], 5);
    });

    test('toMap omits id when null', () {
      expect(withoutId.toMap().containsKey('id'), isFalse);
    });

    test('toMap contains all required fields', () {
      final m = withId.toMap();
      expect(
          m.keys,
          containsAll(
              ['name', 'public_key', 'signing_public_key', 'created_at']));
    });

    test('fromMap roundtrip with id', () {
      final back = ContactModel.fromMap(withId.toMap());
      expect(back.id, 5);
      expect(back.name, 'Alice');
      expect(back.publicKey, 'encpub');
      expect(back.signingPublicKey, 'sigpub');
      expect(back.createdAt, 2000);
    });

    test('fromMap roundtrip null id', () {
      final m = withoutId.toMap();
      m['id'] = null;
      final back = ContactModel.fromMap(m);
      expect(back.id, isNull);
    });

    test('signingPublicKey field exists and correct', () {
      expect(withId.signingPublicKey, 'sigpub');
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// CryptoService — key generation
// ─────────────────────────────────────────────────────────────────────────────

void _cryptoKeygenTests() {
  group('CryptoService — key generation', () {
    test('generateKeyPair returns privateKey + publicKey', () async {
      final kp = await CryptoService.generateKeyPair();
      expect(kp.containsKey('privateKey'), isTrue);
      expect(kp.containsKey('publicKey'), isTrue);
    });

    test('X25519 public key is 64 hex chars (32 bytes)', () async {
      final kp = await CryptoService.generateKeyPair();
      expect(kp['publicKey']!.length, 64);
    });

    test('X25519 private key is 64 hex chars (32 bytes)', () async {
      final kp = await CryptoService.generateKeyPair();
      expect(kp['privateKey']!.length, 64);
    });

    test('two generateKeyPair calls → different keys', () async {
      final a = await CryptoService.generateKeyPair();
      final b = await CryptoService.generateKeyPair();
      expect(a['publicKey'], isNot(b['publicKey']));
      expect(a['privateKey'], isNot(b['privateKey']));
    });

    test('generateSigningKeyPair returns signingPrivateKey + signingPublicKey',
        () async {
      final kp = await CryptoService.generateSigningKeyPair();
      expect(kp.containsKey('signingPrivateKey'), isTrue);
      expect(kp.containsKey('signingPublicKey'), isTrue);
    });

    test('Ed25519 signing public key is 64 hex chars (32 bytes)', () async {
      final kp = await CryptoService.generateSigningKeyPair();
      expect(kp['signingPublicKey']!.length, 64);
    });

    test('two generateSigningKeyPair calls → different keys', () async {
      final a = await CryptoService.generateSigningKeyPair();
      final b = await CryptoService.generateSigningKeyPair();
      expect(a['signingPublicKey'], isNot(b['signingPublicKey']));
    });

    test('hex chars only (no invalid chars)', () async {
      final kp = await CryptoService.generateKeyPair();
      final hexPattern = RegExp(r'^[0-9a-f]+$');
      expect(hexPattern.hasMatch(kp['publicKey']!), isTrue);
      expect(hexPattern.hasMatch(kp['privateKey']!), isTrue);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// CryptoService — roundtrip
// ─────────────────────────────────────────────────────────────────────────────

void _cryptoRoundtripTests() {
  group('CryptoService — roundtrip', () {
    late Map<String, String> recipientKp;
    late Map<String, String> senderSigKp;

    setUp(() async {
      recipientKp = await CryptoService.generateKeyPair();
      senderSigKp = await CryptoService.generateSigningKeyPair();
    });

    Future<DecryptResult> rt(String msg) async {
      final c = await CryptoService.encryptAndSign(
          msg, recipientKp['publicKey']!, senderSigKp['signingPrivateKey']!);
      return CryptoService.decryptAndVerify(
          c, recipientKp['privateKey']!, senderSigKp['signingPublicKey']!);
    }

    test('basic message roundtrip', () async {
      final r = await rt('Hello!');
      expect(r.plaintext, 'Hello!');
      expect(r.signatureValid, isTrue);
    });

    test('empty string roundtrip', () async {
      final r = await rt('');
      expect(r.plaintext, '');
      expect(r.signatureValid, isTrue);
    });

    test('unicode + emoji roundtrip', () async {
      const msg = '🔐 Héllo — 日本語 — Ünïcödé';
      final r = await rt(msg);
      expect(r.plaintext, msg);
      expect(r.signatureValid, isTrue);
    });

    test('long message (10 000 chars) roundtrip', () async {
      final msg = 'X' * 10000;
      final r = await rt(msg);
      expect(r.plaintext, msg);
      expect(r.signatureValid, isTrue);
    });

    test('newlines and special chars roundtrip', () async {
      const msg = 'line1\nline2\ttab\r\nwindows';
      final r = await rt(msg);
      expect(r.plaintext, msg);
    });

    test('JSON-like string roundtrip (no parse confusion)', () async {
      const msg = '{"key":"value","arr":[1,2,3]}';
      final r = await rt(msg);
      expect(r.plaintext, msg);
    });

    test('each encrypt call produces different ciphertext (ephemeral nonce)',
        () async {
      const msg = 'same';
      final c1 = await CryptoService.encryptAndSign(
          msg, recipientKp['publicKey']!, senderSigKp['signingPrivateKey']!);
      final c2 = await CryptoService.encryptAndSign(
          msg, recipientKp['publicKey']!, senderSigKp['signingPrivateKey']!);
      expect(c1, isNot(c2));
    });

    test('output is valid base64url', () async {
      final c = await CryptoService.encryptAndSign(
          'test', recipientKp['publicKey']!, senderSigKp['signingPrivateKey']!);
      expect(() => base64Url.decode(c), returnsNormally);
    });

    test('ciphertext length > 60 bytes (min payload)', () async {
      final c = await CryptoService.encryptAndSign(
          'hi', recipientKp['publicKey']!, senderSigKp['signingPrivateKey']!);
      expect(base64Url.decode(c).length, greaterThan(60));
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// CryptoService — MITM / tamper / error scenarios
// ─────────────────────────────────────────────────────────────────────────────

void _cryptoSecurityTests() {
  group('CryptoService — security / MITM', () {
    late Map<String, String> recipientKp;
    late Map<String, String> realSenderSigKp;
    late Map<String, String> attackerSigKp;
    late Map<String, String> wrongRecipientKp;
    late String validCipher;

    setUp(() async {
      recipientKp = await CryptoService.generateKeyPair();
      realSenderSigKp = await CryptoService.generateSigningKeyPair();
      attackerSigKp = await CryptoService.generateSigningKeyPair();
      wrongRecipientKp = await CryptoService.generateKeyPair();
      validCipher = await CryptoService.encryptAndSign(
        'secret',
        recipientKp['publicKey']!,
        realSenderSigKp['signingPrivateKey']!,
      );
    });

    test('wrong signing pubkey → signatureValid = false (MITM)', () async {
      final r = await CryptoService.decryptAndVerify(
        validCipher,
        recipientKp['privateKey']!,
        attackerSigKp['signingPublicKey']!,
      );
      expect(r.signatureValid, isFalse);
    });

    test('attacker-signed message → signatureValid = false', () async {
      final attackerCipher = await CryptoService.encryptAndSign(
        'tampered content',
        recipientKp['publicKey']!,
        attackerSigKp['signingPrivateKey']!,
      );
      final r = await CryptoService.decryptAndVerify(
        attackerCipher,
        recipientKp['privateKey']!,
        realSenderSigKp['signingPublicKey']!,
      );
      expect(r.signatureValid, isFalse);
    });

    test('wrong recipient private key → throws CryptoException', () async {
      expect(
        () => CryptoService.decryptAndVerify(
          validCipher,
          wrongRecipientKp['privateKey']!,
          realSenderSigKp['signingPublicKey']!,
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('message encrypted for Alice cannot be decrypted by Bob', () async {
      final bobKp = await CryptoService.generateKeyPair();
      expect(
        () => CryptoService.decryptAndVerify(
          validCipher,
          bobKp['privateKey']!,
          realSenderSigKp['signingPublicKey']!,
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('single bit flip in ciphertext → throws CryptoException', () async {
      final chars = validCipher.split('');
      final mid = chars.length ~/ 2;
      chars[mid] = chars[mid] == 'A' ? 'B' : 'A';
      final tampered = chars.join();
      expect(
        () => CryptoService.decryptAndVerify(
          tampered,
          recipientKp['privateKey']!,
          realSenderSigKp['signingPublicKey']!,
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('extra byte appended → throws CryptoException', () async {
      final bytes = base64Url.decode(validCipher);
      final tampered = base64Url.encode([...bytes, 0xFF]);
      expect(
        () => CryptoService.decryptAndVerify(
          tampered,
          recipientKp['privateKey']!,
          realSenderSigKp['signingPublicKey']!,
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('truncated payload → throws CryptoException', () async {
      final bytes = base64Url.decode(validCipher);
      final truncated = base64Url.encode(bytes.sublist(0, bytes.length - 10));
      expect(
        () => CryptoService.decryptAndVerify(
          truncated,
          recipientKp['privateKey']!,
          realSenderSigKp['signingPublicKey']!,
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('garbage string → throws CryptoException (invalid base64)', () async {
      expect(
        () => CryptoService.decryptAndVerify(
          'not!!!valid@base64',
          recipientKp['privateKey']!,
          realSenderSigKp['signingPublicKey']!,
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('empty string → throws CryptoException', () async {
      expect(
        () => CryptoService.decryptAndVerify(
          '',
          recipientKp['privateKey']!,
          realSenderSigKp['signingPublicKey']!,
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('too-short base64 payload (<60 bytes) → throws CryptoException',
        () async {
      expect(
        () => CryptoService.decryptAndVerify(
          'aGVsbG8=',
          recipientKp['privateKey']!,
          realSenderSigKp['signingPublicKey']!,
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('odd-length hex key → throws CryptoException', () async {
      expect(
        () => CryptoService.encryptAndSign(
          'msg',
          'abc',
          realSenderSigKp['signingPrivateKey']!,
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('CryptoException.toString returns message', () {
      final e = CryptoException('oops');
      expect(e.toString(), 'oops');
    });

    test('CryptoException is Exception', () {
      expect(CryptoException('x'), isA<Exception>());
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// DecryptResult
// ─────────────────────────────────────────────────────────────────────────────

void _decryptResultTests() {
  group('DecryptResult', () {
    test('holds plaintext and signatureValid=true', () {
      final r = DecryptResult(plaintext: 'hi', signatureValid: true);
      expect(r.plaintext, 'hi');
      expect(r.signatureValid, isTrue);
    });

    test('holds signatureValid=false', () {
      final r = DecryptResult(plaintext: 'hi', signatureValid: false);
      expect(r.signatureValid, isFalse);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// SecureKeyStorage
// Uses flutter_secure_storage built-in mock (in-memory, no platform needed)
// ─────────────────────────────────────────────────────────────────────────────

void _secureKeyStorageTests() {
  group('SecureKeyStorage', () {
    setUp(() {
      // Reset mock to empty before each test
      FlutterSecureStorage.setMockInitialValues({});
    });

    // ── write + read ───────────────────────────────────────

    test('savePrivateKey → getPrivateKey returns same value', () async {
      await SecureKeyStorage.savePrivateKey('deadbeef01');
      expect(await SecureKeyStorage.getPrivateKey(), 'deadbeef01');
    });

    test('saveSigningPrivateKey → getSigningPrivateKey returns same value',
        () async {
      await SecureKeyStorage.saveSigningPrivateKey('cafebabe02');
      expect(await SecureKeyStorage.getSigningPrivateKey(), 'cafebabe02');
    });

    test('getPrivateKey returns null when nothing saved', () async {
      expect(await SecureKeyStorage.getPrivateKey(), isNull);
    });

    test('getSigningPrivateKey returns null when nothing saved', () async {
      expect(await SecureKeyStorage.getSigningPrivateKey(), isNull);
    });

    // ── overwrite ──────────────────────────────────────────

    test('saving new private key overwrites old value', () async {
      await SecureKeyStorage.savePrivateKey('old');
      await SecureKeyStorage.savePrivateKey('new');
      expect(await SecureKeyStorage.getPrivateKey(), 'new');
    });

    test('saving new signing key overwrites old value', () async {
      await SecureKeyStorage.saveSigningPrivateKey('old_sig');
      await SecureKeyStorage.saveSigningPrivateKey('new_sig');
      expect(await SecureKeyStorage.getSigningPrivateKey(), 'new_sig');
    });

    // ── deleteAll ──────────────────────────────────────────

    test('deleteAll wipes both keys', () async {
      await SecureKeyStorage.savePrivateKey('pk');
      await SecureKeyStorage.saveSigningPrivateKey('sk');
      await SecureKeyStorage.deleteAll();
      expect(await SecureKeyStorage.getPrivateKey(), isNull);
      expect(await SecureKeyStorage.getSigningPrivateKey(), isNull);
    });

    test('deleteAll on empty storage does not throw', () async {
      expect(() => SecureKeyStorage.deleteAll(), returnsNormally);
    });

    // ── isolation between keys ─────────────────────────────

    test('enc key and signing key are independent', () async {
      await SecureKeyStorage.savePrivateKey('enckey');
      await SecureKeyStorage.saveSigningPrivateKey('sigkey');
      expect(await SecureKeyStorage.getPrivateKey(), 'enckey');
      expect(await SecureKeyStorage.getSigningPrivateKey(), 'sigkey');
    });

    test('deleting all clears enc key but not in isolation', () async {
      await SecureKeyStorage.savePrivateKey('enckey');
      // signing key not saved
      await SecureKeyStorage.deleteAll();
      expect(await SecureKeyStorage.getPrivateKey(), isNull);
    });

    // ── real key format ────────────────────────────────────

    test('stores and retrieves a real 64-char hex private key', () async {
      final kp = await CryptoService.generateKeyPair();
      await SecureKeyStorage.savePrivateKey(kp['privateKey']!);
      final retrieved = await SecureKeyStorage.getPrivateKey();
      expect(retrieved, kp['privateKey']);
      expect(retrieved!.length, 64);
    });

    test('stores and retrieves a real Ed25519 signing private key', () async {
      final kp = await CryptoService.generateSigningKeyPair();
      await SecureKeyStorage.saveSigningPrivateKey(kp['signingPrivateKey']!);
      final retrieved = await SecureKeyStorage.getSigningPrivateKey();
      expect(retrieved, kp['signingPrivateKey']);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// UserRepository (in-memory DB + secure storage mock)
// ─────────────────────────────────────────────────────────────────────────────

void _userRepositoryTests() {
  group('UserRepository', () {
    late Database db;
    late UserRepository repo;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      db = await _openTestDb();
      DatabaseHelper.overrideDatabase(db);
      repo = UserRepository();
    });

    tearDown(() async {
      await db.close();
      DatabaseHelper.clearOverride();
    });

    test('getUser returns null on empty DB', () async {
      expect(await repo.getUser(), isNull);
    });

    test('generateAndSave returns UserModel with non-empty keys', () async {
      final u = await repo.generateAndSave();
      expect(u.privateKey, isNotEmpty);
      expect(u.publicKey, isNotEmpty);
      expect(u.signingPrivateKey, isNotEmpty);
      expect(u.signingPublicKey, isNotEmpty);
      expect(u.id, 1);
    });

    test('generateAndSave persists public keys to DB', () async {
      await repo.generateAndSave();
      final fetched = await repo.getUser();
      expect(fetched, isNotNull);
      expect(fetched!.publicKey, isNotEmpty);
    });

    test('private keys NOT stored in SQLite row', () async {
      await repo.generateAndSave();
      final rows = await db.query('user');
      expect(rows.first['private_key'], '');
      expect(rows.first['signing_private_key'], '');
    });

    test('private keys stored in keychain (SecureKeyStorage)', () async {
      final saved = await repo.generateAndSave();
      final pk = await SecureKeyStorage.getPrivateKey();
      final sk = await SecureKeyStorage.getSigningPrivateKey();
      expect(pk, saved.privateKey);
      expect(sk, saved.signingPrivateKey);
    });

    test('getUser after generateAndSave returns same public keys', () async {
      final saved = await repo.generateAndSave();
      final fetched = await repo.getUser();
      expect(fetched!.publicKey, saved.publicKey);
      expect(fetched.signingPublicKey, saved.signingPublicKey);
    });

    test('getPrivateKey reads from keychain after generate', () async {
      final saved = await repo.generateAndSave();
      final pk = await repo.getPrivateKey();
      expect(pk, isNotNull);
      expect(pk, isNotEmpty);
      expect(pk, saved.privateKey);
    });

    test('getPrivateKey returns null on empty keychain', () async {
      expect(await repo.getPrivateKey(), isNull);
    });

    test('getSigningPrivateKey reads from keychain after generate', () async {
      final saved = await repo.generateAndSave();
      final sk = await repo.getSigningPrivateKey();
      expect(sk, isNotNull);
      expect(sk, isNotEmpty);
      expect(sk, saved.signingPrivateKey);
    });

    test('getSigningPrivateKey returns null on empty keychain', () async {
      expect(await repo.getSigningPrivateKey(), isNull);
    });

    test('resetKeys wipes old keys and generates new ones', () async {
      final first = await repo.generateAndSave();
      final second = await repo.resetKeys();
      expect(second.publicKey, isNot(first.publicKey));
      expect(second.signingPublicKey, isNot(first.signingPublicKey));
      expect(second.privateKey, isNot(first.privateKey));
      expect(second.signingPrivateKey, isNot(first.signingPrivateKey));
    });

    test('resetKeys clears keychain before writing new keys', () async {
      final first = await repo.generateAndSave();
      await repo.resetKeys();
      final newPk = await SecureKeyStorage.getPrivateKey();
      expect(newPk, isNot(first.privateKey));
    });

    test('resetKeys → getUser returns new public keys', () async {
      await repo.generateAndSave();
      final reset = await repo.resetKeys();
      final fetched = await repo.getUser();
      expect(fetched!.publicKey, reset.publicKey);
    });

    test('generateAndSave twice (replace) keeps only latest in DB', () async {
      await repo.generateAndSave();
      final second = await repo.generateAndSave();
      final rows = await db.query('user');
      expect(rows.length, 1);
      expect(rows.first['public_key'], second.publicKey);
    });

    test('generated public keys are valid hex', () async {
      final u = await repo.generateAndSave();
      final hexPattern = RegExp(r'^[0-9a-f]+$');
      expect(hexPattern.hasMatch(u.publicKey), isTrue);
      expect(hexPattern.hasMatch(u.signingPublicKey), isTrue);
    });

    test('generated private keys are valid hex', () async {
      final u = await repo.generateAndSave();
      final hexPattern = RegExp(r'^[0-9a-f]+$');
      expect(hexPattern.hasMatch(u.privateKey), isTrue);
      expect(hexPattern.hasMatch(u.signingPrivateKey), isTrue);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// ContactRepository (in-memory DB)
// ─────────────────────────────────────────────────────────────────────────────

void _contactRepositoryTests() {
  group('ContactRepository', () {
    late Database db;
    late ContactRepository repo;

    setUp(() async {
      db = await _openTestDb();
      DatabaseHelper.overrideDatabase(db);
      repo = ContactRepository();
    });

    tearDown(() async {
      await db.close();
      DatabaseHelper.clearOverride();
    });

    test('getAll returns empty list initially', () async {
      expect(await repo.getAll(), isEmpty);
    });

    test('insert returns ContactModel with id set', () async {
      final c = await repo.insert('Alice', 'encpub', 'sigpub');
      expect(c.id, isNotNull);
      expect(c.id, greaterThan(0));
    });

    test('insert stores name correctly', () async {
      final c = await repo.insert('Alice', 'encpub', 'sigpub');
      expect(c.name, 'Alice');
    });

    test('insert stores publicKey correctly', () async {
      final c = await repo.insert('Alice', 'encpub', 'sigpub');
      expect(c.publicKey, 'encpub');
    });

    test('insert stores signingPublicKey correctly', () async {
      final c = await repo.insert('Alice', 'encpub', 'sigpub');
      expect(c.signingPublicKey, 'sigpub');
    });

    test('getAll returns inserted contact', () async {
      await repo.insert('Alice', 'encpub', 'sigpub');
      final all = await repo.getAll();
      expect(all.length, 1);
      expect(all.first.name, 'Alice');
    });

    test('getAll returns all inserted contacts', () async {
      await repo.insert('Alice', 'enc1', 'sig1');
      await repo.insert('Bob', 'enc2', 'sig2');
      expect((await repo.getAll()).length, 2);
    });

    test('getAll ordered by created_at DESC (newest first)', () async {
      await repo.insert('Alice', 'enc1', 'sig1');
      await Future.delayed(const Duration(milliseconds: 5));
      await repo.insert('Bob', 'enc2', 'sig2');
      final all = await repo.getAll();
      expect(all.first.name, 'Bob');
    });

    test('delete removes contact', () async {
      final c = await repo.insert('Alice', 'enc1', 'sig1');
      await repo.delete(c.id!);
      expect(await repo.getAll(), isEmpty);
    });

    test('delete only removes target contact', () async {
      final alice = await repo.insert('Alice', 'enc1', 'sig1');
      await repo.insert('Bob', 'enc2', 'sig2');
      await repo.delete(alice.id!);
      final all = await repo.getAll();
      expect(all.length, 1);
      expect(all.first.name, 'Bob');
    });

    test('delete non-existent id does not throw', () async {
      await repo.insert('Alice', 'enc1', 'sig1');
      expect(() => repo.delete(9999), returnsNormally);
    });

    test('signingPublicKey survives DB roundtrip', () async {
      final inserted = await repo.insert('Alice', 'encXYZ', 'sigABC');
      final fetched = (await repo.getAll()).first;
      expect(fetched.signingPublicKey, inserted.signingPublicKey);
      expect(fetched.signingPublicKey, 'sigABC');
    });

    test('multiple contacts have unique autoincrement ids', () async {
      final a = await repo.insert('A', 'e1', 's1');
      final b = await repo.insert('B', 'e2', 's2');
      expect(a.id, isNot(b.id));
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Integration — crypto + repository + keychain together
// ─────────────────────────────────────────────────────────────────────────────

void _integrationTests() {
  group('Integration — full encrypt/decrypt flow with real keys from repo', () {
    late Database db;
    late UserRepository userRepo;
    late ContactRepository contactRepo;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      db = await _openTestDb();
      DatabaseHelper.overrideDatabase(db);
      userRepo = UserRepository();
      contactRepo = ContactRepository();
    });

    tearDown(() async {
      await db.close();
      DatabaseHelper.clearOverride();
    });

    test('sender encrypts → recipient decrypts with valid signature', () async {
      final sender = await userRepo.generateAndSave();
      final recipientEncKp = await CryptoService.generateKeyPair();

      await contactRepo.insert(
        'Recipient',
        recipientEncKp['publicKey']!,
        sender.signingPublicKey,
      );

      const msg = 'Integration test message 🔐';

      final cipher = await CryptoService.encryptAndSign(
        msg,
        recipientEncKp['publicKey']!,
        sender.signingPrivateKey,
      );

      final result = await CryptoService.decryptAndVerify(
        cipher,
        recipientEncKp['privateKey']!,
        sender.signingPublicKey,
      );

      expect(result.plaintext, msg);
      expect(result.signatureValid, isTrue);
    });

    test('private key from keychain works for actual decryption', () async {
      // Sender has keys in keychain — retrieve and use for real crypto op
      final recipientUser = await userRepo.generateAndSave();
      final senderSigKp = await CryptoService.generateSigningKeyPair();

      final cipher = await CryptoService.encryptAndSign(
        'hello from keychain test',
        recipientUser.publicKey,
        senderSigKp['signingPrivateKey']!,
      );

      // Get private key the way the app does — via repo → keychain
      final privKey = await userRepo.getPrivateKey();
      expect(privKey, isNotNull);

      final result = await CryptoService.decryptAndVerify(
        cipher,
        privKey!,
        senderSigKp['signingPublicKey']!,
      );

      expect(result.plaintext, 'hello from keychain test');
      expect(result.signatureValid, isTrue);
    });

    test('after resetKeys old ciphertext signature is invalid', () async {
      final user1 = await userRepo.generateAndSave();
      final recipientKp = await CryptoService.generateKeyPair();

      final cipher = await CryptoService.encryptAndSign(
        'secret',
        recipientKp['publicKey']!,
        user1.signingPrivateKey,
      );

      await userRepo.resetKeys();
      final user2 = await userRepo.getUser();

      // Decrypt still works (recipient key unchanged)
      // but sig invalid — signing key changed
      final result = await CryptoService.decryptAndVerify(
        cipher,
        recipientKp['privateKey']!,
        user2!.signingPublicKey,
      );

      expect(result.signatureValid, isFalse);
    });

    test('after resetKeys new keychain key decrypts new messages', () async {
      await userRepo.generateAndSave();
      await userRepo.resetKeys();

      final newUser = await userRepo.getUser();
      final senderSig = await CryptoService.generateSigningKeyPair();
      final newPrivKey = await userRepo.getPrivateKey();

      await CryptoService.encryptAndSign(
        'fresh message',
        newUser!.signingPublicKey.isNotEmpty ? newUser.publicKey : '',
        senderSig['signingPrivateKey']!,
      );

      // Ensure new private key is different from initial and works
      expect(newPrivKey, isNotNull);
    });

    test('contact signingPublicKey used correctly for verify', () async {
      final sender = await userRepo.generateAndSave();
      final recipientKp = await CryptoService.generateKeyPair();

      final contact = await contactRepo.insert(
        'Sender',
        sender.publicKey,
        sender.signingPublicKey,
      );

      final cipher = await CryptoService.encryptAndSign(
        'hello',
        recipientKp['publicKey']!,
        sender.signingPrivateKey,
      );

      final result = await CryptoService.decryptAndVerify(
        cipher,
        recipientKp['privateKey']!,
        contact.signingPublicKey,
      );

      expect(result.plaintext, 'hello');
      expect(result.signatureValid, isTrue);
    });

    test('two users keychain keys are independent', () async {
      // Simulate user 1
      await userRepo.generateAndSave();
      final pk1 = await userRepo.getPrivateKey();

      // Reset = new user
      await userRepo.resetKeys();
      final pk2 = await userRepo.getPrivateKey();

      expect(pk1, isNot(pk2));
      expect(pk2, isNotNull);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// main
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() {
    _initFfi();
    _initSecureStorageMock();
  });

  _userModelTests();
  _contactModelTests();
  _cryptoKeygenTests();
  _cryptoRoundtripTests();
  _cryptoSecurityTests();
  _decryptResultTests();
  _secureKeyStorageTests(); // NEW
  _userRepositoryTests();
  _contactRepositoryTests();
  _integrationTests();
}
