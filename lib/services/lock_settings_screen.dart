import 'package:flutter/material.dart';
import 'auth_lock_service.dart';
import 'pin_setup_screen.dart';

class LockSettingsScreen extends StatefulWidget {
  const LockSettingsScreen({super.key});
  @override
  State<LockSettingsScreen> createState() => _LockSettingsScreenState();
}

class _LockSettingsScreenState extends State<LockSettingsScreen> {
  bool _enabled = false;
  bool _biometric = false;
  bool _hasPIN = false;
  bool _bioAvailable = false;
  LockTimeout _timeout = LockTimeout.immediate;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final en = await AuthLockService.isEnabled();
    final bio = await AuthLockService.isBiometricEnabled();
    final pin = await AuthLockService.hasPIN();
    final t = await AuthLockService.getTimeout();
    final av = await AuthLockService.biometricAvailable();
    setState(() {
      _enabled = en;
      _biometric = bio;
      _hasPIN = pin;
      _timeout = t;
      _bioAvailable = av;
      _loading = false;
    });
  }

  Future<void> _toggleEnabled(bool v) async {
    if (v && !_hasPIN) {
      final set = await Navigator.push<bool>(
          context, MaterialPageRoute(builder: (_) => const PinSetupScreen()));
      if (set != true) return; // user cancelled PIN setup
      _hasPIN = true;
    }
    await AuthLockService.setEnabled(v);
    setState(() => _enabled = v);
  }

  Future<void> _toggleBiometric(bool v) async {
    await AuthLockService.setBiometricEnabled(v);
    setState(() => _biometric = v);
  }

  Future<void> _setupPIN() async {
    final ok = await Navigator.push<bool>(context,
        MaterialPageRoute(builder: (_) => PinSetupScreen(isChange: _hasPIN)));
    if (ok == true) setState(() => _hasPIN = true);
  }

  Future<void> _changeTimeout(LockTimeout t) async {
    await AuthLockService.setTimeout(t);
    setState(() => _timeout = t);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('App Lock')),
      body: ListView(
        children: [
          // ── master toggle ──
          SwitchListTile(
            title: const Text('Enable App Lock'),
            subtitle: Text(_enabled ? 'App is protected' : 'Tap to enable'),
            secondary: Icon(
              _enabled ? Icons.lock : Icons.lock_open,
              color: _enabled
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            value: _enabled,
            onChanged: _toggleEnabled,
          ),

          const Divider(height: 1),

          if (_enabled) ...[
            // ── biometric ──
            if (_bioAvailable)
              SwitchListTile(
                title: const Text('Biometric Unlock'),
                subtitle: const Text('Fingerprint / Face ID'),
                secondary: const Icon(Icons.fingerprint),
                value: _biometric,
                onChanged: _toggleBiometric,
              ),

            // ── PIN ──
            ListTile(
              leading: const Icon(Icons.pin),
              title: Text(_hasPIN ? 'Change PIN' : 'Set PIN'),
              subtitle: Text(_hasPIN ? '6-digit PIN configured' : 'No PIN set'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _setupPIN,
            ),

            const Divider(height: 1),

            // ── timeout ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Lock after',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.outline)),
            ),
            RadioGroup<LockTimeout>(
              groupValue: _timeout,
              onChanged: (LockTimeout? v) {
                if (v != null) _changeTimeout(v);
              },
              child: Column(
                children: LockTimeout.values.map((t) {
                  return RadioListTile<LockTimeout>(
                    title: Text(t.label),
                    value: t,
                  );
                }).toList(),
              ),
            ),
            
            const Divider(height: 1),

            // ── stealth info ──
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: theme.colorScheme.outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '3 wrong PINs → stealth mode activates',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
