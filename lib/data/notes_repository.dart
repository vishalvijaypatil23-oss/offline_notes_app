import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import '../sync/outbox.dart';
import '../sync/records.dart';
import 'local_store.dart';
import 'models.dart';

class NotesRepository {
  NotesRepository(this.store)
      : outbox = Outbox(() => store.nowMs),
        _uuid = const Uuid() {
    records = Records(outbox, () => store.nowMs);
  }

  final LocalStore store;
  final Outbox outbox;
  late final Records records;
  final Uuid _uuid;

  Database get _db => store.db;

  Future<List<Note>> notes() async {
    final rows = await _db.query('notes',
        where: 'deleted = 0', orderBy: 'updated_at DESC');
    return rows.map(Note.fromRow).toList();
  }

  Future<Note?> note(String id) => records.note(_db, id);

  Future<List<Attachment>> attachments(String noteId) =>
      records.attachmentsOf(_db, noteId);

  Future<String> createNote({String title = '', String body = ''}) async {
    late String id;
    await _db.transaction((tx) async {
      id = await _insertNote(tx, title, body);
    });
    store.notify();
    return id;
  }

  Future<void> updateNote(String id,
      {required String title, required String body}) async {
    await _db.transaction((tx) async {
      final note = await records.note(tx, id);
      if (note == null || note.deleted) return;
      final changes = <String, Object?>{};
      if (title != note.title) changes['title'] = title;
      if (body != note.body) changes['body'] = body;
      if (changes.isEmpty) return;
      await tx.update('notes', {...changes, 'updated_at': store.nowMs},
          where: 'id = ?', whereArgs: [id]);
      await outbox.noteEdited(tx, id, changes);
      await records.refreshStatus(tx, id);
    });
    store.notify();
  }

  Future<void> deleteNote(String id) async {
    final orphanFiles = <String>[];
    await _db.transaction((tx) async {
      final note = await records.note(tx, id);
      if (note == null || note.deleted) return;
      final cancelled = await outbox.noteDeleted(tx, id);
      if (cancelled) {
        orphanFiles.addAll(await records.purgeNote(tx, id));
        return;
      }
      await tx.update('notes', {'deleted': 1, 'updated_at': store.nowMs},
          where: 'id = ?', whereArgs: [id]);
      await records.refreshStatus(tx, id);
    });
    await store.deleteFiles(orphanFiles);
    store.notify();
  }

  Future<void> addAttachment(String noteId, File source,
      {String? fileName}) async {
    final id = _uuid.v4();
    final name = fileName ?? p.basename(source.path);
    final relativePath = p.join(id, name);
    final target = store.fileFor(relativePath);
    await target.parent.create(recursive: true);
    await source.copy(target.path);
    final size = await target.length();
    final mimeType = lookupMimeType(name) ?? 'application/octet-stream';
    final storagePath = '$noteId/$id';

    await _db.transaction((tx) async {
      await tx.insert('attachments', {
        'id': id,
        'note_id': noteId,
        'file_name': name,
        'mime_type': mimeType,
        'size_bytes': size,
        'local_path': relativePath,
        'sync_status': SyncStatus.pending.name,
        'created_at': store.nowMs,
      });
      Future<void> enqueue(String op, Map<String, Object?> payload) =>
          outbox.add(tx,
              entityType: EntityType.attachment,
              entityId: id,
              noteId: noteId,
              op: op,
              payload: payload);
      await enqueue(Op.create, {
        'note_id': noteId,
        'file_name': name,
        'mime_type': mimeType,
        'size_bytes': size,
      });
      await enqueue(Op.upload, {'path': storagePath});
      await enqueue(Op.setPath, {'path': storagePath});
      await records.refreshStatus(tx, noteId);
    });
    store.notify();
  }

