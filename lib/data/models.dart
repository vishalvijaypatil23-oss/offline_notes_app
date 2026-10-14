import 'dart:convert';

enum SyncStatus { synced, pending, failed, conflict }

enum OutboxStatus {
  queued('queued'),
  inFlight('in_flight'),
  done('done'),
  failed('failed');

  const OutboxStatus(this.value);
  final String value;

  static OutboxStatus parse(String value) =>
      OutboxStatus.values.firstWhere((s) => s.value == value);
}

abstract final class EntityType {
  static const note = 'note';
  static const attachment = 'attachment';
}

abstract final class Op {
  static const create = 'create';
  static const update = 'update';
  static const delete = 'delete';
  static const upload = 'upload';
  static const setPath = 'set_path';
}

abstract final class Lane {
  static const text = 'text';
  static const file = 'file';
}

abstract final class ErrorKind {
  static const network = 'network';
  static const server = 'server';
  static const conflict = 'conflict';
  static const local = 'local';
}

Map<String, Object?> decodeMap(String json) =>
    (jsonDecode(json) as Map<String, dynamic>).cast<String, Object?>();

class Note {
  const Note({
    required this.id,
    required this.title,
    required this.body,
    required this.deleted,
    required this.baseVersion,
    required this.baseTitle,
    required this.baseBody,
    required this.status,
    required this.conflictRow,
    required this.updatedAt,
  });

  factory Note.fromRow(Map<String, Object?> row) => Note(
        id: row['id']! as String,
        title: row['title']! as String,
        body: row['body']! as String,
        deleted: row['deleted'] == 1,
        baseVersion: row['base_version'] as int?,
        baseTitle: row['base_title'] as String?,
        baseBody: row['base_body'] as String?,
        status: SyncStatus.values.byName(row['sync_status']! as String),
        conflictRow: row['conflict_row'] == null
            ? null
            : decodeMap(row['conflict_row']! as String),
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(row['updated_at']! as int),
      );

  final String id;
  final String title;
  final String body;
  final bool deleted;
  final int? baseVersion;
  final String? baseTitle;
  final String? baseBody;
  final SyncStatus status;
  final Map<String, Object?>? conflictRow;
  final DateTime updatedAt;

  bool get isOnServer => baseVersion != null;

  Map<String, Object?> get base => {'title': baseTitle, 'body': baseBody};

  Map<String, Object?> get fields => {'title': title, 'body': body};
}

class Attachment {
  const Attachment({
    required this.id,
    required this.noteId,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.localPath,
    required this.storagePath,
    required this.baseVersion,
    required this.status,
  });

  factory Attachment.fromRow(Map<String, Object?> row) => Attachment(
        id: row['id']! as String,
        noteId: row['note_id']! as String,
        fileName: row['file_name']! as String,
        mimeType: row['mime_type']! as String,
        sizeBytes: row['size_bytes']! as int,
        localPath: row['local_path'] as String?,
        storagePath: row['storage_path'] as String?,
        baseVersion: row['base_version'] as int?,
        status: SyncStatus.values.byName(row['sync_status']! as String),
      );

  final String id;
  final String noteId;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final String? localPath;
  final String? storagePath;
  final int? baseVersion;
  final SyncStatus status;

  bool get isImage => mimeType.startsWith('image/');
}

class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.noteId,
    required this.chain,
    required this.lane,
    required this.op,
    required this.payload,
    required this.sentLog,
    required this.baseVersion,
    required this.status,
    required this.attempts,
    required this.nextAttemptAt,
    required this.lastError,
    required this.errorKind,
    required this.createdAt,
  });

  factory OutboxEntry.fromRow(Map<String, Object?> row) => OutboxEntry(
        id: row['id']! as int,
        entityType: row['entity_type']! as String,
        entityId: row['entity_id']! as String,
        noteId: row['note_id']! as String,
        chain: row['chain']! as String,
        lane: row['lane']! as String,
        op: row['op']! as String,
        payload: decodeMap(row['payload']! as String),
        sentLog: (jsonDecode(row['sent_log']! as String) as List)
            .map((e) => (e as Map<String, dynamic>).cast<String, Object?>())
            .toList(),
        baseVersion: row['base_version'] as int?,
        status: OutboxStatus.parse(row['status']! as String),
        attempts: row['attempts']! as int,
        nextAttemptAt:
            DateTime.fromMillisecondsSinceEpoch(row['next_attempt_at']! as int),
        lastError: row['last_error'] as String?,
        errorKind: row['error_kind'] as String?,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
      );

  final int id;
  final String entityType;
  final String entityId;
  final String noteId;
  final String chain;
  final String lane;
  final String op;
  final Map<String, Object?> payload;
  final List<Map<String, Object?>> sentLog;
  final int? baseVersion;
  final OutboxStatus status;
  final int attempts;
  final DateTime nextAttemptAt;
  final String? lastError;
  final String? errorKind;
  final DateTime createdAt;

  bool get canAbsorbEdits =>
      status == OutboxStatus.queued && (op == Op.update || op == Op.create);

  bool get neverSent => status == OutboxStatus.queued && sentLog.isEmpty;
}
