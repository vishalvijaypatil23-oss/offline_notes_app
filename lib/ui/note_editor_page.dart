import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../data/models.dart';
import 'attachment_tile.dart';
import 'sync_badge.dart';

class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({super.key, required this.controller, this.noteId});

  final AppController controller;
  final String? noteId;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String? _noteId;
  Note? _note;
  bool _pendingDelete = false;
  List<Attachment> _attachments = const [];
  String _loadedTitle = '';
  String _loadedBody = '';
  bool _closing = false;

  AppController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _noteId = widget.noteId;
    _controller.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _controller.removeListener(_load);
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = _noteId;
    if (id == null) return;
    final note = await _controller.note(id);
    final attachments = await _controller.attachments(id);
    final pendingDelete = await _controller.hasPendingDelete(id);
    if (!mounted || _closing) return;
    if (note == null) {
      _closing = true;
      Navigator.of(context).maybePop();
      return;
    }
    final untouched =
        _title.text == _loadedTitle && _body.text == _loadedBody;
    setState(() {
      _note = note;
      _attachments = attachments;
      _pendingDelete = pendingDelete;
      if (untouched) {
        _title.text = note.title;
        _body.text = note.body;
        _loadedTitle = note.title;
        _loadedBody = note.body;
      }
    });
  }

  Future<String?> _save() async {
    final title = _title.text;
    final body = _body.text;
    final id = _noteId;
    if (id == null) {
      if (title.isEmpty && body.isEmpty) return null;
      final newId = await _controller.createNote(title, body);
      _noteId = newId;
      _loadedTitle = title;
      _loadedBody = body;
      if (mounted) await _load();
      return newId;
    }
    if (title == _loadedTitle && body == _loadedBody) return id;
    _loadedTitle = title;
    _loadedBody = body;
    await _controller.saveNote(id, title, body);
    return id;
  }

  Future<void> _attach() async {
    final id = await _save() ?? await _controller.createNote('', '');
    _noteId = id;
    final result = await FilePicker.platform.pickFiles();
    final picked = result?.files.single;
    final path = picked?.path;
    if (picked == null || path == null) return;
    await _controller.addAttachment(id, File(path), picked.name);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final note = _note;
    final inConflict = note?.status == SyncStatus.conflict;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_save());
      },
      child: Scaffold(
        appBar: AppBar(
          title: note == null ? const Text('New note') : SyncBadge(note.status),
          actions: [
            IconButton(
              icon: const Icon(Icons.attach_file),
              tooltip: 'Attach',
              onPressed: _attach,
            ),
            IconButton(
              icon: const Icon(Icons.check),
              tooltip: 'Save',
              onPressed: () async {
                final navigator = Navigator.of(context);
                await _save();
                if (mounted) navigator.pop();
              },
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (note != null && inConflict)
              _ConflictCard(
                note: note,
                localDelete: _pendingDelete,
                onKeepMine: () async {
                  await _save();
                  await _controller.keepMine(note.id);
                },
                onKeepTheirs: () => _controller.keepTheirs(note.id),
              ),
            TextField(
              controller: _title,
              decoration: const InputDecoration(hintText: 'Title'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            TextField(
              controller: _body,
              decoration: const InputDecoration(
                hintText: 'Write something',
                border: InputBorder.none,
              ),
              maxLines: null,
              minLines: 8,
            ),
            for (final attachment in _attachments)
              AttachmentTile(
                key: ValueKey(attachment.id),
                controller: _controller,
                attachment: attachment,
              ),
          ],
        ),
      ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  const _ConflictCard({
    required this.note,
    required this.localDelete,
    required this.onKeepMine,
    required this.onKeepTheirs,
  });

  final Note note;
  final bool localDelete;
  final VoidCallback onKeepMine;
  final VoidCallback onKeepTheirs;

  @override
  Widget build(BuildContext context) {
    final theirs = note.conflictRow!;
    final deletedThere = theirs['deleted'] == true;
    final String message;
    final String mineLabel;
    final String theirsLabel;
    if (deletedThere) {
      message = 'This note was deleted on another device while you edited it.';
      mineLabel = 'Restore with my edits';
      theirsLabel = 'Delete it (keep my text as a copy)';
    } else if (localDelete) {
      message = 'You deleted this note, but another device edited it.';
      mineLabel = 'Delete anyway';
      theirsLabel = 'Keep their version';
    } else {
      message = 'This note was changed on another device.';
      mineLabel = 'Keep mine';
      theirsLabel = 'Keep theirs (save mine as a copy)';
    }
    return Card(
      color: Colors.purple.shade50,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
            if (!deletedThere) ...[
              const SizedBox(height: 8),
              const Text('Their version:'),
              Text('${theirs['title'] ?? ''}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('${theirs['body'] ?? ''}'),
              const SizedBox(height: 8),
              const Text('Your version is in the editor below.'),
            ],
            Wrap(
              spacing: 8,
              children: [
                TextButton(onPressed: onKeepMine, child: Text(mineLabel)),
                TextButton(onPressed: onKeepTheirs, child: Text(theirsLabel)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
