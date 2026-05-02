import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

enum LockTimeout { immediate, thirtySeconds, oneMinute, fiveMinutes }

extension LockTimeoutExt on LockTimeout {
  int get seconds => switch (this) {
    LockTimeout.immediate     => 0,
    LockTimeout.thirtySeconds => 30,
    LockTimeout.oneMinute     => 60,
    LockTimeout.fiveMinutes   => 300,
  };

  String get label => switch (this) {
    LockTimeout.immediate     => 'Immediately',
    LockTimeout.thirtySeconds => 'After 30 seconds',
    LockTimeout.oneMinute     => 'After 1 minute',
    LockTimeout.fiveMinutes   => 'After 5 minutes',
  };
}

class AuthLockService {
  static const _storage = FlutterSecureStorage();
  static final _localAuth = LocalAuthentication();

  static const _kEnabled        = 'lock_enabled';
  static const _kBiometric      = 'lock_biometric';
  static const _kPinHash        = 'lock_pin_hash';
  static const _kTimeout        = 'lock_timeout';
  //static const _kFailCount      = 'lock_fail_count';

  // ── state ─────────────────────────────────────────────
  static DateTime? _lastUnlocked;
  static int _failCount = 0;
  static bool _stealthTriggered = false;

  static bool get stealthTriggered => _stealthTriggered;

  // ── settings read ─────────────────────────────────────

  static Future<bool> isEnabled() async =>
      (await _storage.read(key: _kEnabled)) == 'true';

  static Future<bool> isBiometricEnabled() async =>
      (await _storage.read(key: _kBiometric)) == 'true';

  static Future<bool> hasPIN() async =>
      (await _storage.read(key: _kPinHash)) != null;

  static Future<LockTimeout> getTimeout() async {
    final v = await _storage.read(key: _kTimeout);
    return LockTimeout.values.firstWhere(
      (t) => t.name == v,
      orElse: () => LockTimeout.immediate,
    );
  }

  static Future<bool> biometricAvailable() async {
    try {
      return await _localAuth.canCheckBiometrics ||
             await _localAuth.isDeviceSupported();
    } catch (_) { return false; }
  }

  // ── settings write ────────────────────────────────────

  static Future<void> setEnabled(bool v) =>
      _storage.write(key: _kEnabled, value: v.toString());

  static Future<void> setBiometricEnabled(bool v) =>
      _storage.write(key: _kBiometric, value: v.toString());

  static Future<void> setTimeout(LockTimeout t) =>
      _storage.write(key: _kTimeout, value: t.name);

  static Future<void> savePIN(String pin) async {
    final hash = _hashPin(pin);
    await _storage.write(key: _kPinHash, value: hash);
    _failCount = 0;
  }

  static Future<void> clearPIN() =>
      _storage.delete(key: _kPinHash);

  static Future<void> disableAll() async {
    await _storage.delete(key: _kEnabled);
    await _storage.delete(key: _kBiometric);
    await _storage.delete(key: _kPinHash);
    await _storage.delete(key: _kTimeout);
    _lastUnlocked = null;
    _stealthTriggered = false;
  }

  // ── lock logic ────────────────────────────────────────

  /// true = screen should be locked right now
  static Future<bool> shouldLock() async {
    if (!await isEnabled()) return false;
    if (_lastUnlocked == null) return true;
    final timeout = await getTimeout();
    if (timeout.seconds == 0) return true;
    final elapsed = DateTime.now().difference(_lastUnlocked!).inSeconds;
    return elapsed >= timeout.seconds;
  }

  static void markUnlocked() {
    _lastUnlocked = DateTime.now();
    _failCount = 0;
    _stealthTriggered = false;
  }

  // ── auth methods ──────────────────────────────────────

  /// Returns true on success
  static Future<bool> authenticateBiometric() async {
    try {
      return await _localAuth.authenticate(
        localizedReason: 'Unlock Sealed',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } catch (_) { return false; }
  }

  /// Returns true on correct PIN; triggers stealth after 3 fails
  static Future<bool> verifyPIN(String pin) async {
    final stored = await _storage.read(key: _kPinHash);
    if (stored == null) return false;

    if (_hashPin(pin) == stored) {
      _failCount = 0;
      return true;
    }

    _failCount++;
    if (_failCount >= 3) {
      _stealthTriggered = true;
    }
    return false;
  }

  // ── helpers ───────────────────────────────────────────

  static String _hashPin(String pin) {
    final bytes = utf8.encode('sealed_pin_$pin');
    return sha256.convert(bytes).toString();
  }
}