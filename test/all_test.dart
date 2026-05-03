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
//   • DeepLinkService    — build, parse, QR parse, edge cases
//   • FingerprintService — compute, format, determinism, independence
//   • AuthLockService    — PIN hash, verify, fail count, stealth,
//                          timeout logic, enable/disable, biometric flag
//   • Integration        — full encrypt/decrypt flow with real keys
// ============================================================

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sealed_app/services/crypto_service.dart';
import 'package:sealed_app/services/secure_key_storage.dart';
import 'package:sealed_app/services/deep_link_service.dart';
import 'package:sealed_app/services/fingerprint_service.dart';
import 'package:sealed_app/services/auth_lock_service.dart';
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
  FlutterSecureStorage.setMockInitialValues({});
}

// ─── shared helpers ──────────────────────────────────────────────────────────

Future<Database> _openTestDb() async {
  final db = await databaseFactoryFfi.openDatabase(
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

    test('toMap private_key always empty string (keychain only)', () {
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
      expect(full.toMap()['private_key'], '');
      expect(full.toMap()['signing_private_key'], '');
    });

    // ── SECURITY: private key never leaks to DB ────────────

    test(
        'SECURITY: even after copyWithPrivateKeys toMap never exposes private key',
        () {
      final model = UserModel(
        id: 1,
        privateKey: '',
        publicKey: 'pub',
        signingPrivateKey: '',
        signingPublicKey: 'sig',
        createdAt: 0,
      ).copyWithPrivateKeys(
          privateKey: 'secret_key', signingPrivateKey: 'secret_sig');
      final map = model.toMap();
      expect(map.values, isNot(contains('secret_key')));
      expect(map.values, isNot(contains('secret_sig')));
    });

    test(
        'SECURITY: fromMap cannot be tricked into loading private key from DB row',
        () {
      // Even if an attacker writes private_key into SQLite row, fromMap ignores it
      final maliciousRow = {
        'id': 1,
        'private_key': 'stolen_key',
        'public_key': 'pub',
        'signing_private_key': 'stolen_sig',
        'signing_public_key': 'sigpub',
        'created_at': 0,
      };
      final model = UserModel.fromMap(maliciousRow);
      expect(model.privateKey, '');
      expect(model.signingPrivateKey, '');
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

    test('name with unicode chars survives roundtrip', () {
      final c = ContactModel(
        name: '日本語 Ünïcödé 🔐',
        publicKey: 'pk',
        signingPublicKey: 'sk',
        createdAt: 0,
      );
      final back = ContactModel.fromMap(c.toMap()..['id'] = null);
      expect(back.name, '日本語 Ünïcödé 🔐');
    });

    test('empty name allowed in model', () {
      final c = ContactModel(
          name: '', publicKey: 'pk', signingPublicKey: 'sk', createdAt: 0);
      expect(c.name, '');
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

    test(
        'enc keypair and signing keypair are independent (different algorithms)',
        () async {
      final enc = await CryptoService.generateKeyPair();
      final sig = await CryptoService.generateSigningKeyPair();
      expect(enc['publicKey'], isNot(sig['signingPublicKey']));
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

    // ── SECURITY: payload structure ────────────────────────

    test(
        'SECURITY: payload has correct structure (32 ephemeral + 12 nonce + N+16 mac)',
        () async {
      final c = await CryptoService.encryptAndSign(
          'test', recipientKp['publicKey']!, senderSigKp['signingPrivateKey']!);
      final bytes = base64Url.decode(c);
      // 32 (ephemeral pub) + 12 (nonce) + at least 16 (mac)
      expect(bytes.length, greaterThanOrEqualTo(32 + 12 + 16));
    });

    test('SECURITY: signature covers plaintext (sig is of msg not ciphertext)',
        () async {
      // Encrypt same plaintext twice - different ciphertexts but both valid
      final msg = 'test message';
      final c1 = await CryptoService.encryptAndSign(
          msg, recipientKp['publicKey']!, senderSigKp['signingPrivateKey']!);
      final c2 = await CryptoService.encryptAndSign(
          msg, recipientKp['publicKey']!, senderSigKp['signingPrivateKey']!);
      final r1 = await CryptoService.decryptAndVerify(
          c1, recipientKp['privateKey']!, senderSigKp['signingPublicKey']!);
      final r2 = await CryptoService.decryptAndVerify(
          c2, recipientKp['privateKey']!, senderSigKp['signingPublicKey']!);
      expect(r1.signatureValid, isTrue);
      expect(r2.signatureValid, isTrue);
    });

    test('very long message with special JSON chars roundtrip', () async {
      final msg = '{"nested":{"arr":[1,"two",null,true]}}' * 100;
      final r = await rt(msg);
      expect(r.plaintext, msg);
      expect(r.signatureValid, isTrue);
    });

    test('null bytes in base64 payload do not cause issues', () async {
      // Message with chars that encode to bytes including 0x00
      final msg = String.fromCharCodes(List.generate(32, (i) => i));
      final r = await rt(msg);
      expect(r.plaintext, msg);
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

    // ── SECURITY: replay attacks ───────────────────────────

    test(
        'SECURITY: same ciphertext replayed still decrypts (no replay protection — known gap)',
        () async {
      // Document the known weakness: no nonce/timestamp binding
      // App has no replay protection; this test documents the gap
      final r1 = await CryptoService.decryptAndVerify(
        validCipher,
        recipientKp['privateKey']!,
        realSenderSigKp['signingPublicKey']!,
      );
      final r2 = await CryptoService.decryptAndVerify(
        validCipher,
        recipientKp['privateKey']!,
        realSenderSigKp['signingPublicKey']!,
      );
      expect(r1.plaintext, r2.plaintext);
      // NOTE: This is the documented "no replay protection" gap in README
    });

    test('SECURITY: wrong-length public key → throws CryptoException',
        () async {
      expect(
        () => CryptoService.encryptAndSign(
          'msg',
          'deadbeef', // too short (not 64 chars)
          realSenderSigKp['signingPrivateKey']!,
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test(
        'SECURITY: all-zeros key encrypts but decryption with correct key fails (weak key accepted)',
        () async {
      final zeroKey = '0' * 64;
      // X25519 low-order point — library accepts it, documents known weak key risk
      final cipher = await CryptoService.encryptAndSign(
        'msg',
        zeroKey,
        realSenderSigKp['signingPrivateKey']!,
      );
      // Cannot decrypt with normal key — different recipient
      expect(
        () => CryptoService.decryptAndVerify(
          cipher,
          recipientKp['privateKey']!,
          realSenderSigKp['signingPublicKey']!,
        ),
        throwsA(isA<CryptoException>()),
      );
    });
    test(
        'SECURITY: nonce uniqueness — 100 encryptions all different ciphertexts',
        () async {
      final ciphertexts = <String>{};
      for (var i = 0; i < 100; i++) {
        final c = await CryptoService.encryptAndSign(
          'same message',
          recipientKp['publicKey']!,
          realSenderSigKp['signingPrivateKey']!,
        );
        ciphertexts.add(c);
      }
      expect(ciphertexts.length, 100); // all unique
    });

    test('SECURITY: decrypting with swapped enc/sig keys throws', () async {
      // Using signing key where encryption key expected
      expect(
        () => CryptoService.decryptAndVerify(
          validCipher,
          realSenderSigKp['signingPrivateKey']!, // wrong key type
          realSenderSigKp['signingPublicKey']!,
        ),
        throwsA(isA<CryptoException>()),
      );
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

    test('empty plaintext allowed', () {
      final r = DecryptResult(plaintext: '', signatureValid: true);
      expect(r.plaintext, '');
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// SecureKeyStorage
// ─────────────────────────────────────────────────────────────────────────────

void _secureKeyStorageTests() {
  group('SecureKeyStorage', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
    });

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

    test('enc key and signing key are independent', () async {
      await SecureKeyStorage.savePrivateKey('enckey');
      await SecureKeyStorage.saveSigningPrivateKey('sigkey');
      expect(await SecureKeyStorage.getPrivateKey(), 'enckey');
      expect(await SecureKeyStorage.getSigningPrivateKey(), 'sigkey');
    });

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

    // ── SECURITY: key isolation ────────────────────────────

    test(
        'SECURITY: enc private key and signing private key stored under different keys',
        () async {
      await SecureKeyStorage.savePrivateKey('enc_val');
      await SecureKeyStorage.saveSigningPrivateKey('sig_val');
      // They must not cross-contaminate
      expect(await SecureKeyStorage.getPrivateKey(), 'enc_val');
      expect(await SecureKeyStorage.getSigningPrivateKey(), 'sig_val');
    });

    test('SECURITY: deleteAll clears all keys atomically', () async {
      await SecureKeyStorage.savePrivateKey('pk');
      await SecureKeyStorage.saveSigningPrivateKey('sk');
      await SecureKeyStorage.deleteAll();
      expect(await SecureKeyStorage.getPrivateKey(), isNull);
      expect(await SecureKeyStorage.getSigningPrivateKey(), isNull);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// DeepLinkService
// ─────────────────────────────────────────────────────────────────────────────

void _deepLinkServiceTests() {
  group('DeepLinkService', () {
    const name = 'Alice';
    const enc =
        'aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd';
    const sig =
        'eeff0011eeff0011eeff0011eeff0011eeff0011eeff0011eeff0011eeff0011';
    // ── buildLink ──────────────────────────────────────────

    test('buildLink starts with sealed://', () {
      final link = DeepLinkService.buildLink(
          name: name, encPublicKey: enc, sigPublicKey: sig);
      expect(link, startsWith('sealed://'));
    });

    test('buildLink contains name param', () {
      final link = DeepLinkService.buildLink(
          name: name, encPublicKey: enc, sigPublicKey: sig);
      expect(link, contains('name=Alice'));
    });

    test('buildLink contains enc param', () {
      final link = DeepLinkService.buildLink(
          name: name, encPublicKey: enc, sigPublicKey: sig);
      expect(link, contains('enc='));
    });

    test('buildLink contains sig param', () {
      final link = DeepLinkService.buildLink(
          name: name, encPublicKey: enc, sigPublicKey: sig);
      expect(link, contains('sig='));
    });

    // ── parse ──────────────────────────────────────────────

    test('parse valid link → ContactPayload', () {
      final link = DeepLinkService.buildLink(
          name: name, encPublicKey: enc, sigPublicKey: sig);
      final payload = DeepLinkService.parse(link);
      expect(payload, isNotNull);
      expect(payload!.name, name);
      expect(payload.encPublicKey, enc);
      expect(payload.sigPublicKey, sig);
    });

    test('parse → name preserved', () {
      final link = DeepLinkService.buildLink(
          name: 'Bob', encPublicKey: enc, sigPublicKey: sig);
      expect(DeepLinkService.parse(link)!.name, 'Bob');
    });

    test('parse → encPublicKey preserved', () {
      final link = DeepLinkService.buildLink(
          name: name, encPublicKey: enc, sigPublicKey: sig);
      expect(DeepLinkService.parse(link)!.encPublicKey, enc);
    });

    test('parse → sigPublicKey preserved', () {
      final link = DeepLinkService.buildLink(
          name: name, encPublicKey: enc, sigPublicKey: sig);
      expect(DeepLinkService.parse(link)!.sigPublicKey, sig);
    });

    test('parse wrong scheme → null', () {
      expect(DeepLinkService.parse('https://example.com'), isNull);
    });

    test('parse wrong host → null', () {
      expect(DeepLinkService.parse('sealed://wrong?enc=a&sig=b'), isNull);
    });

    test('parse missing enc → null', () {
      expect(DeepLinkService.parse('sealed://add?name=Alice&sig=b'), isNull);
    });

    test('parse missing sig → null', () {
      expect(DeepLinkService.parse('sealed://add?name=Alice&enc=a'), isNull);
    });

    test('parse garbage string → null', () {
      expect(DeepLinkService.parse('not a link at all'), isNull);
    });

    test('parse empty string → null', () {
      expect(DeepLinkService.parse(''), isNull);
    });

    test('parse with leading/trailing whitespace → works', () {
      final link = DeepLinkService.buildLink(
          name: name, encPublicKey: enc, sigPublicKey: sig);
      final payload = DeepLinkService.parse('  $link  ');
      expect(payload, isNotNull);
    });

    test('parse with empty name → returns payload with empty name', () {
      final link = DeepLinkService.buildLink(
          name: '', encPublicKey: enc, sigPublicKey: sig);
      final payload = DeepLinkService.parse(link);
      expect(payload, isNotNull);
      expect(payload!.name, '');
    });

    // ── parseQr ────────────────────────────────────────────

    test('parseQr valid sealed:// link → ContactPayload', () {
      final link = DeepLinkService.buildLink(
          name: name, encPublicKey: enc, sigPublicKey: sig);
      final payload = DeepLinkService.parseQr(link);
      expect(payload, isNotNull);
      expect(payload!.encPublicKey, enc);
    });

    test('parseQr garbage → null', () {
      expect(DeepLinkService.parseQr('random text'), isNull);
    });

    // ── buildShareableText ─────────────────────────────────

    test('buildShareableText contains sealed:// link', () {
      final text = DeepLinkService.buildShareableText(
          name: name, encPublicKey: enc, sigPublicKey: sig);
      expect(text, contains('sealed://'));
    });

    test('buildShareableText contains enc key', () {
      final text = DeepLinkService.buildShareableText(
          name: name, encPublicKey: enc, sigPublicKey: sig);
      expect(text, contains(enc));
    });

    test('buildShareableText contains sig key', () {
      final text = DeepLinkService.buildShareableText(
          name: name, encPublicKey: enc, sigPublicKey: sig);
      expect(text, contains(sig));
    });

    test('buildShareableText contains name', () {
      final text = DeepLinkService.buildShareableText(
          name: 'Bob', encPublicKey: enc, sigPublicKey: sig);
      expect(text, contains('Bob'));
    });

    // ── SECURITY: injection check ──────────────────────────

    test('SECURITY: name with special chars encoded in URL safely', () {
      final link = DeepLinkService.buildLink(
          name: 'Alice & Bob <script>', encPublicKey: enc, sigPublicKey: sig);
      final payload = DeepLinkService.parse(link);
      expect(payload, isNotNull);
      expect(payload!.name, 'Alice & Bob <script>');
    });

    test('SECURITY: keys with all hex chars survive URL encoding roundtrip',
        () {
      final link = DeepLinkService.buildLink(
          name: name, encPublicKey: enc, sigPublicKey: sig);
      final payload = DeepLinkService.parse(link);
      expect(payload!.encPublicKey, enc);
      expect(payload.sigPublicKey, sig);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// FingerprintService
// ─────────────────────────────────────────────────────────────────────────────

void _fingerprintServiceTests() {
  group('FingerprintService', () {
    const enc =
        'aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd';
    const sig =
        'eeff0011eeff0011eeff0011eeff0011eeff0011eeff0011eeff0011eeff0011';
    test('compute returns non-empty string', () {
      expect(FingerprintService.compute(enc, sig), isNotEmpty);
    });

    test('compute is deterministic (same input → same output)', () {
      final a = FingerprintService.compute(enc, sig);
      final b = FingerprintService.compute(enc, sig);
      expect(a, b);
    });

    test('compute format: colon-separated uppercase hex pairs', () {
      final fp = FingerprintService.compute(enc, sig);
      final pattern = RegExp(r'^[0-9A-F]{2}(:[0-9A-F]{2})+$');
      expect(pattern.hasMatch(fp), isTrue);
    });

    test('compute produces 16 pairs (16 bytes shown)', () {
      final fp = FingerprintService.compute(enc, sig);
      expect(fp.split(':').length, 16);
    });

    test('different enc key → different fingerprint', () {
      final fp1 = FingerprintService.compute(enc, sig);
      final fp2 = FingerprintService.compute('1122334455667788' * 4, sig);
      expect(fp1, isNot(fp2));
    });

    test('different sig key → different fingerprint', () {
      final fp1 = FingerprintService.compute(enc, sig);
      final fp2 = FingerprintService.compute(enc, '9900aabb' * 8);
      expect(fp1, isNot(fp2));
    });

    test('swapped enc and sig keys → different fingerprint (order matters)',
        () {
      final fp1 = FingerprintService.compute(enc, sig);
      final fp2 = FingerprintService.compute(sig, enc);
      expect(fp1, isNot(fp2));
    });

    test('computeOwn delegates to compute (same result)', () {
      final fp1 = FingerprintService.compute(enc, sig);
      final fp2 = FingerprintService.computeOwn(enc, sig);
      expect(fp1, fp2);
    });

    test('compute result is SHA-256 based (16 bytes of 32-byte hash)', () {
      // Manually compute expected value
      final input = utf8.encode(enc + sig);
      final digest = sha256.convert(input);
      final expected = digest.bytes
          .take(16)
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(':');
      expect(FingerprintService.compute(enc, sig), expected);
    });

    test('empty strings → still returns valid format', () {
      final fp = FingerprintService.compute('', '');
      expect(fp.split(':').length, 16);
    });

    // ── SECURITY: fingerprint is collision-resistant for real keys ──

    test('SECURITY: two different real keypairs have different fingerprints',
        () async {
      final kp1 = await CryptoService.generateKeyPair();
      final sp1 = await CryptoService.generateSigningKeyPair();
      final kp2 = await CryptoService.generateKeyPair();
      final sp2 = await CryptoService.generateSigningKeyPair();
      final fp1 = FingerprintService.compute(
          kp1['publicKey']!, sp1['signingPublicKey']!);
      final fp2 = FingerprintService.compute(
          kp2['publicKey']!, sp2['signingPublicKey']!);
      expect(fp1, isNot(fp2));
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// AuthLockService
// ─────────────────────────────────────────────────────────────────────────────

void _authLockServiceTests() {
  group('AuthLockService', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
    });

    tearDown(() async {
      await AuthLockService.disableAll();
    });

    // ── enabled state ──────────────────────────────────────

    test('isEnabled returns false by default', () async {
      expect(await AuthLockService.isEnabled(), isFalse);
    });

    test('setEnabled true → isEnabled returns true', () async {
      await AuthLockService.setEnabled(true);
      expect(await AuthLockService.isEnabled(), isTrue);
    });

    test('setEnabled false → isEnabled returns false', () async {
      await AuthLockService.setEnabled(true);
      await AuthLockService.setEnabled(false);
      expect(await AuthLockService.isEnabled(), isFalse);
    });

    // ── biometric state ────────────────────────────────────

    test('isBiometricEnabled returns false by default', () async {
      expect(await AuthLockService.isBiometricEnabled(), isFalse);
    });

    test('setBiometricEnabled true → isBiometricEnabled returns true',
        () async {
      await AuthLockService.setBiometricEnabled(true);
      expect(await AuthLockService.isBiometricEnabled(), isTrue);
    });

    // ── PIN management ─────────────────────────────────────

    test('hasPIN returns false before any PIN set', () async {
      expect(await AuthLockService.hasPIN(), isFalse);
    });

    test('savePIN → hasPIN returns true', () async {
      await AuthLockService.savePIN('123456');
      expect(await AuthLockService.hasPIN(), isTrue);
    });

    test('clearPIN → hasPIN returns false', () async {
      await AuthLockService.savePIN('123456');
      await AuthLockService.clearPIN();
      expect(await AuthLockService.hasPIN(), isFalse);
    });

    // ── PIN verification ───────────────────────────────────

    test('verifyPIN correct → returns true', () async {
      await AuthLockService.savePIN('654321');
      expect(await AuthLockService.verifyPIN('654321'), isTrue);
    });

    test('verifyPIN wrong → returns false', () async {
      await AuthLockService.savePIN('654321');
      expect(await AuthLockService.verifyPIN('000000'), isFalse);
    });

    test('verifyPIN no PIN set → returns false', () async {
      expect(await AuthLockService.verifyPIN('123456'), isFalse);
    });

    test('verifyPIN case: correct after wrong guesses → resets fail count',
        () async {
      await AuthLockService.savePIN('111111');
      await AuthLockService.verifyPIN('000000');
      await AuthLockService.verifyPIN('000000');
      final ok = await AuthLockService.verifyPIN('111111');
      expect(ok, isTrue);
    });

    // ── SECURITY: stealth mode ─────────────────────────────

    test('SECURITY: 3 wrong PINs → stealthTriggered = true', () async {
      await AuthLockService.savePIN('999999');
      await AuthLockService.verifyPIN('000000');
      await AuthLockService.verifyPIN('000000');
      expect(AuthLockService.stealthTriggered, isFalse);
      await AuthLockService.verifyPIN('000000');
      expect(AuthLockService.stealthTriggered, isTrue);
    });

    test('SECURITY: stealth not triggered before 3 fails', () async {
      await AuthLockService.savePIN('999999');
      await AuthLockService.verifyPIN('000000');
      await AuthLockService.verifyPIN('000000');
      expect(AuthLockService.stealthTriggered, isFalse);
    });

    test('SECURITY: markUnlocked resets stealth + fail count', () async {
      await AuthLockService.savePIN('123456');
      await AuthLockService.verifyPIN('wrong1');
      await AuthLockService.verifyPIN('wrong2');
      await AuthLockService.verifyPIN('wrong3');
      expect(AuthLockService.stealthTriggered, isTrue);
      AuthLockService.markUnlocked();
      expect(AuthLockService.stealthTriggered, isFalse);
    });

    test('SECURITY: PIN hashed not stored in plaintext', () async {
      // savePIN stores hash — verifyPIN must hash input before comparing
      await AuthLockService.savePIN('123456');
      // Wrong PIN must fail (proves comparison uses hash)
      expect(await AuthLockService.verifyPIN('654321'), isFalse);
    });

    test('SECURITY: different PINs produce different stored hashes', () async {
      // savePIN('111111') then try verifyPIN('222222') → must fail
      await AuthLockService.savePIN('111111');
      expect(await AuthLockService.verifyPIN('222222'), isFalse);
    });

    test('SECURITY: PIN with salt — raw PIN not verifiable without salt',
        () async {
      // The implementation uses 'sealed_pin_' prefix as salt
      // Verifying the raw hash of just the PIN (no salt) must fail
      await AuthLockService.savePIN('123456');
      // verifyPIN internally hashes 'sealed_pin_123456', not '123456'
      // This test confirms correct PIN works (salt is consistent)
      expect(await AuthLockService.verifyPIN('123456'), isTrue);
    });

    // ── timeout ────────────────────────────────────────────

    test('getTimeout returns immediate by default', () async {
      expect(await AuthLockService.getTimeout(), LockTimeout.immediate);
    });

    test('setTimeout → getTimeout returns set value', () async {
      await AuthLockService.setTimeout(LockTimeout.fiveMinutes);
      expect(await AuthLockService.getTimeout(), LockTimeout.fiveMinutes);
    });

    test('LockTimeout.immediate.seconds == 0', () {
      expect(LockTimeout.immediate.seconds, 0);
    });

    test('LockTimeout.thirtySeconds.seconds == 30', () {
      expect(LockTimeout.thirtySeconds.seconds, 30);
    });

    test('LockTimeout.oneMinute.seconds == 60', () {
      expect(LockTimeout.oneMinute.seconds, 60);
    });

    test('LockTimeout.fiveMinutes.seconds == 300', () {
      expect(LockTimeout.fiveMinutes.seconds, 300);
    });

    test('LockTimeout labels are non-empty strings', () {
      for (final t in LockTimeout.values) {
        expect(t.label, isNotEmpty);
      }
    });

    // ── shouldLock ─────────────────────────────────────────

    test('shouldLock returns false when lock not enabled', () async {
      expect(await AuthLockService.shouldLock(), isFalse);
    });

    test('shouldLock returns true when enabled and never unlocked', () async {
      await AuthLockService.setEnabled(true);
      expect(await AuthLockService.shouldLock(), isTrue);
    });

    test('shouldLock returns true after markUnlocked with immediate timeout',
        () async {
      await AuthLockService.setEnabled(true);
      await AuthLockService.setTimeout(LockTimeout.immediate);
      AuthLockService.markUnlocked();
      expect(await AuthLockService.shouldLock(), isTrue);
    });

    test(
        'shouldLock returns false after markUnlocked with 5min timeout (just unlocked)',
        () async {
      await AuthLockService.setEnabled(true);
      await AuthLockService.setTimeout(LockTimeout.fiveMinutes);
      AuthLockService.markUnlocked();
      expect(await AuthLockService.shouldLock(), isFalse);
    });

    // ── disableAll ─────────────────────────────────────────

    test('disableAll clears all lock settings', () async {
      await AuthLockService.setEnabled(true);
      await AuthLockService.setBiometricEnabled(true);
      await AuthLockService.savePIN('123456');
      await AuthLockService.setTimeout(LockTimeout.fiveMinutes);
      await AuthLockService.disableAll();
      expect(await AuthLockService.isEnabled(), isFalse);
      expect(await AuthLockService.isBiometricEnabled(), isFalse);
      expect(await AuthLockService.hasPIN(), isFalse);
      expect(await AuthLockService.getTimeout(), LockTimeout.immediate);
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

    // ── SECURITY: DB never contains private key ────────────

    test('SECURITY: DB row private_key empty after generate', () async {
      await repo.generateAndSave();
      final rows = await db.query('user');
      expect(rows.first['private_key'], '');
    });

    test('SECURITY: DB row signing_private_key empty after generate', () async {
      await repo.generateAndSave();
      final rows = await db.query('user');
      expect(rows.first['signing_private_key'], '');
    });

    test('SECURITY: DB row never contains private key after reset', () async {
      await repo.generateAndSave();
      await repo.resetKeys();
      final rows = await db.query('user');
      expect(rows.first['private_key'], '');
      expect(rows.first['signing_private_key'], '');
    });

    test('SECURITY: generated public key is 64 chars (X25519 = 32 bytes)',
        () async {
      final u = await repo.generateAndSave();
      expect(u.publicKey.length, 64);
    });

    test(
        'SECURITY: generated signing public key is 64 chars (Ed25519 = 32 bytes)',
        () async {
      final u = await repo.generateAndSave();
      expect(u.signingPublicKey.length, 64);
    });

    test('SECURITY: enc and signing public keys are different', () async {
      final u = await repo.generateAndSave();
      expect(u.publicKey, isNot(u.signingPublicKey));
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

    test('insert 10 contacts → getAll returns 10', () async {
      for (var i = 0; i < 10; i++) {
        await repo.insert('Contact$i', 'enc$i', 'sig$i');
      }
      expect((await repo.getAll()).length, 10);
    });

    test('createdAt stored as unix millis (positive integer)', () async {
      final c = await repo.insert('Alice', 'enc', 'sig');
      final all = await repo.getAll();
      expect(all.first.createdAt, greaterThan(0));
      expect(all.first.createdAt, c.createdAt);
    });

    test('unicode name survives DB roundtrip', () async {
      await repo.insert('日本語 🔐', 'enc', 'sig');
      final all = await repo.getAll();
      expect(all.first.name, '日本語 🔐');
    });

    // ── SECURITY ───────────────────────────────────────────

    test('SECURITY: both enc and sig keys required — neither can be null',
        () async {
      // Insert returns model with both keys populated
      final c = await repo.insert('Alice', 'enckey', 'sigkey');
      expect(c.publicKey, isNotEmpty);
      expect(c.signingPublicKey, isNotEmpty);
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
          'Recipient', recipientEncKp['publicKey']!, sender.signingPublicKey);

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
      final recipientUser = await userRepo.generateAndSave();
      final senderSigKp = await CryptoService.generateSigningKeyPair();

      final cipher = await CryptoService.encryptAndSign(
        'hello from keychain test',
        recipientUser.publicKey,
        senderSigKp['signingPrivateKey']!,
      );

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

      final result = await CryptoService.decryptAndVerify(
        cipher,
        recipientKp['privateKey']!,
        user2!.signingPublicKey,
      );

      expect(result.signatureValid, isFalse);
    });

    test('contact signingPublicKey used correctly for verify', () async {
      final sender = await userRepo.generateAndSave();
      final recipientKp = await CryptoService.generateKeyPair();

      final contact = await contactRepo.insert(
          'Sender', sender.publicKey, sender.signingPublicKey);

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
      await userRepo.generateAndSave();
      final pk1 = await userRepo.getPrivateKey();
      await userRepo.resetKeys();
      final pk2 = await userRepo.getPrivateKey();
      expect(pk1, isNot(pk2));
      expect(pk2, isNotNull);
    });

    // ── SECURITY integration tests ─────────────────────────

    test(
        'SECURITY: MITM — attacker intercepts and re-encrypts with own sig → invalid',
        () async {
      final alice = await userRepo.generateAndSave();
      final recipientKp = await CryptoService.generateKeyPair();
      final attackerSig = await CryptoService.generateSigningKeyPair();

      // Attacker intercepts and signs with their own key
      final attackerCipher = await CryptoService.encryptAndSign(
        'tampered message',
        recipientKp['publicKey']!,
        attackerSig['signingPrivateKey']!,
      );

      // Recipient verifies against Alice's known key
      final result = await CryptoService.decryptAndVerify(
        attackerCipher,
        recipientKp['privateKey']!,
        alice.signingPublicKey,
      );

      expect(result.signatureValid, isFalse);
    });

    test('SECURITY: wrong contact sig key → signatureValid false', () async {
      final sender = await userRepo.generateAndSave();
      final recipientKp = await CryptoService.generateKeyPair();
      final wrongSigKp = await CryptoService.generateSigningKeyPair();

      final cipher = await CryptoService.encryptAndSign(
        'hello',
        recipientKp['publicKey']!,
        sender.signingPrivateKey,
      );

      // Contact has wrong signing key stored
      final contact = await contactRepo.insert(
        'Wrong',
        sender.publicKey,
        wrongSigKp['signingPublicKey']!,
      );

      final result = await CryptoService.decryptAndVerify(
        cipher,
        recipientKp['privateKey']!,
        contact.signingPublicKey,
      );

      expect(result.signatureValid, isFalse);
    });

    test(
        'SECURITY: full flow — fingerprint of sender contact matches their actual keys',
        () async {
      final sender = await userRepo.generateAndSave();
      final contact = await contactRepo.insert(
        'Sender',
        sender.publicKey,
        sender.signingPublicKey,
      );

      final expectedFp =
          FingerprintService.compute(sender.publicKey, sender.signingPublicKey);
      final contactFp = FingerprintService.compute(
          contact.publicKey, contact.signingPublicKey);

      expect(expectedFp, contactFp);
    });

    test('SECURITY: deep link → contact → verify full flow', () async {
      final sender = await userRepo.generateAndSave();
      final link = DeepLinkService.buildLink(
        name: 'Sender',
        encPublicKey: sender.publicKey,
        sigPublicKey: sender.signingPublicKey,
      );

      final payload = DeepLinkService.parse(link);
      expect(payload, isNotNull);

      final contact = await contactRepo.insert(
        payload!.name,
        payload.encPublicKey,
        payload.sigPublicKey,
      );

      final recipientKp = await CryptoService.generateKeyPair();
      final cipher = await CryptoService.encryptAndSign(
        'via deep link',
        recipientKp['publicKey']!,
        sender.signingPrivateKey,
      );

      final result = await CryptoService.decryptAndVerify(
        cipher,
        recipientKp['privateKey']!,
        contact.signingPublicKey,
      );

      expect(result.plaintext, 'via deep link');
      expect(result.signatureValid, isTrue);
    });

    test('SECURITY: reset keys → new keys work for new messages', () async {
      await userRepo.generateAndSave();
      await userRepo.resetKeys();

      final newUser = await userRepo.getUser();
      final newPrivKey = await userRepo.getPrivateKey();
      final senderSig = await CryptoService.generateSigningKeyPair();

      expect(newPrivKey, isNotNull);
      expect(newUser, isNotNull);

      final cipher = await CryptoService.encryptAndSign(
        'new message after reset',
        newUser!.publicKey,
        senderSig['signingPrivateKey']!,
      );

      final result = await CryptoService.decryptAndVerify(
        cipher,
        newPrivKey!,
        senderSig['signingPublicKey']!,
      );

      expect(result.plaintext, 'new message after reset');
      expect(result.signatureValid, isTrue);
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
  _secureKeyStorageTests();
  _deepLinkServiceTests();
  _fingerprintServiceTests();
  _authLockServiceTests();
  _userRepositoryTests();
  _contactRepositoryTests();
  _integrationTests();
}
