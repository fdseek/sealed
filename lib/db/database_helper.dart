import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Single SQLite package for ALL platforms: sqflite_common_ffi
/// Removed sqflite native import — no more split package confusion
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._internal();
  static Database? _db;

  DatabaseHelper._internal();

  /// Call once in main() before runApp
  static void initFfi() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  /// Test-only: inject an already-open in-memory database.
  /// Call in setUp(), then clearOverride() in tearDown().
  static void overrideDatabase(Database db) => _db = db;

  /// Test-only: clear cached instance so next [database] call opens fresh DB.
  static void clearOverride() => _db = null;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dir = await getApplicationSupportDirectory();
    final path = join(dir.path, 'app.db');

    return await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE user (
        id INTEGER PRIMARY KEY,
        private_key TEXT NOT NULL,
        public_key TEXT NOT NULL,
        signing_private_key TEXT NOT NULL,
        signing_public_key TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE contacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        public_key TEXT NOT NULL,
        signing_public_key TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// Migrate v1 → v2: add signing key columns
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
          "ALTER TABLE user ADD COLUMN signing_private_key TEXT NOT NULL DEFAULT ''");
      await db.execute(
          "ALTER TABLE user ADD COLUMN signing_public_key TEXT NOT NULL DEFAULT ''");
      await db.execute(
          "ALTER TABLE contacts ADD COLUMN signing_public_key TEXT NOT NULL DEFAULT ''");

      // Force key regeneration on next app start (empty = regenerate)
      await db.delete('user');
    }
  }
}