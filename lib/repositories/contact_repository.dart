import '../db/database_helper.dart';
import '../models/contact_model.dart';

class ContactRepository {
  final _db = DatabaseHelper.instance;

  Future<List<ContactModel>> getAll() async {
    final db = await _db.database;
    final rows = await db.query('contacts', orderBy: 'created_at DESC');
    return rows.map(ContactModel.fromMap).toList();
  }

  /// [publicKey] = X25519 encryption pubkey
  /// [signingPublicKey] = Ed25519 signing pubkey
  Future<ContactModel> insert(
      String name, String publicKey, String signingPublicKey) async {
    final db = await _db.database;
    final contact = ContactModel(
      name: name,
      publicKey: publicKey,
      signingPublicKey: signingPublicKey,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final id = await db.insert('contacts', contact.toMap());
    return ContactModel(
      id: id,
      name: name,
      publicKey: publicKey,
      signingPublicKey: signingPublicKey,
      createdAt: contact.createdAt,
    );
  }

  Future<void> delete(int id) async {
    final db = await _db.database;
    await db.delete('contacts', where: 'id = ?', whereArgs: [id]);
  }
}