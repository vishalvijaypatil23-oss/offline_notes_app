// fake_server.dart: provided backend. Do not change its behaviour.
// Treat it as a remote server: call it only from your sync layer.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class NetworkError implements Exception {
  NetworkError(this.reason);
  final String reason;
  @override
  String toString() => 'NetworkError($reason)';
}

/// The row changed on the server since the version you sent.
class Conflict implements Exception {
  Conflict(this.serverRow);
  final Map<String, Object?> serverRow; // current server state
}

class AlreadyExists implements Exception {}

class NotFound implements Exception {}

class ConstraintViolation implements Exception {
  ConstraintViolation(this.message);
  final String message;
  @override
  String toString() => 'ConstraintViolation($message)';
}

class FaultConfig {
  bool offline = false;
  double failureRate = 0; // 0.3 = 30% of calls fail before reaching the server
  Duration latency = Duration.zero;
  bool loseResponseAfterCommit = false; // server applies the call, client gets NetworkError
}

class FakeServer {
  FakeServer._(this._dir);

  /// Opens (or creates) server state under [dir].
  static FakeServer open(Directory dir) => FakeServer._(dir).._load();

  final Directory _dir;
  final faults = FaultConfig();
  final _rng = Random();
  int _seq = 0;
  final Map<String, Map<String, Map<String, Object?>>> _tables = {
    'notes': {},
    'attachments': {},
  };
  final Map<String, ({String path, int total, BytesBuilder data})> _uploads = {};
  static const _serverOwned = {'id', 'version', 'updated_at', 'server_seq'};

  // ---- Rows. Tables: 'notes' {id, title, body, deleted}
  //      and 'attachments' {id, note_id, file_name, mime_type, size_bytes, storage_path, deleted}

  /// Creates a row. [row] must carry a client-generated 'id'.
  Future<Map<String, Object?>> insert(String table, Map<String, Object?> row) =>
      _call(() {
        final rows = _table(table);
        final id = row['id'];
        if (id is! String) throw ArgumentError('id is required');
        if (rows.containsKey(id)) throw AlreadyExists();
        _checkParent(table, row);
        final stored = <String, Object?>{...row}
          ..removeWhere((k, _) => _serverOwned.contains(k))
          ..['id'] = id
          ..putIfAbsent('deleted', () => false)
          ..['version'] = 1;
        _stamp(stored);
        rows[id] = stored;
        return {...stored};
      });

  /// Applies [changes] only if the server row is still at [expectedVersion];
  /// otherwise throws [Conflict]. Delete = update with {'deleted': true}.
  Future<Map<String, Object?>> update(String table, String id,
          int expectedVersion, Map<String, Object?> changes) =>
      _call(() => _apply(table, id, changes, expectedVersion));

  /// Rows changed after [cursor] (exclusive), oldest first.
  Future<List<Map<String, Object?>>> changesSince(String table, int cursor,
          {int limit = 200}) =>
      _call(() {
        final rows = _table(table)
            .values
            .where((r) => (r['server_seq'] as int) > cursor)
            .toList()
          ..sort((a, b) =>
              (a['server_seq'] as int).compareTo(b['server_seq'] as int));
        return rows.take(limit).map((r) => {...r}).toList();
      });

  Future<Map<String, Object?>?> get(String table, String id) => _call(() {
        final r = _table(table)[id];
        return r == null ? null : {...r};
      });

  // ---- Files

  /// Stores a whole file. The same path again overwrites, so retries are safe.
  Future<void> uploadFile(String path, Uint8List bytes) =>
      _call(() => _file(path).writeAsBytesSync(bytes));

  Future<Uint8List> downloadFile(String path) => _call(() {
        final f = _file(path);
        if (!f.existsSync()) throw NotFound();
        return f.readAsBytesSync();
      });

