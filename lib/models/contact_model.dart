class ContactModel {
  final int? id;
  final String name;
  final String publicKey;

  /// Ed25519 signing public key — used to verify messages from this contact
  /// Prevents MITM: receiver checks signature matches this key
  final String signingPublicKey;

  final int createdAt;

  ContactModel({
    this.id,
    required this.name,
    required this.publicKey,
    required this.signingPublicKey,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'public_key': publicKey,
        'signing_public_key': signingPublicKey,
        'created_at': createdAt,
      };

  factory ContactModel.fromMap(Map<String, dynamic> map) => ContactModel(
        id: map['id'] as int?,
        name: map['name'] as String,
        publicKey: map['public_key'] as String,
        signingPublicKey: map['signing_public_key'] as String,
        createdAt: map['created_at'] as int,
      );
}