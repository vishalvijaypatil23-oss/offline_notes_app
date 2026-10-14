import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';

import '../data/local_store.dart';
import '../data/models.dart';
import '../fake_server.dart';
import 'backoff.dart';
import 'conflict.dart';
import 'outbox.dart';
import 'records.dart';

typedef RowApplier = Future<List<String>> Function(
    DatabaseExecutor tx, Map<String, Object?> row);

class SyncEngine {
  SyncEngine({
    required this.store,
    required this.server,
    Backoff? backoff,
    this.autoRetry = true,
    this.pageSize = 200,
  })  : backoff = backoff ?? Backoff(),
        outbox = Outbox(() => store.nowMs) {
    records = Records(outbox, () => store.nowMs);
  }

  final LocalStore store;
  final FakeServer server;
  final Backoff backoff;
  final Outbox outbox;
  late final Records records;
  final bool autoRetry;
  final int pageSize;

  Future<void>? _running;
  bool _rerun = false;
  bool _requeueNetworkFailures = false;
  int _pullFailures = 0;
  Timer? _timer;
  bool _disposed = false;
  String? lastError;

  bool get isRunning => _running != null;

  FaultConfig get faults => server.faults;

  Future<void> start() async {
    await store.db.transaction((tx) async {
      await outbox.recoverInFlight(tx);
      await _refreshOpenNotes(tx);
    });
    store.notify();
  }

  Future<void> sync({bool retryNetworkFailures = false}) {
    if (retryNetworkFailures) _requeueNetworkFailures = true;
    final current = _running;
    if (current != null) {
      _rerun = true;
      return current;
    }
    final finished = Completer<void>();
    _running = finished.future;
    _timer?.cancel();
    () async {
      try {
        do {
          _rerun = false;
          await _runOnce();
        } while (_rerun && !_disposed);
      } catch (e) {
        lastError = '$e';
      } finally {
        _running = null;
        finished.complete();
        store.notify();
        await _scheduleNext();
      }
    }();
    return finished.future;
  }

