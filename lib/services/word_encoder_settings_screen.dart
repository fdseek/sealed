import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:sealed_app/services/word_encoder.dart';

class WordEncoderSettingsScreen extends StatefulWidget {
  const WordEncoderSettingsScreen({super.key});

  @override
  State<WordEncoderSettingsScreen> createState() =>
      _WordEncoderSettingsScreenState();
}

class _WordEncoderSettingsScreenState extends State<WordEncoderSettingsScreen> {
  TokenMode _mode = TokenMode.persian;
  bool _loading = true;

  // preview bytes
  static final _previewBytes = () {
    final b = List<int>.generate(8, (i) => (i * 31 + 7) % 256);
    return b;
  }();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await WordEncoderService.loadMode();
    setState(() {
      _mode = m;
      _loading = false;
    });
  }

  Future<void> _setMode(TokenMode m) async {
    await WordEncoderService.saveMode(m);
    setState(() => _mode = m);
  }

  String _preview(TokenMode m) {
    try {
      return WordEncoderService.encode(Uint8List.fromList(_previewBytes), m);
    } catch (_) {
      return '—';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Word Encoding Style')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Messages are encoded as readable tokens after encryption.\n'
            'Choose the style — both sides must use the same.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 20),
          ...TokenMode.values.map((m) {
            final selected = m == _mode;
            return GestureDetector(
              onTap: () => _setMode(m),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
                    width: selected ? 2 : 1,
                  ),
                  color: selected
                      ? theme.colorScheme.primary.withValues(alpha: .06)
                      : theme.colorScheme.surface,
                ),
                child: Row(
                  children: [
                    Radio<TokenMode>(
                      value: m,
                      groupValue: _mode,
                      onChanged: (v) => _setMode(v!),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(m.label,
                              style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: selected
                                      ? FontWeight.bold
                                      : FontWeight.normal)),
                          const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              _preview(m),
                              style: theme.textTheme.bodySmall?.copyWith(
                                height: 1.6,
                                color: theme.colorScheme.onSurface,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiaryContainer.withValues(alpha: .4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: theme.colorScheme.tertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Both sender and receiver must use the same style to decode messages.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.tertiary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
