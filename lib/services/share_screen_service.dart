import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/user_model.dart';
import '../services/deep_link_service.dart';

class ShareScreen extends StatefulWidget {
  final UserModel? user;

  const ShareScreen({
    super.key,
    required this.user,
  });

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  final _nameCtrl = TextEditingController(text: 'Me');

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  String _buildLink() {
    if (widget.user == null) return '';
    return DeepLinkService.buildLink(
      name: _nameCtrl.text.trim().isEmpty ? 'Me' : _nameCtrl.text.trim(),
      encPublicKey: widget.user!.publicKey,
      sigPublicKey: widget.user!.signingPublicKey,
    );
  }

  String _buildShareText() {
    if (widget.user == null) return '';
    return DeepLinkService.buildShareableText(
      name: _nameCtrl.text.trim().isEmpty ? 'Me' : _nameCtrl.text.trim(),
      encPublicKey: widget.user!.publicKey,
      sigPublicKey: widget.user!.signingPublicKey,
    );
  }

  void _copyLink() {
    final link = _buildLink();
    if (link.isEmpty) return;
    Clipboard.setData(ClipboardData(text: link));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  void _shareText() {
    Clipboard.setData(ClipboardData(text: _buildShareText()));
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Share text copied to clipboard')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.user == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Your display name',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person_outline),
              helperText: 'Shown when contact scans your QR',
            ),
            onChanged: (_) => setState(() {}),
          ),

          const SizedBox(height: 24),

          // QR card
          Stack(
            alignment: Alignment.topRight,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: QrImageView(
                  data: _buildLink(),
                  version: QrVersions.auto,
                  size: 240,
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Tooltip(
                  message: 'Copy link',
                  child: Material(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: _copyLink,
                      child: const Padding(
                        padding: EdgeInsets.all(6),
                        child: Icon(Icons.copy, color: Colors.white, size: 16),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),
          Text(
            'Tap 📋 on QR to copy link • Or use buttons below',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),

          Text('Share link', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            'Send to anyone — works without QR scanner',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 12),

          GestureDetector(
            onTap: _copyLink,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _buildLink(),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontFamily: 'monospace'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.copy, size: 16, color: theme.colorScheme.outline),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _copyLink,
                  icon: const Icon(Icons.link, size: 16),
                  label: const Text('Copy Link'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _shareText,
                  icon: const Icon(Icons.share, size: 16),
                  label: const Text('Share Text'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          ExpansionTile(
            title:
                Text('Preview share message', style: theme.textTheme.bodySmall),
            tilePadding: EdgeInsets.zero,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  _buildShareText(),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
