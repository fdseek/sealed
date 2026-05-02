import 'package:flutter/material.dart';
import 'auth_lock_service.dart';
import 'lock_screen.dart';

/// Wrap MaterialApp's `home:` or use as `builder:`
/// Handles: initial lock + background→foreground re-lock
class LockGate extends StatefulWidget {
  final Widget child;
  const LockGate({super.key, required this.child});

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate>
    with WidgetsBindingObserver {

  bool _locked = false;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkLock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // app lifecycle: background → resume
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkLock();
  }

  Future<void> _checkLock() async {
    final should = await AuthLockService.shouldLock();
    if (mounted) {
      setState(() {
      _locked = should;
      _checked = true;
    });
    }
  }

  void _unlock() => setState(() => _locked = false);

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()));
    }
    if (_locked) return LockScreen(onUnlocked: _unlock);
    return widget.child;
  }
}