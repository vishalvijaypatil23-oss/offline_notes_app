import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../data/models.dart';
import 'debug_page.dart';
import 'note_editor_page.dart';
import 'sync_badge.dart';

class NotesListPage extends StatelessWidget {
  const NotesListPage({super.key, required this.controller});

  final AppController controller;

  void _open(BuildContext context, String? noteId) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NoteEditorPage(controller: controller, noteId: noteId),
    ));
  }

  Future<void> _confirmDelete(BuildContext context, Note note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${note.title.isEmpty ? 'Untitled' : note.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.deleteNote(note.id);
  }

  String _syncLabel() {
    final last = controller.lastSyncedAt;
    final label =
        last == null ? 'Never synced' : 'Last synced ${clockTime(last)}';
    final error = controller.lastSyncError;
    return error == null ? label : '$label · $error';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final notes = controller.notes;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Notes'),
                Text(_syncLabel(), style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            actions: [
              if (controller.syncing)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.sync),
                tooltip: 'Sync now',
                onPressed: controller.refresh,
              ),
              IconButton(
                icon: const Icon(Icons.bug_report_outlined),
                tooltip: 'Debug',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DebugPage(controller: controller),
                  ),
                ),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: controller.refresh,
            child: notes.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: Text('No notes yet')),
                      ),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: notes.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final note = notes[index];
                      return ListTile(
                        title: Text(note.title.isEmpty ? 'Untitled' : note.title),
                        subtitle: Text(
                          note.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SyncBadge(note.status),
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: 'Edit',
                              onPressed: () => _open(context, note.id),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Delete',
                              onPressed: note.status == SyncStatus.conflict
                                  ? null
                                  : () => _confirmDelete(context, note),
                            ),
                          ],
                        ),
                        onTap: () => _open(context, note.id),
                      );
                    },
                  ),
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () => _open(context, null),
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }
}
