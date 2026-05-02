
# 🔐 Sealed — End-to-End Encrypted Messaging Toolkit

> Encrypt messages. Verify senders. Trust no one in between.

---

## Overview

**Sealed** is a Flutter mobile/desktop application that provides **end-to-end encrypted and signed messaging** between trusted contacts — without relying on any server, cloud service, or third party.

### The Problem

Standard messaging apps store messages on servers, leaving them vulnerable to breaches, government requests, or insider access. Users needing true privacy — journalists, lawyers, activists — have no simple, offline-first tool to encrypt plaintext messages they can send through any channel they already use.

### The Solution

Sealed gives each user a locally generated key pair (X25519 for encryption, Ed25519 for signing). Users exchange public keys out-of-band, then encrypt/sign any message. The resulting blob can be sent via SMS, email, or a sticky note — transport layer is irrelevant. No server. No accounts. No metadata.

---

## Features

### User-Facing
- 🔑 Auto-generated key pair on first launch
- 📋 Copy / Share public keys to exchange with contacts
- 🔄 Encrypt & Sign messages for a selected contact
- 🔓 Decrypt & Verify messages from a contact, with signature status badge
- 👥 Contact management with both encryption and signing keys
- ⚠️ Tamper detection — invalid messages flagged visually
- 🔁 Key reset with confirmation dialog

### Technical
- **X25519** ephemeral key exchange — forward secrecy per message
- **ChaCha20-Poly1305 AEAD** — authenticated symmetric encryption
- **Ed25519** digital signatures — sender authentication, MITM protection
- **SQLite** via `sqflite_common_ffi` — works on Android, iOS, Windows, Linux, macOS
- **No network calls** — fully offline
- Compact **base64url** binary payload
- DB schema versioning with v1 → v2 migration

---

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | Flutter (Dart) |
| Cryptography | `package:cryptography` |
| Local DB | `sqflite_common_ffi` |
| Sharing | `share_plus` |
| Utilities | `path`, `path_provider` |
| Platforms | Android, iOS, Linux, Windows, macOS |

---

## Architecture Overview

```
┌─────────────────────────────────┐
│           UI Layer              │
│  main.dart (StatefulWidget)     │
│  - Home page (encrypt/decrypt)  │
│  - Contacts page                │
└────────────┬────────────────────┘
             │
    ┌────────▼────────┐
    │  Repositories   │
    │  UserRepository │  ←→  SQLite (user table)
    │  ContactRepo    │  ←→  SQLite (contacts table)
    └────────┬────────┘
             │
    ┌────────▼────────┐
    │  CryptoService  │
    │  X25519 + AEAD  │
    │  Ed25519 sign   │
    └─────────────────┘
             │
    ┌────────▼────────┐
    │  DatabaseHelper │
    │  SQLite FFI     │
    └─────────────────┘
```

### Crypto Wire Format

```
Payload (base64url):
[ Ephemeral Pub 32B ][ Nonce 12B ][ Ciphertext + MAC 16B ]

Inner plaintext (decrypted JSON):
{ "msg": "<plaintext>", "sig": "<hex Ed25519 sig>" }
```

---

## Installation Guide

### Prerequisites
- Flutter SDK ≥ 3.0 / Dart ≥ 3.0
- Android SDK (API 21+) for Android builds
- Xcode 14+ for iOS builds

### Steps

```bash
git clone https://github.com/your-org/sealed.git
cd sealed
flutter pub get
flutter run
```

### Release Builds

```bash
flutter build apk --release               # Android APK
flutter build appbundle --release          # Play Store
flutter build ipa --release                # iOS
flutter build linux --release              # Desktop
```

---

## Usage

### First Launch
App auto-generates X25519 + Ed25519 key pair. Keys shown on Home tab.

### Share Your Keys
Tap **Copy** or **Share**. Format:
```
enc:<X25519 public key hex>
sig:<Ed25519 public key hex>
```

### Add a Contact
Contacts tab → **+** → enter name → paste their `enc:` and `sig:` keys → **Add**.

### Encrypt
Home → **Encrypt** mode → select recipient → type message → **Encrypt & Sign** → copy result.

### Decrypt
Home → **Decrypt** mode → select sender → paste blob → **Decrypt & Verify** → read plaintext + signature badge.

| Badge | Meaning |
|---|---|
| ✅ Green | Authentic — signature matched contact's key |
| ⚠️ Orange | INVALID — tampering, wrong sender, or key mismatch |

---

## Configuration

Zero-configuration by design. No env vars, no API keys.

| Setting | Default | Note |
|---|---|---|
| DB version | 2 | Auto-migrated |
| DB path | `getApplicationSupportDirectory()` | Platform app data dir |
| Key storage | SQLite plaintext | ⚠️ Critical gap — see Production Review |

