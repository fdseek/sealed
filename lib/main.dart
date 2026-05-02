import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sealed_app/services/crypto_service.dart';
import 'package:sealed_app/services/fingerprint_service.dart';
import 'package:sealed_app/services/lock_gate.dart';
import 'package:sealed_app/services/lock_settings_screen.dart';
import 'package:sealed_app/services/share_screen_service.dart';
import 'db/database_helper.dart';
import 'models/user_model.dart';
import 'models/contact_model.dart';
import 'repositories/user_repository.dart';
import 'repositories/contact_repository.dart';
import 'services/deep_link_service.dart';

/// Camera scanning only supported on Android / iOS.
bool get _cameraSupported =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.initFfi();
  runApp(const NavigationBarApp());
}

class NavigationBarApp extends StatelessWidget {
  const NavigationBarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: LockGate(
        child: const AppNavigation(),
      ),
    );
  }
}

class AppNavigation extends StatefulWidget {
  const AppNavigation({super.key});

  @override
  State<AppNavigation> createState() => _AppNavigationState();
}

class _AppNavigationState extends State<AppNavigation> {
  int currentPageIndex = 0;

  final _userRepo = UserRepository();
  final _contactRepo = ContactRepository();

  UserModel? _user;
  List<ContactModel> _contacts = [];
  bool _loading = true;

