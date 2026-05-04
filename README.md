# 🔐 Sealed

> Offline-first, end-to-end encrypted messaging toolkit. No servers. No accounts. No metadata.

Sealed lets two parties exchange cryptographically signed, encrypted messages over **any channel** — SMS, email, paper — using locally generated keys. Transport layer is irrelevant. Trust is cryptographic.

---

## Features

- **X25519 key exchange** — ephemeral keypair per message → forward secrecy
- **ChaCha20-Poly1305 AEAD** — authenticated encryption, tamper-evident
- **Ed25519 signatures** — sender authentication inside the ciphertext (MITM-proof)
- **Stealth lock mode** — 3 wrong PINs → app shows decoy "No messages" screen
- **Biometric + PIN unlock** — `local_auth` gate on app open
- **Private keys in keychain** — `flutter_secure_storage` (Keychain/Keystore), never SQLite
- **QR code key exchange** — scan to add contact, no manual copy-paste required
- **Key fingerprints** — SHA-256(encKey + sigKey) displayed per contact for out-of-band verification
- **Fully offline** — zero network calls, zero backend
- **Cross-platform** — Android, iOS, Linux, Windows (single codebase)

---

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | Flutter / Dart |
| Encryption | `package:cryptography` — X25519, ChaCha20-Poly1305, Ed25519 |
| Key Storage | `flutter_secure_storage` — platform Keychain / Keystore |
| Database | `sqflite_common_ffi` — SQLite (public keys + contacts only) |
| Auth | `local_auth` — biometric + PIN |
| QR | `mobile_scanner` + `qr_flutter` |
| Hashing | `package:crypto` — SHA-256 (PIN hash, fingerprints) |
| CI/CD | GitHub Actions — test → build → release |

---

## Architecture

```
┌──────────────────────────────────────────┐
│                 UI Layer                 │
│  main.dart — Home / Contacts / Share     │
│  LockGate → LockScreen / PinSetupScreen  │
└────────────────┬─────────────────────────┘
                 │
       ┌─────────▼──────────┐
       │    Repositories     │
       │  UserRepository     │──→ SQLite: public keys only
       │  ContactRepository  │──→ SQLite: contacts (name, pubkeys)
       └─────────┬───────────┘
                 │
       ┌─────────▼──────────┐
       │   CryptoService    │
       │  encryptAndSign()  │
       │  decryptAndVerify()│
       └─────────┬───────────┘
                 │
   ┌─────────────▼────────────────┐
   │         Storage              │
   │  SecureKeyStorage            │──→ Keychain/Keystore: private keys
   │  DatabaseHelper (SQLite FFI) │──→ app.db (v2 schema)
   └──────────────────────────────┘
```

### Wire Format

```
Payload (base64url):
┌─────────────────┬──────────┬───────────────────────────┐
│ Ephemeral Pub   │  Nonce   │ Ciphertext + Poly1305 MAC  │
│    32 bytes     │ 12 bytes │      N + 16 bytes          │
└─────────────────┴──────────┴───────────────────────────┘

Inner plaintext (decrypted JSON):
{ "msg": "<plaintext>", "sig": "<hex Ed25519 signature>" }
```

Signature covers the plaintext **before** encryption. Verification requires the sender's Ed25519 public key, stored per-contact. A wrong or missing key returns `signatureValid: false` — not an exception.

### Key Separation

| Key Type | Algorithm | Storage |
|---|---|---|
| Encryption private key | X25519 | `flutter_secure_storage` |
| Signing private key | Ed25519 | `flutter_secure_storage` |
| Encryption public key | X25519 | SQLite `user` table |
| Signing public key | Ed25519 | SQLite `user` + `contacts` |

Private keys **never** touch SQLite. `UserModel.toMap()` always writes empty strings for private key columns by design.

---

## Database Schema

```sql
-- v2 schema
CREATE TABLE user (
  id                  INTEGER PRIMARY KEY,
  private_key         TEXT NOT NULL,          -- always '' (keychain only)
  public_key          TEXT NOT NULL,
  signing_private_key TEXT NOT NULL,          -- always '' (keychain only)
  signing_public_key  TEXT NOT NULL,
  created_at          INTEGER NOT NULL
);

CREATE TABLE contacts (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  name               TEXT NOT NULL,
  public_key         TEXT NOT NULL,           -- X25519 enc pubkey
  signing_public_key TEXT NOT NULL,           -- Ed25519 sig pubkey
  created_at         INTEGER NOT NULL
);
```

**Migration v1 → v2**: adds `signing_*` columns, then wipes the user row to force key regeneration on next launch.

---

## Installation

### Prerequisites

- Flutter SDK ≥ 3.19 / Dart ≥ 3.3
- Android SDK API 21+ (Android builds)
- Xcode 14+ (iOS builds)
- Linux: `libsqlite3-dev libgtk-3-dev libsecret-1-dev`

### Run

```bash
git clone https://github.com/your-org/sealed.git
cd sealed
flutter pub get
flutter run
```

### Release Builds