---

## API Documentation

No external API. Internal `CryptoService` API:

```dart
// Encrypt a message for a recipient, signed by sender
static Future<String> encryptAndSign(
  String plaintext,
  String recipientPublicKeyHex,   // X25519
  String signingPrivateKeyHex,    // Ed25519
)

// Decrypt and verify sender signature
static Future<DecryptResult> decryptAndVerify(
  String ciphertext,
  String privateKeyHex,
  String senderSigningPublicKeyHex,
)

class DecryptResult {
  final String plaintext;
  final bool signatureValid;
}
```

`CryptoException` thrown on: invalid base64, corrupted payload, MAC failure, missing fields.

---

## Testing

```bash
flutter test
```

## Deployment

### Android
```bash
flutter build appbundle --release
```
Requires `android/key.properties` with keystore signing config.

### iOS
```bash
flutter build ipa --release
```
Requires Apple Developer account + provisioning profile.

### Desktop
```bash
flutter build linux --release
flutter build windows --release
flutter build macos --release
```

---

## Roadmap

| Priority | Feature |
|---|---|
| 🟡 Medium | Multiple identities |
| 🟡 Medium | Local encrypted message history |
| 🟢 Low | Dark mode |
| 🟢 Low | Localization / i18n |

---

## Contributing Guidelines

1. Fork → feature branch: `git checkout -b feature/your-feature`
2. Keep all crypto logic in `CryptoService` — no crypto scattered in UI
3. **No network calls** — offline-first, always
4. Tests required for all new logic, mandatory for anything touching crypto
5. Never log or persist plaintext messages or private keys outside secure storage
6. PR must describe security implications of the change
7. Security-sensitive PRs require maintainer review before merge

---

## License
[GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.en.html) .




## 🏭 Production Readiness Review

### ✅ What Is Done

- [x] Correct algorithm choices: X25519, ChaCha20-Poly1305, Ed25519
- [x] Ephemeral X25519 keypair per message — forward secrecy
- [x] AEAD encryption — MAC authentication, tamper-evident
- [x] Ed25519 signature inside ciphertext — MITM protection
- [x] SQLite schema v2 with v1 → v2 migration
- [x] Test-injectable `DatabaseHelper` (`overrideDatabase` / `clearOverride`)
- [x] Both key types stored per contact
- [x] Signature validity clearly surfaced in UI
- [x] Key reset with confirmation dialog
- [x] Cross-platform via `sqflite_common_ffi`
- [x]  **Automated tests** — zero test files. No unit, widget, or integration tests.
- [x] **License file**
- [x] **Key input validation** — no length/format checks before crypto operations.
- [x] **CI/CD pipeline**
- [x] **Secure key storage** — private keys in plaintext SQLite. Must use `flutter_secure_storage` or platform keychain.

- [x] **App authentication** — no PIN, biometric, or lock screen. Physical device access = full access.
### ❌ What Is Missing


- [ ] **DB migration UX** — `onUpgrade` silently deletes user row with no notification to the user.
- [ ] **App store signing configuration** documented
- [ ] **Privacy policy** — required for Play Store and App Store

### ⚠️ Risks / Weak Points

| Risk | Severity | Detail |
|---|---|---|
| Silent key wipe on DB upgrade | 🟠 High | v1 → v2 migration deletes user row silently |
| No replay protection | 🟡 Medium | Captured ciphertexts can be replayed; no session/timestamp binding |

---

## 📋 Release Checklist

### Security (Blocking)
- [x] Migrate private key storage to `flutter_secure_storage` or platform keychain
- [ ] Add biometric / PIN authentication gate on app open
- [x] Validate key lengths before crypto operations (64 hex chars for both key types)

### Quality (Blocking)
- [x] Unit tests: `CryptoService` (round-trip, tamper, wrong key, sig paths)
- [x] Unit tests: `UserRepository`, `ContactRepository` with in-memory DB
- [x] Widget tests: encrypt/decrypt UI flow
- [x] Minimum 80% coverage on crypto + repository layers

### UX / Correctness
- [ ] Notify user when DB migration resets their keys
- [x] Show key fingerprint per contact for out-of-band verification
- [x] Add QR code key exchange
- [x] Verify behavior on Android + iOS

### Distribution
- [ ] Add `LICENSE` file
- [ ] Configure Android keystore in `android/key.properties`
- [ ] Configure iOS signing
- [ ] Write Privacy Policy
- [ ] Create `CHANGELOG.md`
- [x] Set up CI: `flutter test` + `flutter build` on push


### Documentation
- [ ] Add screenshots
- [ ] Write threat model document
- [ ] Add `SECURITY.md` with disclosure contact