import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../data/models.dart';
import '../data/notes_repository.dart';
import '../fake_server.dart';
import '../sync/sync_engine.dart';

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController({required this.repository, required this.engine});

  final NotesRepository repository;
  final SyncEngine engine;

  List<Note> notes = const [];
  DateTime? lastSyncedAt;
  bool syncing = false;

  StreamSubscription<void>? _changes;
  Timer? _reloadTimer;
  Timer? _syncTimer;

  FaultConfig get faults => engine.faults;
  String? get lastSyncError => engine.lastError;

  Future<void> start() async {
    await engine.start();
    await _reload();
    _changes = repository.store.changes.listen((_) => _scheduleReload());
    WidgetsBinding.instance.addObserver(this);
    unawaited(engine.sync(retryNetworkFailures: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(engine.sync(retryNetworkFailures: true));
    }
  }

  Future<void> refresh() => engine.sync(retryNetworkFailures: true);

  Future<Note?> note(String id) => repository.note(id);

  Future<List<Attachment>> attachments(String noteId) =>
      repository.attachments(noteId);

  Future<bool> hasPendingDelete(String noteId) async {
    final entries = await repository.queue();
    return entries.any((e) =>
        e.noteId == noteId &&
        e.op == Op.delete &&
        e.status != OutboxStatus.done);
  }

  Future<String> createNote(String title, String body) async {
    final id = await repository.createNote(title: title, body: body);
    _syncSoon();
    return id;
  }

  Future<void> saveNote(String id, String title, String body) async {
    await repository.updateNote(id, title: title, body: body);
    _syncSoon();
  }

  Future<void> deleteNote(String id) async {
    await repository.deleteNote(id);
    _syncSoon();
  }

  Future<void> addAttachment(String noteId, File file, String fileName) async {
    await repository.addAttachment(noteId, file, fileName: fileName);
    _syncSoon();
  }

  Future<File?> attachmentFile(String attachmentId) =>
      engine.ensureAttachmentFile(attachmentId);

  Future<void> keepMine(String noteId) async {
    await repository.keepMine(noteId);
    _syncSoon();
  }

  Future<void> keepTheirs(String noteId) async {
    await repository.keepTheirs(noteId);
    _syncSoon();
  }

  Future<List<OutboxEntry>> queue() => repository.queue();

  Future<void> retryFailed() async {
    await repository.retryFailed();
    _syncSoon();
  }

  Future<void> clearDone() => repository.clearDone();

  void setOffline(bool value) {
    faults.offline = value;
    notifyListeners();
    if (!value) unawaited(refresh());
  }

  void setRandomFailures(bool value) {
    faults.failureRate = value ? 0.3 : 0;
    notifyListeners();
  }

  void setLatency(bool value) {
    faults.latency = value ? const Duration(seconds: 2) : Duration.zero;
    notifyListeners();
  }

  void setLoseResponse(bool value) {
    faults.loseResponseAfterCommit = value;
    notifyListeners();
  }

  bool otherDeviceEdit(String noteId, Map<String, Object?> changes) =>
      engine.simulateOtherDeviceEdit(noteId, changes);

  Future<void> wipeLocalData() async {
    await engine.wipeLocalData();
    await _reload();
    unawaited(refresh());
  }

  void _syncSoon() {
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(engine.sync());
    });
  }

  void _scheduleReload() {
    _reloadTimer ??= Timer(const Duration(milliseconds: 50), () {
      _reloadTimer = null;
      unawaited(_reload());
    });
  }

  Future<void> _reload() async {
    notes = await repository.notes();
    lastSyncedAt = await repository.lastSyncedAt();
    syncing = engine.isRunning;
    notifyListeners();
  }

  @override
  void dispose() {
    _changes?.cancel();
    _reloadTimer?.cancel();
    _syncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    engine.dispose();
    super.dispose();
  }
}