  // home state
  ContactModel? _selectedContact;
  bool _isEncrypt = true;
  final TextEditingController _inputController = TextEditingController();
  String _result = '';
  String? _errorMessage;
  bool _processing = false;
  bool? _lastSigValid;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    var user = await _userRepo.getUser();
    user ??= await _userRepo.generateAndSave();
    final contacts = await _contactRepo.getAll();
    setState(() {
      _user = user;
      _contacts = contacts;
      _loading = false;
    });
    // check clipboard on startup for valid contact link
    _checkClipboardForContact();
  }

  /// On open: sniff clipboard → prompt if valid sealed:// link found
  Future<void> _checkClipboardForContact() async {
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text ?? '';
      if (text.isEmpty) return;
      final linkMatch =
          RegExp(r'sealed://\S+').firstMatch(text)?.group(0) ?? text;
      final payload = DeepLinkService.parse(linkMatch);
      if (payload == null) return;
      if (!mounted) return;
      // small delay so UI settles
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      await _showConfirmAddContact(payload);
    } catch (_) {}
  }

  // ─── Key actions ─────────────────────────────────────

  Future<void> _resetKeys() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Keys'),
        content: const Text(
            'This will generate a new key pair. Your old keys will be lost forever. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final newUser = await _userRepo.resetKeys();
    setState(() {
      _user = newUser;
      _selectedContact = null;
      _result = '';
      _errorMessage = null;
      _lastSigValid = null;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('New key pair generated')),
      );
    }
  }

  // ─── Add Contact entry point ─────────────────────────

  /// FAB → bottom sheet with 3 options
  void _openAddContactSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text('Add Contact',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_cameraSupported)
              ListTile(
                leading: const Icon(Icons.qr_code_scanner),
                title: const Text('Scan QR Code'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openQrScanner();
                },
              ),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Paste from Clipboard'),
              onTap: () {
                Navigator.pop(ctx);
                _pasteAndAdd();
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Enter Manually'),
              onTap: () {
                Navigator.pop(ctx);
                _showAddContactDialog();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ─── QR Scanner ──────────────────────────────────────

void _openQrScanner() {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => _QrScannerPage(
      onDetected: (payload) async {
        Navigator.pop(context);
        await _showConfirmAddContact(payload);
      },
    )),
  );
}
  // ─── Paste ───────────────────────────────────────────

  Future<void> _pasteAndAdd() async {
    final data = await Clipboard.getData('text/plain');
    if (!mounted) return;
    final text = data?.text ?? '';
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clipboard is empty')),
      );
      return;
    }
    final linkMatch =
        RegExp(r'sealed://\S+').firstMatch(text)?.group(0) ?? text;
    final payload = DeepLinkService.parse(linkMatch);
    if (payload == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No valid Sealed link found')),
      );
      return;
    }
    await _showConfirmAddContact(payload);
  }

  // ─── Confirm add contact dialog ───────────────────────

  Future<void> _showConfirmAddContact(ContactPayload payload) async {
    final nameCtrl =
        TextEditingController(text: payload.name.isEmpty ? '' : payload.name);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Contact?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Contact info from link:'),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              _KeyPreview(
                  label: 'Encryption Key', value: payload.encPublicKey),
              const SizedBox(height: 8),
              _KeyPreview(label: 'Signing Key', value: payload.sigPublicKey),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add Contact'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed == true) {
      final name = nameCtrl.text.trim().isEmpty
          ? (payload.name.isEmpty ? 'Unknown' : payload.name)
          : nameCtrl.text.trim();
      try {
        final contact = await _contactRepo.insert(
            name, payload.encPublicKey, payload.sigPublicKey);
        setState(() => _contacts.insert(0, contact));
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$name added')));
          setState(() => currentPageIndex = 1); // jump to contacts tab
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed: ${e.toString()}')));
        }
      }
    }
  }

  // ─── Manual add contact dialog ────────────────────────

  Future<void> _showAddContactDialog({ContactModel? prefill}) async {
    final nameCtrl = TextEditingController(text: prefill?.name ?? '');
    final encKeyCtrl = TextEditingController(text: prefill?.publicKey ?? '');
    final sigKeyCtrl =
        TextEditingController(text: prefill?.signingPublicKey ?? '');

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Contact'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: encKeyCtrl,
                decoration: const InputDecoration(
                  labelText: 'Encryption Public Key (enc:...)',
                  border: OutlineInputBorder(),
                  helperText: 'X25519 key for encrypting messages',
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: sigKeyCtrl,
                decoration: const InputDecoration(
                  labelText: 'Signing Public Key (sig:...)',
                  border: OutlineInputBorder(),
                  helperText: 'Ed25519 key for verifying messages',
                ),
                maxLines: 3,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final encKey =
                  encKeyCtrl.text.trim().replaceFirst(RegExp(r'^enc:'), '');
              final sigKey =
                  sigKeyCtrl.text.trim().replaceFirst(RegExp(r'^sig:'), '');
              if (name.isEmpty || encKey.isEmpty || sigKey.isEmpty) return;
              final contact = await _contactRepo.insert(name, encKey, sigKey);
              setState(() => _contacts.insert(0, contact));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _removeContact(int index) async {
    final contact = _contacts[index];
    if (contact.id == null) return;
    await _contactRepo.delete(contact.id!);
    setState(() {
      _contacts.removeAt(index);
      if (_selectedContact?.id == contact.id) _selectedContact = null;
    });
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('${contact.name} removed')));
    }
  }

  Future<void> _confirmRemove(int index) async {
    final contact = _contacts[index];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Contact'),
        content: Text('Remove ${contact.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm == true) await _removeContact(index);
  }

  // ─── Fingerprint dialog ───────────────────────────────

  void _showFingerprintDialog(
      BuildContext context, ContactModel contact, ThemeData theme) {
    final fp =
        FingerprintService.compute(contact.publicKey, contact.signingPublicKey);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.verified_user, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                contact.name,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Key Fingerprint', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                fp,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 1.5,
                  color: theme.colorScheme.primary,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Ask ${contact.name} to read their fingerprint aloud '
              'and verify it matches exactly.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: fp));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Fingerprint copied')));
              Navigator.pop(ctx);
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  // ─── Crypto actions ───────────────────────────────────

  Future<void> _processText() async {
    final input = _inputController.text.trim();
    setState(() {
      _errorMessage = null;
      _result = '';
      _lastSigValid = null;
    });

    if (input.isEmpty) {
      setState(() => _errorMessage = 'Please enter a message');
      return;
    }

    if (_isEncrypt && _selectedContact == null) {
      setState(() => _errorMessage = 'Select a contact to encrypt for');
      return;
    }

    setState(() => _processing = true);

    try {
      if (_isEncrypt) {
        final signingPrivateKey = await _userRepo.getSigningPrivateKey();
        if (signingPrivateKey == null) {
          setState(() => _errorMessage = 'No signing key found. Reset keys.');
          return;
        }
        final encrypted = await CryptoService.encryptAndSign(
          input,
          _selectedContact!.publicKey,
          signingPrivateKey,
        );
        setState(() => _result = encrypted);
      } else {
        if (_selectedContact == null) {
          setState(() =>
              _errorMessage = 'Select sender contact to verify signature');
          return;
        }
        final privateKey = await _userRepo.getPrivateKey();
        if (privateKey == null) {
          setState(() => _errorMessage = 'No private key found. Reset keys.');
          return;
        }
        final decryptResult = await CryptoService.decryptAndVerify(
          input,
          privateKey,
          _selectedContact!.signingPublicKey,
        );
        setState(() {
          _result = decryptResult.plaintext;
          _lastSigValid = decryptResult.signatureValid;
        });
      }
    } on CryptoException catch (e) {
      setState(() => _errorMessage = e.message);
    } catch (e) {
      setState(() => _errorMessage = 'Unexpected error: ${e.toString()}');
    } finally {
      setState(() => _processing = false);
    }
  }

  void _copyResult() {
    if (_result.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _result));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
  }

  // ─── Home page ────────────────────────────────────────

  Widget _buildHomePage(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your Identity', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onLongPress: () {
                      if (_user == null) return;
                      final fp = FingerprintService.computeOwn(
                          _user!.publicKey, _user!.signingPublicKey);
                      Clipboard.setData(ClipboardData(text: fp));
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Fingerprint copied')));
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Fingerprint',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.colorScheme.outline),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _user != null
                                ? FingerprintService.computeOwn(
                                    _user!.publicKey, _user!.signingPublicKey)
                                : '—',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontFamily: 'monospace',
                              letterSpacing: 1.4,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Long-press to copy',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.colorScheme.outline),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () =>
                              setState(() => currentPageIndex = 2),
                          icon: const Icon(Icons.qr_code_2, size: 16),
                          label: const Text('Share QR'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _resetKeys,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Reset'),
                        style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          Text('Mode', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: true,
                label: Text('Encrypt'),
                icon: Icon(Icons.lock_outline),
              ),
              ButtonSegment(
                value: false,
                label: Text('Decrypt'),
                icon: Icon(Icons.lock_open_outlined),
              ),
            ],
            selected: {_isEncrypt},
            onSelectionChanged: (val) => setState(() {
              _isEncrypt = val.first;
              _result = '';
              _errorMessage = null;
              _lastSigValid = null;
              _inputController.clear();
              _selectedContact = null;
            }),
          ),

          const SizedBox(height: 20),

          Text(
            _isEncrypt ? 'Recipient' : 'Sender (for signature verification)',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<ContactModel>(
            initialValue: _selectedContact,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText:
                  _isEncrypt ? 'Select recipient' : 'Select sender contact',
            ),
            items: _contacts
                .map((c) => DropdownMenuItem(
                      value: c,
                      child: Text(c.name),
                    ))
                .toList(),
            onChanged: (val) => setState(() => _selectedContact = val),
          ),
          const SizedBox(height: 20),

          Text('Input', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          TextField(
            controller: _inputController,
            maxLines: 5,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: _isEncrypt
                  ? 'Enter message to encrypt...'
                  : 'Paste encrypted message...',
            ),
          ),

          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _processing ? null : _processText,
              icon: _processing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Icon(_isEncrypt ? Icons.lock : Icons.lock_open),
              label: Text(_isEncrypt ? 'Encrypt & Sign' : 'Decrypt & Verify'),
            ),
          ),

          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline,
                      color: Colors.red.shade700, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(color: Colors.red.shade700),
                    ),
                  ),
                ],
              ),
            ),
          ],

          if (!_isEncrypt && _lastSigValid != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _lastSigValid!
                    ? Colors.green.shade50
                    : Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _lastSigValid!
                      ? Colors.green.shade300
                      : Colors.orange.shade300,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _lastSigValid! ? Icons.verified_user : Icons.warning_amber,
                    color: _lastSigValid!
                        ? Colors.green.shade700
                        : Colors.orange.shade700,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _lastSigValid!
                          ? 'Signature valid — message is authentic'
                          : '⚠ Signature INVALID — possible tampering or wrong sender',
                      style: TextStyle(
                        color: _lastSigValid!
                            ? Colors.green.shade700
                            : Colors.orange.shade700,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          if (_result.isNotEmpty) ...[
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Result', style: theme.textTheme.labelLarge),
                IconButton(
                  onPressed: _copyResult,
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy',
                ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outline),
              ),
              child: SelectableText(
                _result,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontFamily: 'monospace'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─── Contact page ─────────────────────────────────────

  Widget _buildContactPage(ThemeData theme) {
    if (_contacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline,
                size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            const Text(
              'No contacts yet.\nTap + to add one.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _contacts.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final contact = _contacts[index];
        final initials = contact.name
            .trim()
            .split(' ')
            .where((w) => w.isNotEmpty)
            .take(2)
            .map((w) => w[0].toUpperCase())
            .join();

        final fingerprint = FingerprintService.compute(
            contact.publicKey, contact.signingPublicKey);

        return Dismissible(
          key: ValueKey(contact.id ?? index),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            color: Colors.red,
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          confirmDismiss: (_) async {
            bool confirmed = false;
            await showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Remove Contact'),
                content: Text('Remove ${contact.name}?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    style:
                        FilledButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: () {
                      confirmed = true;
                      Navigator.pop(ctx);
                    },
                    child: const Text('Remove'),
                  ),
                ],
              ),
            );
            return confirmed;
          },
          onDismissed: (_) => _removeContact(index),
          child: ListTile(
            leading: CircleAvatar(child: Text(initials)),
            title: Text(contact.name),
            subtitle: Row(
              children: [
                Icon(Icons.fingerprint,
                    size: 12, color: theme.colorScheme.primary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    fingerprint,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      letterSpacing: 1.0,
                      color: theme.colorScheme.primary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            onTap: () => _showFingerprintDialog(context, contact, theme),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () => _confirmRemove(index),
            ),
          ),
        );
      },
    );
  }

  // ─── Share page ───────────────────────────────────────

  Widget _buildSharePage() {
    return ShareScreen(user: _user);
  }

  // ─── Build ────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.security),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LockSettingsScreen()),
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        onDestinationSelected: (i) => setState(() => currentPageIndex = i),
        indicatorColor: Colors.amber,
        selectedIndex: currentPageIndex,
        destinations: const [
          NavigationDestination(
            selectedIcon: Icon(Icons.home),
            icon: Icon(Icons.home_outlined),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.contact_mail),
            label: 'Contacts',
          ),
          NavigationDestination(
            selectedIcon: Icon(Icons.qr_code_2),
            icon: Icon(Icons.qr_code_2_outlined),
            label: 'Share',
          ),
        ],
      ),
      floatingActionButton: currentPageIndex == 1
          ? FloatingActionButton(
              onPressed: _openAddContactSheet,
              child: const Icon(Icons.add),
            )
          : null,
      body: IndexedStack(
        index: currentPageIndex,
        children: [
          _buildHomePage(theme),
          _buildContactPage(theme),
          _buildSharePage(),
        ],
      ),
    );
  }
}

// ─── QR Scanner page ──────────────────────────────────────

class _QrScannerPage extends StatefulWidget {
  final void Function(ContactPayload) onDetected;
  const _QrScannerPage({required this.onDetected});

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> {
  late final MobileScannerController _ctrl;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = MobileScannerController();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    setState(() => _processing = true);
    _ctrl.stop();

    final payload = DeepLinkService.parseQr(raw);
    if (payload == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid QR — not a Sealed contact link')),
      );
      setState(() => _processing = false);
      _ctrl.start();
      return;
    }
    widget.onDetected(payload);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: Stack(
        children: [
          MobileScanner(controller: _ctrl, onDetect: _onDetect),
          Center(
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                border: Border.all(
                  color: theme.colorScheme.primary,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          if (_processing)
            Container(
              color: Colors.black45,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Key preview widget ──────────────────────────────────

class _KeyPreview extends StatelessWidget {
  final String label;
  final String value;

  const _KeyPreview({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline)),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
      ],
    );
  }
}