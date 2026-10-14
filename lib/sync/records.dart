import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../data/models.dart';
import 'outbox.dart';

class Records {
  Records(this.outbox, this._now);

  final Outbox outbox;
  final int Function() _now;

  Future<Note?> note(DatabaseExecutor tx, String id) async {
    final rows = await tx.query('notes', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Note.fromRow(rows.first);
  }

  Future<Attachment?> attachment(DatabaseExecutor tx, String id) async {
    final rows =
        await tx.query('attachments', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Attachment.fromRow(rows.first);
  }

  Future<List<Attachment>> attachmentsOf(
      DatabaseExecutor tx, String noteId) async {
    final rows = await tx.query('attachments',
        where: 'note_id = ?', whereArgs: [noteId], orderBy: 'created_at');
    return rows.map(Attachment.fromRow).toList();
  }

  Future<void> refreshStatus(DatabaseExecutor tx, String noteId) async {
    final note = await this.note(tx, noteId);
    if (note == null) return;
    final open = await tx.query('outbox',
        columns: ['chain', 'status'],
        where: 'note_id = ? AND status != ?',
        whereArgs: [noteId, OutboxStatus.done.value]);

    SyncStatus statusOf(Iterable<Map<String, Object?>> rows) {
      final statuses = rows.map((r) => r['status']).toSet();
      if (statuses.contains(OutboxStatus.failed.value)) return SyncStatus.failed;
      if (statuses.isNotEmpty) return SyncStatus.pending;
      return SyncStatus.synced;
    }

    final noteStatus =
        note.conflictRow != null ? SyncStatus.conflict : statusOf(open);
    await tx.update('notes', {'sync_status': noteStatus.name},
        where: 'id = ?', whereArgs: [noteId]);

    for (final attachment in await attachmentsOf(tx, noteId)) {
      final chain = Outbox.attachmentChain(attachment.id);
      final status = statusOf(open.where((r) => r['chain'] == chain));
      await tx.update('attachments', {'sync_status': status.name},
          where: 'id = ?', whereArgs: [attachment.id]);
    }
  }

  Future<void> adoptServerNote(
      DatabaseExecutor tx, String noteId, Map<String, Object?> row) async {
    final pending = await outbox.pendingNoteKeys(tx, noteId);
    final values = <String, Object?>{
      'base_version': row['version'],
      'base_title': row['title'] ?? '',
      'base_body': row['body'] ?? '',
    };
    for (final key in ['title', 'body']) {
      if (!pending.contains(key)) values[key] = row[key] ?? '';
    }
    await tx.update('notes', values, where: 'id = ?', whereArgs: [noteId]);
  }

  Future<void> insertServerNote(
      DatabaseExecutor tx, Map<String, Object?> row) async {
    await tx.insert(
        'notes',
        {
          'id': row['id'],
          'title': row['title'] ?? '',
          'body': row['body'] ?? '',
          'deleted': 0,
          'base_version': row['version'],
          'base_title': row['title'] ?? '',
          'base_body': row['body'] ?? '',
          'sync_status': SyncStatus.synced.name,
          'updated_at': _now(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> setConflict(
      DatabaseExecutor tx, String noteId, Map<String, Object?> serverRow) {
    return tx.update(
        'notes', {'conflict_row': jsonEncode(serverRow), 'deleted': 0},
        where: 'id = ?', whereArgs: [noteId]);
  }

  Future<List<String>> purgeNote(DatabaseExecutor tx, String noteId) async {
    final files = [
      for (final a in await attachmentsOf(tx, noteId))
        if (a.localPath != null) a.localPath!,
    ];
    await outbox.markAllDoneForNote(tx, noteId);
    await tx.delete('attachments', where: 'note_id = ?', whereArgs: [noteId]);
    await tx.delete('notes', where: 'id = ?', whereArgs: [noteId]);
    return files;
  }
}