```bash
# Android
flutter build apk --release --split-per-abi
flutter build appbundle --release

# iOS
flutter build ipa --release

# Linux
flutter build linux --release

# Windows
flutter build windows --release
```

---

## Usage

### First Launch

Key pair auto-generated on first run. X25519 + Ed25519 keypairs stored immediately — encryption key to Keychain/Keystore, public keys to SQLite.

### Share Your Keys

**Share tab** → enter display name → scan QR or copy link.

Link format:
```
sealed://add?name=Alice&enc=<X25519-hex>&sig=<Ed25519-hex>
```

### Add a Contact

- **Scan QR** — camera scan of contact's QR
- **Paste link** — paste `sealed://` link from clipboard
- **Manual** — enter name + both public keys directly

### Encrypt a Message

```
Home → Encrypt mode → select recipient → type message → Encrypt & Sign
```

Output: base64url blob. Send via any channel.

### Decrypt a Message

```
Home → Decrypt mode → select sender contact → paste blob → Decrypt & Verify
```

Result includes signature badge:

| Badge | Meaning |
|---|---|
| ✅ Green | Signature valid — message authentic |
| ⚠️ Orange | Signature INVALID — tampered, wrong sender, or key mismatch |

### Crypto API

```dart
// Encrypt for recipient, sign with sender's Ed25519 key
final cipher = await CryptoService.encryptAndSign(
  plaintext,
  recipientPublicKeyHex,   // X25519 hex
  signingPrivateKeyHex,    // Ed25519 hex
);

// Decrypt and verify sender signature
final result = await CryptoService.decryptAndVerify(
  ciphertext,              // base64url blob
  privateKeyHex,           // X25519 hex
  senderSigningPublicKeyHex,
);

result.plaintext       // String
result.signatureValid  // bool
```

`CryptoException` thrown on: invalid base64, truncated payload, MAC failure, wrong key, missing fields.

---

## App Lock

Configured in **Settings → App Lock**:

| Option | Detail |
|---|---|
| PIN (6-digit) | SHA-256 hashed, stored in `flutter_secure_storage` |
| Biometric | `local_auth` — fingerprint / Face ID |
| Timeout | Immediate / 30s / 1min / 5min |
| Stealth mode | 3 wrong PINs → decoy "No messages" screen |

Lock state re-checked on every `AppLifecycleState.resumed` via `LockGate` (`WidgetsBindingObserver`).

---

## Configuration

Zero configuration by design. No `.env`, no API keys, no backend.

| Setting | Value | Notes |
|---|---|---|
| DB version | 2 | Auto-migrated on upgrade |
| DB path | `getApplicationSupportDirectory()/app.db` | Platform app data dir |
| Key storage | Platform Keychain/Keystore | Via `flutter_secure_storage` |
| Network | None | Fully offline |

---

## Testing

```bash
flutter test test/all_test.dart
flutter test --coverage
```

Test coverage includes:

- `UserModel` — `toMap`/`fromMap`, private key isolation, `copyWithPrivateKeys`
- `ContactModel` — roundtrip, optional id
- `CryptoService` — keygen, encrypt+sign, decrypt+verify, MITM/tamper/wrong-key scenarios
- `SecureKeyStorage` — write/read/delete (in-memory mock)
- `UserRepository` — full lifecycle with in-memory SQLite
- `ContactRepository` — insert, ordering, delete
- Integration — real crypto ops using repo-sourced keys

**Test isolation**: `DatabaseHelper.overrideDatabase()` injects in-memory SQLite. `FlutterSecureStorage.setMockInitialValues({})` resets keychain mock per test.

CI enforces **60% minimum coverage** and runs `flutter analyze`.

---

## CI/CD

GitHub Actions pipeline (`.github/workflows/dart.yml`):

```
push/PR → test → build-android + build-linux + build-windows
tag (v*) → release (upload APKs + AppImage + Windows zip)
```

Artifacts: split APKs, universal APK, Linux AppImage, Windows zip.

---

## Contributing

1. Fork → `git checkout -b feature/your-feature`
2. Crypto logic stays in `CryptoService` only — no crypto in UI
3. **No network calls** — offline-first, always
4. Tests required for all new logic; mandatory for anything touching crypto
5. Never log or persist plaintext or private keys outside secure storage
6. PR must describe security implications of the change
7. Security-sensitive PRs require maintainer review before merge

---

## Known Limitations

| Issue | Severity | Detail |
|---|---|---|
| Silent key wipe on DB upgrade | 🟠 High | v1→v2 migration deletes user row with no user notification |
| No replay protection | 🟡 Medium | Ciphertexts can be replayed — no timestamp/session binding |
| No message history | 🟡 Medium | Decrypt output not stored — copy before navigating away |

---

## Roadmap

| Priority | Feature |
|---|---|
| 🔴 High | Notify user on DB migration key reset |
| 🟡 Medium | Encrypted local message history |
| 🟡 Medium | Multiple identities |
| 🟢 Low | Localization / i18n |
| 🟢 Low | `SECURITY.md` + threat model doc |

---

## License

[GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.en.html)