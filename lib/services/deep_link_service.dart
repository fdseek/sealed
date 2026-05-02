
class DeepLinkService {
  static const _scheme = 'sealed';
  static const _host = 'add';

  // ── Build ──────────────────────────────────────────────

  /// Build a shareable link from own public keys.
  static String buildLink({
    required String name,
    required String encPublicKey,
    required String sigPublicKey,
  }) {
    final encoded = Uri(
      scheme: _scheme,
      host: _host,
      queryParameters: {
        'name': name,
        'enc': encPublicKey,
        'sig': sigPublicKey,
      },
    ).toString();
    return encoded;
  }

  /// Build https fallback link (for non-app users / plain share).
  /// Uses a universal URL that shows instructions if app not installed.
  static String buildShareableText({
    required String name,
    required String encPublicKey,
    required String sigPublicKey,
  }) {
    final link = buildLink(
      name: name,
      encPublicKey: encPublicKey,
      sigPublicKey: sigPublicKey,
    );
    return 'Add me on Sealed 🔐\n\n'
        'Open this link to add my key automatically:\n$link\n\n'
        'Or add manually:\n'
        'Encryption key: $encPublicKey\n'
        'Signing key:    $sigPublicKey';
  }

  // ── Parse ──────────────────────────────────────────────

  /// Returns [ContactPayload] if valid sealed:// link, else null.
  static ContactPayload? parse(String raw) {
    try {
      final uri = Uri.parse(raw.trim());
      if (uri.scheme != _scheme) return null;
      if (uri.host != _host) return null;

      final name = uri.queryParameters['name'] ?? '';
      final enc = uri.queryParameters['enc'] ?? '';
      final sig = uri.queryParameters['sig'] ?? '';

      if (enc.isEmpty || sig.isEmpty) return null;

      return ContactPayload(
        name: name,
        encPublicKey: enc,
        sigPublicKey: sig,
      );
    } catch (_) {
      return null;
    }
  }

  /// Try to parse from QR scan result string.
  static ContactPayload? parseQr(String qrData) => parse(qrData);
}

class ContactPayload {
  final String name;
  final String encPublicKey;
  final String sigPublicKey;

  const ContactPayload({
    required this.name,
    required this.encPublicKey,
    required this.sigPublicKey,
  });
}