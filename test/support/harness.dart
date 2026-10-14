import 'dart:io';
import 'dart:math';

import 'package:offline_notes/data/local_store.dart';
import 'package:offline_notes/data/models.dart';
import 'package:offline_notes/data/notes_repository.dart';
import 'package:offline_notes/fake_server.dart';
import 'package:offline_notes/sync/backoff.dart';
import 'package:offline_notes/sync/sync_engine.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestClock {
  DateTime now = DateTime(2026, 1, 1, 9);

  DateTime call() => now;

  void advance(Duration duration) => now = now.add(duration);
}

class Harness {
  Harness._(this.dir, this.clock);

  final Directory dir;
  final TestClock clock;
  late FakeServer server;
  late LocalStore store;
  late NotesRepository repo;
  late SyncEngine engine;

  static Future<Harness> create() async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('offline_notes_test');
    final harness = Harness._(dir, TestClock());
    await harness._boot();
    return harness;
  }

  Future<void> _boot() async {
    server = FakeServer.open(Directory(p.join(dir.path, 'server')));
    store = await LocalStore.open(
      dbFactory: databaseFactoryFfi,
      dbPath: p.join(dir.path, 'notes.db'),
      filesDir: Directory(p.join(dir.path, 'files')),
      clock: clock.call,
    );
    repo = NotesRepository(store);
    engine = SyncEngine(
      store: store,
      server: server,
      backoff: Backoff(random: Random(7)),
      autoRetry: false,
      pageSize: 2,
    );
    await engine.start();
  }

  Future<void> restart() async {
    engine.dispose();
    await store.close();
    await _boot();
  }

  Future<void> dispose() async {
    engine.dispose();
    await store.close();
    await dir.delete(recursive: true);
  }

  Future<void> later() async {
    clock.advance(const Duration(minutes: 2));
    await engine.sync();
  }

  Future<String> syncedNote(String title, String body) async {
    final id = await repo.createNote(title: title, body: body);
    await engine.sync();
    return id;
  }

  Future<List<OutboxEntry>> openEntries() async {
    final all = await repo.queue();
    return all.where((e) => e.status != OutboxStatus.done).toList();
  }

  Future<File> tempFile(String name, List<int> bytes) async {
    final file = File(p.join(dir.path, 'picked', name));
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes);
  }
}
