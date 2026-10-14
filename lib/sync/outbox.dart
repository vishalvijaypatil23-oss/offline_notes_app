import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../data/models.dart';

class Outbox {
  Outbox(this._now);

  final int Function() _now;

  static const maxAttempts = 5;

  static String noteChain(String noteId) => 'note:$noteId';
  static String attachmentChain(String attachmentId) => 'att:$attachmentId';

  Future<int> add(
    DatabaseExecutor tx, {
    required String entityType,
    required String entityId,
    required String noteId,
    required String op,
    required Map<String, Object?> payload,
  }) {
    final isNote = entityType == EntityType.note;
    final now = _now();
    return tx.insert('outbox', {
      'entity_type': entityType,
      'entity_id': entityId,
      'note_id': noteId,
      'chain': isNote ? noteChain(entityId) : attachmentChain(entityId),
      'lane': isNote ? Lane.text : Lane.file,
      'op': op,
      'payload': jsonEncode(payload),
      'status': OutboxStatus.queued.value,
      'attempts': 0,
      'next_attempt_at': now,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<List<OutboxEntry>> openInChain(DatabaseExecutor tx, String chain) async {
    final rows = await tx.query('outbox',
        where: 'chain = ? AND status != ?',
        whereArgs: [chain, OutboxStatus.done.value],
        orderBy: 'id');
    return rows.map(OutboxEntry.fromRow).toList();
  }

  Future<bool> hasOpenForNote(DatabaseExecutor tx, String noteId) async {
    final rows = await tx.query('outbox',
        columns: ['id'],
        where: 'note_id = ? AND status != ?',
        whereArgs: [noteId, OutboxStatus.done.value],
        limit: 1);
    return rows.isNotEmpty;
  }

  Future<Set<String>> pendingNoteKeys(DatabaseExecutor tx, String noteId) async {
    final keys = <String>{};
    for (final entry in await openInChain(tx, noteChain(noteId))) {
      if (entry.op == Op.delete) return {'title', 'body', 'deleted'};
      keys.addAll(entry.payload.keys);
    }
    return keys;
  }

  Future<void> noteEdited(
      DatabaseExecutor tx, String noteId, Map<String, Object?> changes) async {
    final open = await openInChain(tx, noteChain(noteId));
    final last = open.isEmpty ? null : open.last;
    if (last != null && last.canAbsorbEdits) {
      await _update(tx, last.id, {
        'payload': jsonEncode({...last.payload, ...changes}),
      });
      return;
    }
    await add(tx,
        entityType: EntityType.note,
        entityId: noteId,
        noteId: noteId,
        op: Op.update,
        payload: changes);
  }

  Future<bool> noteDeleted(DatabaseExecutor tx, String noteId) async {
    final open = await openInChain(tx, noteChain(noteId));
    if (open.isNotEmpty && open.first.op == Op.create && open.first.neverSent) {
      await tx.delete('outbox',
          where: 'note_id = ? AND status != ?',
          whereArgs: [noteId, OutboxStatus.done.value]);
      return true;
    }
    for (final entry in open) {
      if (entry.op == Op.update && entry.status == OutboxStatus.queued) {
        await tx.delete('outbox', where: 'id = ?', whereArgs: [entry.id]);
      }
    }
    await add(tx,
        entityType: EntityType.note,
        entityId: noteId,
        noteId: noteId,
        op: Op.delete,
        payload: {'deleted': true});
    return false;
  }

  Future<OutboxEntry?> nextReady(DatabaseExecutor db, String lane) async {
    final rows = await db.rawQuery('''
SELECT o.* FROM outbox o
WHERE o.lane = ? AND o.status = 'queued' AND o.next_attempt_at <= ?
  AND NOT EXISTS (
    SELECT 1 FROM outbox p
    WHERE p.chain = o.chain AND p.id < o.id AND p.status != 'done')
  AND (o.entity_type != 'attachment' OR o.op != 'create' OR EXISTS (
    SELECT 1 FROM notes n
    WHERE n.id = o.note_id AND n.base_version IS NOT NULL))
ORDER BY o.id
LIMIT 1''', [lane, _now()]);
    return rows.isEmpty ? null : OutboxEntry.fromRow(rows.first);
  }

  Future<void> markInFlight(DatabaseExecutor tx, OutboxEntry entry,
      {int? baseVersion}) {
    return _update(tx, entry.id, {
      'status': OutboxStatus.inFlight.value,
      'base_version': baseVersion,
      'sent_log': jsonEncode([...entry.sentLog, entry.payload]),
    });
  }

  Future<void> markDone(DatabaseExecutor tx, int id) => _update(tx, id, {
        'status': OutboxStatus.done.value,
        'last_error': null,
        'error_kind': null,
      });

  Future<void> markAllDoneForNote(DatabaseExecutor tx, String noteId) =>
      tx.update(
          'outbox',
          {'status': OutboxStatus.done.value, 'updated_at': _now()},
          where: 'note_id = ? AND status != ?',
          whereArgs: [noteId, OutboxStatus.done.value]);

  Future<void> markChainDone(DatabaseExecutor tx, String chain) => tx.update(
      'outbox', {'status': OutboxStatus.done.value, 'updated_at': _now()},
      where: 'chain = ? AND status != ?',
      whereArgs: [chain, OutboxStatus.done.value]);

  Future<void> requeueNow(DatabaseExecutor tx, int id,
      {Map<String, Object?>? payload, String? op}) {
    final values = <String, Object?>{
      'status': OutboxStatus.queued.value,
      'next_attempt_at': _now(),
    };
    if (payload != null) values['payload'] = jsonEncode(payload);
    if (op != null) values['op'] = op;
    return _update(tx, id, values);
  }

  Future<void> retryLater(DatabaseExecutor tx, OutboxEntry entry,
      {required String error, required String kind, required Duration delay}) {
    final attempts = entry.attempts + 1;
    if (attempts >= maxAttempts) {
      return fail(tx, entry, error: error, kind: kind);
    }
    return _update(tx, entry.id, {
      'status': OutboxStatus.queued.value,
      'attempts': attempts,
      'next_attempt_at': _now() + delay.inMilliseconds,
      'last_error': error,
      'error_kind': kind,
    });
  }

  Future<void> fail(DatabaseExecutor tx, OutboxEntry entry,
      {required String error, required String kind}) {
    return _update(tx, entry.id, {
      'status': OutboxStatus.failed.value,
      'attempts': entry.attempts + 1,
      'last_error': error,
      'error_kind': kind,
    });
  }

  Future<int> recoverInFlight(DatabaseExecutor db) => db.update(
      'outbox',
      {'status': OutboxStatus.queued.value, 'next_attempt_at': _now()},
      where: 'status = ?',
      whereArgs: [OutboxStatus.inFlight.value]);

  Future<int> requeueNetworkFailures(DatabaseExecutor db) => db.update(
      'outbox',
      {
        'status': OutboxStatus.queued.value,
        'attempts': 0,
        'next_attempt_at': _now(),
      },
      where: 'status = ? AND error_kind = ?',
      whereArgs: [OutboxStatus.failed.value, ErrorKind.network]);

  Future<int> retryFailed(DatabaseExecutor db) => db.update(
      'outbox',
      {
        'status': OutboxStatus.queued.value,
        'attempts': 0,
        'next_attempt_at': _now(),
      },
      where: 'status = ? AND (error_kind IS NULL OR error_kind != ?)',
      whereArgs: [OutboxStatus.failed.value, ErrorKind.conflict]);

  Future<int> clearDone(DatabaseExecutor db) => db.delete('outbox',
      where: 'status = ?', whereArgs: [OutboxStatus.done.value]);

  Future<int?> nextWakeAt(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
        "SELECT MIN(next_attempt_at) AS t FROM outbox WHERE status = 'queued' AND next_attempt_at > ?",
        [_now()]);
    return rows.first['t'] as int?;
  }

  Future<List<OutboxEntry>> all(DatabaseExecutor db) async {
    final rows = await db.query('outbox', orderBy: 'id DESC');
    return rows.map(OutboxEntry.fromRow).toList();
  }

  Future<void> _update(
      DatabaseExecutor tx, int id, Map<String, Object?> values) {
    return tx.update('outbox', {...values, 'updated_at': _now()},
        where: 'id = ?', whereArgs: [id]);
  }
}
