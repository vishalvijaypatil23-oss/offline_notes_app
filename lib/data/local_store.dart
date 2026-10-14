import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';

import '../sync/sync_log.dart';
import 'schema.dart';

class LocalStore {
  LocalStore._(this.db, this.filesDir, this.clock, this.log);

  static Future<LocalStore> open({
    required DatabaseFactory dbFactory,
    required String dbPath,
    required Directory filesDir,
    DateTime Function()? clock,
    SyncLog? log,
  }) async {
    final db = await dbFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        singleInstance: false,
        onCreate: (db, _) async {
          for (final sql in schemaStatements) {
            await db.execute(sql);
          }
        },
      ),
    );
    await filesDir.create(recursive: true);
    final syncLog = log ?? SyncLog(clock: clock);
    syncLog.add('db', 'opened $dbPath');
    syncLog.add('files', 'attachments are stored in ${filesDir.path}');
    return LocalStore._(db, filesDir, clock ?? DateTime.now, syncLog);
  }

  final Database db;
  final Directory filesDir;
  final DateTime Function() clock;
  final SyncLog log;
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  int get nowMs => clock().millisecondsSinceEpoch;

  void notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  File fileFor(String relativePath) => File(p.join(filesDir.path, relativePath));

  Future<void> deleteFiles(Iterable<String> relativePaths) async {
    for (final path in relativePaths) {
      final file = fileFor(path);
      if (await file.exists()) await file.delete();
    }
  }

  Future<String?> readMeta(String key) async {
    final rows = await db.query('sync_meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> writeMeta(DatabaseExecutor tx, String key, String value) =>
      tx.insert('sync_meta', {'key': key, 'value': value},
          conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> wipe() async {
    await db.transaction((tx) async {
      for (final table in ['notes', 'attachments', 'outbox', 'sync_meta']) {
        await tx.delete(table);
      }
    });
    if (await filesDir.exists()) await filesDir.delete(recursive: true);
    await filesDir.create(recursive: true);
    log.add('db', 'local data wiped, server folder kept');
    notify();
  }

  Future<void> close() async {
    await _changes.close();
    await db.close();
  }
}