  Future<void> keepMine(String id) async {
    await _db.transaction((tx) async {
      final note = await records.note(tx, id);
      final server = note?.conflictRow;
      if (note == null || server == null) return;
      final chain = Outbox.noteChain(id);
      final open = await outbox.openInChain(tx, chain);
      final wasDelete = open.any((e) => e.op == Op.delete);
      final serverDeleted = server['deleted'] == true;

      await outbox.markChainDone(tx, chain);
      await tx.update(
          'notes',
          {
            'base_version': server['version'],
            'base_title': server['title'] ?? '',
            'base_body': server['body'] ?? '',
            'conflict_row': null,
            'deleted': wasDelete ? 1 : 0,
            'updated_at': store.nowMs,
          },
          where: 'id = ?',
          whereArgs: [id]);

      final Map<String, Object?> payload;
      if (wasDelete) {
        payload = {'deleted': true};
      } else if (serverDeleted) {
        payload = {...note.fields, 'deleted': false};
      } else {
        final keys = {
          for (final e in open) ...e.payload.keys,
        }..remove('deleted');
        payload = {for (final k in keys) k: note.fields[k]};
      }
      if (payload.isNotEmpty) {
        await outbox.add(tx,
            entityType: EntityType.note,
            entityId: id,
            noteId: id,
            op: wasDelete ? Op.delete : Op.update,
            payload: payload);
      }
      await records.refreshStatus(tx, id);
    });
    store.notify();
  }

  Future<void> keepTheirs(String id) async {
    final orphanFiles = <String>[];
    await _db.transaction((tx) async {
      final note = await records.note(tx, id);
      final server = note?.conflictRow;
      if (note == null || server == null) return;
      final chain = Outbox.noteChain(id);
      final open = await outbox.openInChain(tx, chain);
      final wasDelete = open.any((e) => e.op == Op.delete);
      final serverDeleted = server['deleted'] == true;
      final mineDiffers =
          note.title != server['title'] || note.body != server['body'];

      if (!wasDelete && (mineDiffers || serverDeleted)) {
        final title = note.title.isEmpty ? 'Untitled' : note.title;
        await _insertNote(tx, '$title (my copy)', note.body);
      }
      await outbox.markChainDone(tx, chain);

      if (serverDeleted) {
        orphanFiles.addAll(await records.purgeNote(tx, id));
        return;
      }
      await tx.update(
          'notes',
          {
            'title': server['title'] ?? '',
            'body': server['body'] ?? '',
            'base_version': server['version'],
            'base_title': server['title'] ?? '',
            'base_body': server['body'] ?? '',
            'conflict_row': null,
            'deleted': 0,
            'updated_at': store.nowMs,
          },
          where: 'id = ?',
          whereArgs: [id]);
      await records.refreshStatus(tx, id);
    });
    await store.deleteFiles(orphanFiles);
    store.notify();
  }

  Future<List<OutboxEntry>> queue() => outbox.all(_db);

  Future<void> retryFailed() async {
    await _db.transaction((tx) async {
      await outbox.retryFailed(tx);
      await _refreshAll(tx);
    });
    store.notify();
  }

  Future<void> retryNote(String noteId) async {
    await _db.transaction((tx) async {
      await outbox.retryFailedForNote(tx, noteId);
      await records.refreshStatus(tx, noteId);
    });
    store.notify();
  }

  Future<void> clearDone() async {
    await outbox.clearDone(_db);
    store.notify();
  }

  Future<DateTime?> lastSyncedAt() async {
    final value = await store.readMeta('last_synced_at');
    return value == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(int.parse(value));
  }

  Future<String> _insertNote(
      DatabaseExecutor tx, String title, String body) async {
    final id = _uuid.v4();
    await tx.insert('notes', {
      'id': id,
      'title': title,
      'body': body,
      'deleted': 0,
      'sync_status': SyncStatus.pending.name,
      'updated_at': store.nowMs,
    });
    await outbox.add(tx,
        entityType: EntityType.note,
        entityId: id,
        noteId: id,
        op: Op.create,
        payload: {'title': title, 'body': body});
    return id;
  }

  Future<void> _refreshAll(DatabaseExecutor tx) async {
    final rows = await tx.query('notes', columns: ['id']);
    for (final row in rows) {
      await records.refreshStatus(tx, row['id']! as String);
    }
  }
}
