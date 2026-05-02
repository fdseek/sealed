import 'package:flutter/material.dart';
import 'auth_lock_service.dart';
import 'lock_screen.dart'; // reuses _Numpad

class PinSetupScreen extends StatefulWidget {
  final bool isChange;
  const PinSetupScreen({super.key, this.isChange = false});

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  List<String> _pin = [];
  List<String>? _firstPin;
  String _label = 'Enter new PIN';
  String? _error;
  static const _len = 6;

  void _onKey(String d) {
    if (_pin.length >= _len) return;
    setState(() { _pin.add(d); _error = null; });
    if (_pin.length == _len) _next();
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin.removeLast());
  }

  Future<void> _next() async {
    if (_firstPin == null) {
      setState(() {
        _firstPin = List.from(_pin);
        _pin = [];
        _label = 'Confirm PIN';
      });
    } else {
      if (_pin.join() == _firstPin!.join()) {
        await AuthLockService.savePIN(_pin.join());
        if (mounted) Navigator.pop(context, true);
      } else {
        setState(() {
          _pin = [];
          _firstPin = null;
          _label = 'Enter new PIN';
          _error = 'PINs do not match. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.isChange ? 'Change PIN' : 'Set PIN')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_label, style: theme.textTheme.titleMedium),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_len, (i) {
                  final filled = i < _pin.length;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    width: 14, height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                    ),
                  );
                }),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 32),
              Numpad(onKey: _onKey, onBackspace: _backspace),
            ],
          ),
        ),
      ),
    );
  }
}