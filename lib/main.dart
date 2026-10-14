import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'app/app_controller.dart';
import 'data/local_store.dart';
import 'data/notes_repository.dart';
import 'fake_server.dart';
import 'sync/sync_engine.dart';
import 'sync/sync_log.dart';
import 'ui/notes_list_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final documents = await getApplicationDocumentsDirectory();

  final log = SyncLog(sink: (line) => debugPrint(line));
  final server = FakeServer.open(Directory('${support.path}/fake_server'));
  log.add('server', 'fake server folder ${support.path}/fake_server');
  final store = await LocalStore.open(
    log: log,
    dbFactory: databaseFactory,
    dbPath: p.join(support.path, 'notes.db'),
    filesDir: Directory(p.join(documents.path, 'attachments')),
  );
  final controller = AppController(
    repository: NotesRepository(store),
    engine: SyncEngine(store: store, server: server),
  );
  await controller.start();
  runApp(NotesApp(controller: controller));
}

class NotesApp extends StatelessWidget {
  const NotesApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline Notes',
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      home: NotesListPage(controller: controller),
    );
  }
}
