import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'auth_lock_service.dart';

class LockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;
  const LockScreen({super.key, required this.onUnlocked});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final List<String> _pin = [];
  String? _error;
  bool _showPIN = false;
  bool _biometricAvailable = false;
  bool _biometricEnabled = false;
  bool _hasPIN = false;

  static const _pinLength = 6;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final bioAvail   = await AuthLockService.biometricAvailable();
    final bioEnabled = await AuthLockService.isBiometricEnabled();
    final hasPin     = await AuthLockService.hasPIN();
    setState(() {
      _biometricAvailable = bioAvail;
      _biometricEnabled   = bioEnabled;
      _hasPIN             = hasPin;
      _showPIN            = !bioEnabled || !bioAvail;
    });
    if (_biometricEnabled && bioAvail) _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    final ok = await AuthLockService.authenticateBiometric();
    if (ok) {
      AuthLockService.markUnlocked();
      widget.onUnlocked();
    } else {
      if (_hasPIN) setState(() => _showPIN = true);
    }
  }

  void _onKey(String digit) {
    if (_pin.length >= _pinLength) return;
    setState(() {
      _pin.add(digit);
      _error = null;
    });
    if (_pin.length == _pinLength) _submitPIN();
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin.removeLast());
  }

  Future<void> _submitPIN() async {
    final input = _pin.join();
    final ok = await AuthLockService.verifyPIN(input);

    if (AuthLockService.stealthTriggered) {
      // stealth: show fake "No messages" screen
      if (mounted) {
        setState(() {
        _pin.clear();
        _error = null;
        _showPIN = false;
      });
      }
      return;
    }

    if (ok) {
      AuthLockService.markUnlocked();
      widget.onUnlocked();
    } else {
      setState(() {
        _pin.clear();
        _error = 'Wrong PIN';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // stealth mode → blank screen
    if (AuthLockService.stealthTriggered && !_showPIN) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Text('No messages', style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 48),

                  // icon
                  Icon(Icons.lock_outline,
                    size: 48, color: colorScheme.primary),
                  const SizedBox(height: 16),
                  Text('Sealed', style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('Enter PIN to continue',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: colorScheme.outline)),

                  const SizedBox(height: 40),

                  if (_showPIN) ...[
                    // dots
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(_pinLength, (i) {
                        final filled = i < _pin.length;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          width: 14, height: 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: filled
                                ? colorScheme.primary
                                : colorScheme.outlineVariant,
                          ),
                        );
                      }),
                    ),

                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!,
                        style: TextStyle(
                          color: colorScheme.error, fontSize: 13)),
                    ],

                    const SizedBox(height: 36),

                    // numpad
                    Numpad(onKey: _onKey, onBackspace: _backspace),

                    const SizedBox(height: 24),

                    // biometric fallback button
                    if (_biometricAvailable && _biometricEnabled)
                      TextButton.icon(
                        onPressed: _tryBiometric,
                        icon: const Icon(Icons.fingerprint, size: 20),
                        label: const Text('Use biometric'),
                      ),
                  ] else ...[
                    // biometric primary
                    FilledButton.icon(
                      onPressed: _tryBiometric,
                      icon: const Icon(Icons.fingerprint),
                      label: const Text('Unlock with Biometric'),
                    ),
                    if (_hasPIN) ...[
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => setState(() => _showPIN = true),
                        child: const Text('Use PIN instead'),
                      ),
                    ],
                  ],

                  const SizedBox(height: 48),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Numpad ──────────────────────────────────────────────

class Numpad extends StatelessWidget {
  final void Function(String) onKey;
  final VoidCallback onBackspace;
  const Numpad({super.key, required this.onKey, required this.onBackspace});

  @override
  Widget build(BuildContext context) {
    final keys = [
      ['1','2','3'],
      ['4','5','6'],
      ['7','8','9'],
      ['', '0', '⌫'],
    ];
    return Column(
      children: keys.map((row) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: row.map((k) {
          if (k.isEmpty) return const SizedBox(width: 80, height: 64);
          return _NumKey(label: k,
            onTap: k == '⌫' ? onBackspace : () => onKey(k));
        }).toList(),
      )).toList(),
    );
  }
}

class _NumKey extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _NumKey({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    return SizedBox(
      width: 80, height: 64,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(40),
        child: Center(
          child: Text(label,
            style: TextStyle(fontSize: 22,
              color: color.onSurface, fontWeight: FontWeight.w400)),
        ),
      ),
    );
  }
}