  Future<void> whenIdle() => _running ?? Future.value();

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }

  Future<void> _runOnce() async {
    if (_requeueNetworkFailures) {
      _requeueNetworkFailures = false;
      await store.db.transaction((tx) async {
        await outbox.requeueNetworkFailures(tx);
        await _refreshOpenNotes(tx);
      });
    }
    while (!_disposed) {
      final processed = await Future.wait([_drain(Lane.text), _drain(Lane.file)]);
      if (processed.every((count) => count == 0)) break;
    }
    try {
      await pull();
      _pullFailures = 0;
      lastError = null;
      await store.writeMeta(store.db, 'last_synced_at', '${store.nowMs}');
    } on NetworkError catch (e) {
      _pullFailures++;
      lastError = e.reason;
    }
  }

  Future<void> _scheduleNext() async {
    _timer?.cancel();
    if (!autoRetry || _disposed) return;
    try {
      Duration? wait;
      if (_pullFailures > 0) wait = backoff.delayFor(_pullFailures);
      final wakeAt = await outbox.nextWakeAt(store.db);
      if (wakeAt != null) {
        final untilEntry = Duration(milliseconds: wakeAt - store.nowMs);
        if (wait == null || untilEntry < wait) wait = untilEntry;
      }
      if (wait == null || _disposed) return;
      _timer = Timer(wait, () => sync());
    } catch (e) {
      lastError = '$e';
    }
  }

  Future<int> _drain(String lane) async {
    var processed = 0;
    while (!_disposed) {
      final entry = await outbox.nextReady(store.db, lane);
      if (entry == null) break;
      await _process(entry);
      processed++;
      store.notify();
    }
    return processed;
  }

  Future<void> _process(OutboxEntry entry) async {
    try {
      await outbox.markInFlight(store.db, entry,
          baseVersion: await _baseVersionOf(entry));
      store.notify();
      if (entry.entityType == EntityType.note) {
        switch (entry.op) {
          case Op.create:
            await _pushNoteCreate(entry);
          case Op.update:
            await _pushNoteUpdate(entry);
          case Op.delete:
            await _pushNoteDelete(entry);
          default:
            throw StateError('unknown note op ${entry.op}');
        }
      } else {
        switch (entry.op) {
          case Op.create:
            await _pushAttachmentCreate(entry);
          case Op.upload:
            await _uploadFile(entry);
          case Op.setPath:
            await _pushStoragePath(entry);
          default:
            throw StateError('unknown attachment op ${entry.op}');
        }
      }
    } on NetworkError catch (e) {
      await _retry(entry, e.reason, ErrorKind.network);
    } on ConstraintViolation catch (e) {
      await _retry(entry, e.message, ErrorKind.server);
    } on NotFound {
      await _fail(entry, 'not found on server', ErrorKind.server);
    } on FileSystemException catch (e) {
      await _fail(entry, e.message, ErrorKind.local);
    } catch (e) {
      await _fail(entry, '$e', ErrorKind.local);
    }
  }

  Future<int?> _baseVersionOf(OutboxEntry entry) async {
    if (entry.entityType == EntityType.note) {
      return (await records.note(store.db, entry.entityId))?.baseVersion;
    }
    return (await records.attachment(store.db, entry.entityId))?.baseVersion;
  }

  Future<void> _retry(OutboxEntry entry, String error, String kind) {
    return store.db.transaction((tx) async {
      await outbox.retryLater(tx, entry,
          error: error,
          kind: kind,
          delay: backoff.delayFor(entry.attempts + 1));
      await records.refreshStatus(tx, entry.noteId);
    });
  }

  Future<void> _fail(OutboxEntry entry, String error, String kind) {
    return store.db.transaction((tx) async {
      await outbox.fail(tx, entry, error: error, kind: kind);
      await records.refreshStatus(tx, entry.noteId);
    });
  }

  Future<void> _done(OutboxEntry entry) {
    return store.db.transaction((tx) async {
      await outbox.markDone(tx, entry.id);
      await records.refreshStatus(tx, entry.noteId);
    });
  }

  Future<void> _pushNoteCreate(OutboxEntry entry) async {
    Map<String, Object?> row;
    try {
      row = await server.insert('notes', {'id': entry.entityId, ...entry.payload});
    } on AlreadyExists {
      row = await server.get('notes', entry.entityId) ?? (throw NotFound());
    }
    final leftover = <String, Object?>{
      for (final e in entry.payload.entries)
        if (row[e.key] != e.value) e.key: e.value,
    };
    await store.db.transaction((tx) async {
      if (leftover.isEmpty) {
        await outbox.markDone(tx, entry.id);
      } else if (row['version'] == 1) {
        await outbox.requeueNow(tx, entry.id, op: Op.update, payload: leftover);
      } else {
        await records.setConflict(tx, entry.entityId, row);
        await outbox.fail(tx, entry,
            error: 'conflict: changed on another device',
            kind: ErrorKind.conflict);
      }
      await records.adoptServerNote(tx, entry.entityId, row);
      await records.refreshStatus(tx, entry.noteId);
    });
  }

  Future<void> _pushNoteUpdate(OutboxEntry entry) async {
    final note = await records.note(store.db, entry.entityId);
    if (note == null) return _done(entry);
    final baseVersion = note.baseVersion;
    if (baseVersion == null) {
      return _fail(entry, 'note is not on the server', ErrorKind.local);
    }
    try {
      final row =
          await server.update('notes', note.id, baseVersion, entry.payload);
      await store.db.transaction((tx) async {
        await outbox.markDone(tx, entry.id);
        await records.adoptServerNote(tx, note.id, row);
        await records.refreshStatus(tx, note.id);
      });
    } on Conflict catch (c) {
      await _onUpdateConflict(entry, note, c.serverRow);
    }
  }

  Future<void> _onUpdateConflict(
      OutboxEntry entry, Note note, Map<String, Object?> serverRow) {
    final merge = mergeUpdate(
      base: note.base,
      server: serverRow,
      mine: entry.payload,
      sent: [...entry.sentLog, entry.payload],
    );
    return store.db.transaction((tx) async {
      switch (merge.outcome) {
        case MergeOutcome.alreadyApplied:
          await outbox.markDone(tx, entry.id);
          await records.adoptServerNote(tx, note.id, serverRow);
        case MergeOutcome.retry:
          await outbox.requeueNow(tx, entry.id, payload: merge.toSend);
          await records.adoptServerNote(tx, note.id, serverRow);
        case MergeOutcome.conflict:
          await records.setConflict(tx, note.id, serverRow);
          await outbox.fail(tx, entry,
              error: 'conflict: changed on another device',
              kind: ErrorKind.conflict);
      }
      await records.refreshStatus(tx, note.id);
    });
  }

  Future<void> _pushNoteDelete(OutboxEntry entry) async {
    final note = await records.note(store.db, entry.entityId);
    if (note == null) return _done(entry);
    final baseVersion = note.baseVersion;
    if (baseVersion == null) {
      return _fail(entry, 'note is not on the server', ErrorKind.local);
    }
    final orphanFiles = <String>[];
    try {
      await server.update('notes', note.id, baseVersion, {'deleted': true});
      await store.db.transaction((tx) async {
        orphanFiles.addAll(await records.purgeNote(tx, note.id));
      });
    } on Conflict catch (c) {
      final serverRow = c.serverRow;
      final outcome =
          mergeDelete(base: note.base, server: serverRow, local: note.fields);
      await store.db.transaction((tx) async {
        switch (outcome) {
          case MergeOutcome.alreadyApplied:
            orphanFiles.addAll(await records.purgeNote(tx, note.id));
            return;
          case MergeOutcome.retry:
            await records.adoptServerNote(tx, note.id, serverRow);
            await outbox.requeueNow(tx, entry.id);
          case MergeOutcome.conflict:
            await records.setConflict(tx, note.id, serverRow);
            await outbox.fail(tx, entry,
                error: 'conflict: edited on another device',
                kind: ErrorKind.conflict);
        }
        await records.refreshStatus(tx, note.id);
      });
    }
    await store.deleteFiles(orphanFiles);
  }

  Future<void> _pushAttachmentCreate(OutboxEntry entry) async {
    Map<String, Object?> row;
    try {
      row = await server
          .insert('attachments', {'id': entry.entityId, ...entry.payload});
    } on AlreadyExists {
      row = await server.get('attachments', entry.entityId) ??
          (throw NotFound());
    }
    await store.db.transaction((tx) async {
      await tx.update('attachments', {'base_version': row['version']},
          where: 'id = ?', whereArgs: [entry.entityId]);
      await outbox.markDone(tx, entry.id);
      await records.refreshStatus(tx, entry.noteId);
    });
  }

  Future<void> _uploadFile(OutboxEntry entry) async {
    final attachment = await records.attachment(store.db, entry.entityId);
    final localPath = attachment?.localPath;
    if (localPath == null) {
      return _fail(entry, 'local file missing', ErrorKind.local);
    }
    final file = store.fileFor(localPath);
    if (!await file.exists()) {
      return _fail(entry, 'local file missing', ErrorKind.local);
    }
    final bytes = await file.readAsBytes();
    await server.uploadFile(entry.payload['path']! as String, bytes);
    await _done(entry);
  }

  Future<void> _pushStoragePath(OutboxEntry entry) async {
    final attachment = await records.attachment(store.db, entry.entityId);
    if (attachment == null) return _done(entry);
    final baseVersion = attachment.baseVersion;
    if (baseVersion == null) {
      return _fail(entry, 'attachment row is not on the server', ErrorKind.local);
    }
    final path = entry.payload['path']! as String;
    Map<String, Object?> row;
    try {
      row = await server
          .update('attachments', attachment.id, baseVersion, {'storage_path': path});
    } on Conflict catch (c) {
      if (c.serverRow['storage_path'] != path) {
        await store.db.transaction((tx) async {
          await tx.update(
              'attachments', {'base_version': c.serverRow['version']},
              where: 'id = ?', whereArgs: [attachment.id]);
          await outbox.requeueNow(tx, entry.id);
        });
        return;
      }
      row = c.serverRow;
    }
    await store.db.transaction((tx) async {
      await tx.update(
          'attachments', {'storage_path': path, 'base_version': row['version']},
          where: 'id = ?', whereArgs: [attachment.id]);
      await outbox.markDone(tx, entry.id);
      await records.refreshStatus(tx, entry.noteId);
    });
  }

  Future<void> pull() async {
    await _pullTable('notes', _applyNoteRow);
    await _pullTable('attachments', _applyAttachmentRow);
  }

  Future<void> _pullTable(String table, RowApplier apply) async {
    var cursor = int.parse(await store.readMeta('cursor:$table') ?? '0');
    while (true) {
      final page = await server.changesSince(table, cursor, limit: pageSize);
      if (page.isEmpty) return;
      final pageEnd = page.last['server_seq']! as int;
      final orphanFiles = <String>[];
      await store.db.transaction((tx) async {
        for (final row in page) {
          orphanFiles.addAll(await apply(tx, row));
        }
        await store.writeMeta(tx, 'cursor:$table', '$pageEnd');
      });
      cursor = pageEnd;
      await store.deleteFiles(orphanFiles);
      store.notify();
      if (page.length < pageSize) return;
    }
  }

  Future<List<String>> _applyNoteRow(
      DatabaseExecutor tx, Map<String, Object?> row) async {
    final id = row['id']! as String;
    final version = row['version']! as int;
    final deleted = row['deleted'] == true;
    final local = await records.note(tx, id);
    if (local == null) {
      if (!deleted) await records.insertServerNote(tx, row);
      return const [];
    }
    final noteChain = await outbox.openInChain(tx, Outbox.noteChain(id));
    if (noteChain.isNotEmpty) return const [];
    if ((local.baseVersion ?? 0) >= version) return const [];
    if (deleted) {
      if (await outbox.hasOpenForNote(tx, id)) {
        await records.setConflict(tx, id, row);
        await records.refreshStatus(tx, id);
        return const [];
      }
      return records.purgeNote(tx, id);
    }
    await records.adoptServerNote(tx, id, row);
    await records.refreshStatus(tx, id);
    return const [];
  }

  Future<List<String>> _applyAttachmentRow(
      DatabaseExecutor tx, Map<String, Object?> row) async {
    final id = row['id']! as String;
    final chain = await outbox.openInChain(tx, Outbox.attachmentChain(id));
    if (chain.isNotEmpty) return const [];
    final local = await records.attachment(tx, id);
    if (row['deleted'] == true) {
      if (local == null) return const [];
      await tx.delete('attachments', where: 'id = ?', whereArgs: [id]);
      final localPath = local.localPath;
      return [if (localPath != null) localPath];
    }
    final noteId = row['note_id']! as String;
    if (await records.note(tx, noteId) == null) return const [];
    final values = <String, Object?>{
      'note_id': noteId,
      'file_name': row['file_name'] ?? 'file',
      'mime_type': row['mime_type'] ?? 'application/octet-stream',
      'size_bytes': row['size_bytes'] ?? 0,
      'storage_path': row['storage_path'],
      'base_version': row['version'],
      'sync_status': SyncStatus.synced.name,
    };
    if (local == null) {
      await tx.insert('attachments',
          {...values, 'id': id, 'created_at': store.nowMs});
    } else {
      await tx.update('attachments', values,
          where: 'id = ?', whereArgs: [id]);
    }
    return const [];
  }

  Future<File?> ensureAttachmentFile(String attachmentId) async {
    final attachment = await records.attachment(store.db, attachmentId);
    if (attachment == null) return null;
    final localPath = attachment.localPath;
    if (localPath != null) {
      final cached = store.fileFor(localPath);
      if (await cached.exists()) return cached;
    }
    final storagePath = attachment.storagePath;
    if (storagePath == null) return null;
    final bytes = await server.downloadFile(storagePath);
    final relative = p.join(attachment.id, attachment.fileName);
    final file = store.fileFor(relative);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    await store.db.update('attachments', {'local_path': relative},
        where: 'id = ?', whereArgs: [attachment.id]);
    store.notify();
    return file;
  }

  bool simulateOtherDeviceEdit(String noteId, Map<String, Object?> changes) {
    try {
      server.simulateOtherDeviceEdit('notes', noteId, changes);
      return true;
    } on NotFound {
      return false;
    }
  }

  Future<void> wipeLocalData() async {
    _timer?.cancel();
    await whenIdle();
    _pullFailures = 0;
    await store.wipe();
  }

  Future<void> _refreshOpenNotes(DatabaseExecutor tx) async {
    final rows = await tx.rawQuery(
        "SELECT DISTINCT note_id FROM outbox WHERE status != 'done'");
    for (final row in rows) {
      await records.refreshStatus(tx, row['note_id']! as String);
    }
  }
}
