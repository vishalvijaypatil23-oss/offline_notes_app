import 'package:flutter_test/flutter_test.dart';
import 'package:offline_notes/data/models.dart';

import 'support/harness.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.create());
  tearDown(() async => h.dispose());

  group('push', () {
    test('a note created offline stays pending, then syncs once online',
        () async {
      h.server.faults.offline = true;
      final id = await h.repo.createNote(title: 'groceries', body: 'milk');
      await h.engine.sync();

      expect((await h.repo.note(id))!.status, SyncStatus.pending);
      expect((await h.openEntries()).single.attempts, 1);

      h.server.faults.offline = false;
      await h.later();

      final note = (await h.repo.note(id))!;
      expect(note.status, SyncStatus.synced);
      expect(note.baseVersion, 1);
      expect((await h.server.get('notes', id))!['title'], 'groceries');
    });

    test('lost response on create: no duplicate row, note ends synced',
        () async {
      final id = await h.repo.createNote(title: 'once', body: '');
      h.server.faults.loseResponseAfterCommit = true;
      await h.engine.sync();
      expect((await h.repo.note(id))!.status, SyncStatus.pending);

      h.server.faults.loseResponseAfterCommit = false;
      await h.later();

      expect((await h.repo.note(id))!.status, SyncStatus.synced);
      final rows = await h.server.changesSince('notes', 0);
      expect(rows.where((r) => r['id'] == id), hasLength(1));
      expect(rows.single['version'], 1);
    });

    test('lost response on update is recognised as our own write', () async {
      final id = await h.syncedNote('draft', '');
      await h.repo.updateNote(id, title: 'final', body: '');
      h.server.faults.loseResponseAfterCommit = true;
      await h.engine.sync();

      h.server.faults.loseResponseAfterCommit = false;
      await h.later();

      final note = (await h.repo.note(id))!;
      expect(note.status, SyncStatus.synced);
      expect(note.conflictRow, isNull);
      final row = (await h.server.get('notes', id))!;
      expect(row['title'], 'final');
      expect(row['version'], 2);
    });

    test('lost response on delete still ends with a tombstone', () async {
      final id = await h.syncedNote('bye', '');
      await h.repo.deleteNote(id);
      h.server.faults.loseResponseAfterCommit = true;
      await h.engine.sync();

      h.server.faults.loseResponseAfterCommit = false;
      await h.later();

      expect(await h.repo.note(id), isNull);
      expect((await h.server.get('notes', id))!['deleted'], isTrue);
    });

    test('a backing-off note does not hold up an unrelated note', () async {
      h.server.faults.offline = true;
      final slow = await h.repo.createNote(title: 'slow', body: '');
      await h.engine.sync();
      h.server.faults.offline = false;

      final fast = await h.repo.createNote(title: 'fast', body: '');
      await h.engine.sync();

      expect((await h.repo.note(fast))!.status, SyncStatus.synced);
      expect((await h.repo.note(slow))!.status, SyncStatus.pending);
    });
  });

  group('queue', () {
    test('edits coalesce into one entry and create + delete cancels out',
        () async {
      h.server.faults.offline = true;
      final a = await h.repo.createNote(title: 'a', body: '');
      for (var i = 1; i <= 5; i++) {
        await h.repo.updateNote(a, title: 'a$i', body: '');
      }
      var open = await h.openEntries();
      expect(open, hasLength(1));
      expect(open.single.op, Op.create);
      expect(open.single.payload['title'], 'a5');

      final b = await h.repo.createNote(title: 'b', body: '');
      await h.repo.deleteNote(b);

      expect(await h.repo.note(b), isNull);
      open = await h.openEntries();
      expect(open.map((e) => e.noteId), everyElement(a));
    });

    test('edits made while a push is backing off still become one push',
        () async {
      final id = await h.syncedNote('x0', '');
      h.server.faults.offline = true;
      await h.repo.updateNote(id, title: 'x1', body: '');
      await h.engine.sync();
      for (var i = 2; i <= 5; i++) {
        await h.repo.updateNote(id, title: 'x$i', body: '');
      }
      final open = await h.openEntries();
      expect(open, hasLength(1));
      expect(open.single.payload, {'title': 'x5'});

      h.server.faults.offline = false;
      await h.later();

      final row = (await h.server.get('notes', id))!;
      expect(row['title'], 'x5');
      expect(row['version'], 2);
    });

    test('backs off, fails after five attempts, reconnect re-queues',
        () async {
      h.server.faults.offline = true;
      final id = await h.repo.createNote(title: 'stubborn', body: '');

      await h.engine.sync();
      final first = (await h.openEntries()).single;
      final wait = first.nextAttemptAt.difference(h.clock.now);
      expect(wait.inMilliseconds, inInclusiveRange(500, 1000));

      for (var i = 0; i < 4; i++) {
        await h.later();
      }
      final failed = (await h.openEntries()).single;
      expect(failed.status, OutboxStatus.failed);
      expect(failed.attempts, 5);
      expect(failed.errorKind, ErrorKind.network);
      expect((await h.repo.note(id))!.status, SyncStatus.failed);

      h.server.faults.offline = false;
      await h.engine.sync(retryNetworkFailures: true);
      expect((await h.repo.note(id))!.status, SyncStatus.synced);
    });

    test('a failed note can be retried on its own', () async {
      h.server.faults.offline = true;
      final id = await h.repo.createNote(title: 'retry me', body: '');
      await h.engine.sync();
      for (var i = 0; i < 4; i++) {
        await h.later();
      }
      expect((await h.repo.note(id))!.status, SyncStatus.failed);

      h.server.faults.offline = false;
      await h.repo.retryNote(id);
      expect((await h.repo.note(id))!.status, SyncStatus.pending);

      await h.engine.sync();
      expect((await h.repo.note(id))!.status, SyncStatus.synced);
    });

    test('in-flight entries go back to queued on restart and resend safely',
        () async {
      final id = await h.repo.createNote(title: 'crash', body: '');
      final entry = (await h.openEntries()).single;
      await h.store.db.update('outbox', {'status': 'in_flight'},
          where: 'id = ?', whereArgs: [entry.id]);
      await h.server.insert('notes', {'id': id, 'title': 'crash', 'body': ''});

      await h.restart();
      expect((await h.openEntries()).single.status, OutboxStatus.queued);

      await h.engine.sync();
      expect((await h.repo.note(id))!.status, SyncStatus.synced);
      expect(await h.server.changesSince('notes', 0), hasLength(1));
    });
  });

  group('conflicts', () {
    test('same field edited on both sides is surfaced and nothing is lost',
        () async {
      final id = await h.syncedNote('plan', 'body');
      h.engine.simulateOtherDeviceEdit(id, {'title': 'their plan'});
      await h.repo.updateNote(id, title: 'my plan', body: 'body');
      await h.engine.sync();

      final note = (await h.repo.note(id))!;
      expect(note.status, SyncStatus.conflict);
      expect(note.title, 'my plan');
      expect(note.conflictRow!['title'], 'their plan');

      await h.repo.keepTheirs(id);
      await h.engine.sync();

      final notes = await h.repo.notes();
      expect(notes.map((n) => n.title),
          containsAll(['their plan', 'my plan (my copy)']));
      expect(notes.map((n) => n.status), everyElement(SyncStatus.synced));
    });

    test('keep mine pushes my version on top of theirs', () async {
      final id = await h.syncedNote('plan', 'body');
      h.engine.simulateOtherDeviceEdit(id, {'title': 'their plan'});
      await h.repo.updateNote(id, title: 'my plan', body: 'body');
      await h.engine.sync();

      await h.repo.keepMine(id);
      await h.engine.sync();

      expect((await h.repo.note(id))!.status, SyncStatus.synced);
      final row = (await h.server.get('notes', id))!;
      expect(row['title'], 'my plan');
      expect(row['version'], 3);
    });

    test('edits to different fields merge without asking', () async {
      final id = await h.syncedNote('title', 'body');
      h.engine.simulateOtherDeviceEdit(id, {'body': 'their body'});
      await h.repo.updateNote(id, title: 'my title', body: 'body');
      await h.engine.sync();

      final note = (await h.repo.note(id))!;
      expect(note.status, SyncStatus.synced);
      expect(note.title, 'my title');
      expect(note.body, 'their body');
      final row = (await h.server.get('notes', id))!;
      expect(row['title'], 'my title');
      expect(row['body'], 'their body');
    });

    test('remote delete vs local edit: user can restore with their edits',
        () async {
      final id = await h.syncedNote('keep me', 'old');
      h.engine.simulateOtherDeviceEdit(id, {'deleted': true});
      await h.repo.updateNote(id, title: 'keep me', body: 'new');
      await h.engine.sync();

      final note = (await h.repo.note(id))!;
      expect(note.status, SyncStatus.conflict);
      expect(note.conflictRow!['deleted'], isTrue);
      expect((await h.repo.notes()).map((n) => n.id), contains(id));

      await h.repo.keepMine(id);
      await h.engine.sync();

      final row = (await h.server.get('notes', id))!;
      expect(row['deleted'], isFalse);
      expect(row['body'], 'new');
    });

    test('local delete vs remote edit: keeping theirs brings the note back',
        () async {
      final id = await h.syncedNote('shared', 'body');
      h.engine.simulateOtherDeviceEdit(id, {'title': 'shared, edited'});
      await h.repo.deleteNote(id);
      await h.engine.sync();

      expect((await h.repo.note(id))!.status, SyncStatus.conflict);

      await h.repo.keepTheirs(id);
      await h.engine.sync();

      final note = (await h.repo.note(id))!;
      expect(note.deleted, isFalse);
      expect(note.title, 'shared, edited');
      expect(note.status, SyncStatus.synced);
      expect((await h.server.get('notes', id))!['deleted'], isFalse);
    });
  });

  group('pull', () {
    test('never overwrites a row that still has pending changes', () async {
      final id = await h.syncedNote('orig', 'body');
      h.engine.simulateOtherDeviceEdit(id, {'title': 'theirs'});
      await h.repo.updateNote(id, title: 'orig', body: 'mine');

      await h.engine.pull();

      final note = (await h.repo.note(id))!;
      expect(note.title, 'orig');
      expect(note.body, 'mine');
      expect(note.baseVersion, 1);
    });

    test('pages through changes and stores the cursor', () async {
      for (var i = 0; i < 5; i++) {
        await h.server.insert('notes', {'id': 'remote-$i', 'title': 't$i', 'body': ''});
      }
      await h.engine.sync();

      expect(await h.repo.notes(), hasLength(5));
      expect(await h.store.readMeta('cursor:notes'), '5');
    });

    test('remote tombstone removes a clean local note', () async {
      final id = await h.syncedNote('gone soon', '');
      h.engine.simulateOtherDeviceEdit(id, {'deleted': true});
      await h.engine.sync();
      expect(await h.repo.note(id), isNull);
    });
  });

  group('attachments', () {
    test('file uploads after its note, storage_path is set last', () async {
      h.server.faults.offline = true;
      final id = await h.repo.createNote(title: 'with photo', body: '');
      final bytes = List<int>.generate(5000, (i) => i % 256);
      await h.repo.addAttachment(id, await h.tempFile('photo.jpg', bytes));

      final open = await h.openEntries();
      expect(open.map((e) => e.op),
          [Op.setPath, Op.upload, Op.create, Op.create]);

      h.server.faults.offline = false;
      await h.later();

      final attachment = (await h.repo.attachments(id)).single;
      expect(attachment.status, SyncStatus.synced);
      final row = (await h.server.get('attachments', attachment.id))!;
      expect(row['storage_path'], '$id/${attachment.id}');
      expect(row['mime_type'], 'image/jpeg');
      expect(await h.server.downloadFile('$id/${attachment.id}'), bytes);
    });

    test('fresh install pulls notes back and downloads files lazily',
        () async {
      final id = await h.syncedNote('trip', 'photos');
      final bytes = List<int>.generate(1000, (i) => (i * 7) % 256);
      await h.repo.addAttachment(id, await h.tempFile('map.png', bytes));
      await h.engine.sync();

      await h.engine.wipeLocalData();
      await h.engine.sync();

      expect((await h.repo.notes()).single.title, 'trip');
      final attachment = (await h.repo.attachments(id)).single;
      expect(attachment.localPath, isNull);

      final file = await h.engine.ensureAttachmentFile(attachment.id);
      expect(await file!.readAsBytes(), bytes);
      expect((await h.repo.attachments(id)).single.localPath, isNotNull);
    });
  });
}