  // Resumable upload (stretch). Chunks must arrive in order. Sessions live in
  // memory, so they expire when the app restarts (like a server-side timeout).
  Future<String> startUpload(String path, int totalBytes) => _call(() {
        final id = '${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 30)}';
        _uploads[id] = (path: path, total: totalBytes, data: BytesBuilder());
        return id;
      });

  /// Bytes received so far: resume from this offset.
  Future<int> uploadOffset(String uploadId) =>
      _call(() => _session(uploadId).data.length);

  /// Returns the new offset. The file appears once the last byte arrives.
  Future<int> uploadChunk(String uploadId, int offset, Uint8List chunk) =>
      _call(() {
        final s = _session(uploadId);
        if (offset != s.data.length) {
          throw ConstraintViolation('expected offset ${s.data.length}');
        }
        if (offset + chunk.length > s.total) {
          throw ConstraintViolation('chunk runs past totalBytes');
        }
        s.data.add(chunk);
        if (s.data.length == s.total) {
          _file(s.path).writeAsBytesSync(s.data.takeBytes());
          _uploads.remove(uploadId);
        }
        return offset + chunk.length;
      });

  // ---- Debug: play "the other device". No faults applied.

  Map<String, Object?> simulateOtherDeviceEdit(
      String table, String id, Map<String, Object?> changes) {
    final row = _apply(table, id, changes, null);
    _save();
    return row;
  }

  // ---- Internals

  Future<T> _call<T>(T Function() op) async {
    if (faults.latency > Duration.zero) {
      await Future<void>.delayed(faults.latency);
    }
    if (faults.offline) throw NetworkError('offline');
    if (_rng.nextDouble() < faults.failureRate) {
      throw NetworkError('random failure');
    }
    final result = op();
    _save();
    if (faults.loseResponseAfterCommit) {
      throw NetworkError('response lost after commit');
    }
    return result;
  }

  Map<String, Object?> _apply(String table, String id,
      Map<String, Object?> changes, int? expectedVersion) {
    final row = _table(table)[id];
    if (row == null) throw NotFound();
    if (expectedVersion != null && row['version'] != expectedVersion) {
      throw Conflict({...row});
    }
    final clean = <String, Object?>{...changes}
      ..removeWhere((k, _) => _serverOwned.contains(k));
    _checkParent(table, {...row, ...clean});
    row
      ..addAll(clean)
      ..['version'] = (row['version'] as int) + 1;
    _stamp(row);
    return {...row};
  }

  Map<String, Map<String, Object?>> _table(String name) =>
      _tables[name] ?? (throw ArgumentError('unknown table $name'));

  void _checkParent(String table, Map<String, Object?> row) {
    if (table == 'attachments' &&
        !_tables['notes']!.containsKey(row['note_id'])) {
      throw ConstraintViolation('note ${row['note_id']} is not on the server');
    }
  }

  void _stamp(Map<String, Object?> row) {
    row['updated_at'] = DateTime.now().toUtc().toIso8601String();
    row['server_seq'] = ++_seq;
  }

  ({String path, int total, BytesBuilder data}) _session(String id) =>
      _uploads[id] ?? (throw NotFound());

  File _file(String path) {
    final dir = Directory('${_dir.path}/files')..createSync(recursive: true);
    return File('${dir.path}/${Uri.encodeComponent(path)}');
  }

  File get _stateFile => File('${_dir.path}/server.json');

  void _load() {
    if (!_stateFile.existsSync()) return;
    final json = jsonDecode(_stateFile.readAsStringSync()) as Map<String, dynamic>;
    _seq = json['seq'] as int;
    for (final t in _tables.keys.toList()) {
      final rows = (json[t] as Map<String, dynamic>?) ?? {};
      _tables[t] = {
        for (final e in rows.entries)
          e.key: Map<String, Object?>.from(e.value as Map),
      };
    }
  }

  void _save() {
    _dir.createSync(recursive: true);
    _stateFile.writeAsStringSync(jsonEncode({'seq': _seq, ..._tables}));
  }
}
