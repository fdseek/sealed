class UserModel {
  final int id;
  final String privateKey;       // empty string when loaded from DB (in keychain)
  final String publicKey;
  final String signingPrivateKey; // empty string when loaded from DB (in keychain)
  final String signingPublicKey;
  final int createdAt;

  UserModel({
    this.id = 1,
    required this.privateKey,
    required this.publicKey,
    required this.signingPrivateKey,
    required this.signingPublicKey,
    required this.createdAt,
  });

  /// Used after keygen to return full model with private keys populated
  /// without persisting them to SQLite.
  UserModel copyWithPrivateKeys({
    required String privateKey,
    required String signingPrivateKey,
  }) => UserModel(
        id: id,
        privateKey: privateKey,
        publicKey: publicKey,
        signingPrivateKey: signingPrivateKey,
        signingPublicKey: signingPublicKey,
        createdAt: createdAt,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'private_key': '',          // never write private key to SQLite
        'public_key': publicKey,
        'signing_private_key': '',  // never write private key to SQLite
        'signing_public_key': signingPublicKey,
        'created_at': createdAt,
      };

  factory UserModel.fromMap(Map<String, dynamic> map) => UserModel(
        id: map['id'] as int,
        privateKey: '',             // loaded separately from keychain
        publicKey: map['public_key'] as String,
        signingPrivateKey: '',      // loaded separately from keychain
        signingPublicKey: map['signing_public_key'] as String,
        createdAt: map['created_at'] as int,
      );
}