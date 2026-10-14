import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../data/models.dart';
import 'queue_inspector_page.dart';

class DebugPage extends StatelessWidget {
  const DebugPage({super.key, required this.controller});

  final AppController controller;

  Future<Note?> _pickNote(BuildContext context) {
    return showDialog<Note>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Pick a note'),
        children: [
          for (final note in controller.notes)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, note),
              child: Text(note.title.isEmpty ? 'Untitled' : note.title),
            ),
        ],
      ),
    );
  }

  Future<void> _otherDeviceEdit(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final note = await _pickNote(context);
    if (note == null || !context.mounted) return;
    final title = TextEditingController(text: '${note.title} (other device)');
    final body = TextEditingController(text: note.body);
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit as the other device'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            TextField(
              controller: body,
              decoration: const InputDecoration(labelText: 'Body'),
              maxLines: 4,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save on server'),
          ),
        ],
      ),
    );
    if (save != true) return;
    final ok = controller.otherDeviceEdit(
        note.id, {'title': title.text, 'body': body.text});
    messenger.showSnackBar(SnackBar(
      content: Text(ok
          ? 'Edited on the server as another device'
          : 'That note is not on the server yet'),
    ));
  }

  Future<void> _otherDeviceDelete(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final note = await _pickNote(context);
    if (note == null) return;
    final ok = controller.otherDeviceEdit(note.id, {'deleted': true});
    messenger.showSnackBar(SnackBar(
      content: Text(ok
          ? 'Deleted on the server as another device'
          : 'That note is not on the server yet'),
    ));
  }

  Future<void> _wipe(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Wipe local data?'),
        content: const Text(
            'Deletes the local database and cached files. The server folder is kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Wipe'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.wipeLocalData();
    messenger.showSnackBar(
      const SnackBar(content: Text('Local data wiped, pulling from server')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final faults = controller.faults;
        return Scaffold(
          appBar: AppBar(title: const Text('Debug')),
          body: ListView(
            children: [
              const ListTile(title: Text('Faults')),
              SwitchListTile(
                title: const Text('Offline'),
                value: faults.offline,
                onChanged: controller.setOffline,
              ),
              SwitchListTile(
                title: const Text('30% random failures'),
                value: faults.failureRate > 0,
                onChanged: controller.setRandomFailures,
              ),
              SwitchListTile(
                title: const Text('2 second latency'),
                value: faults.latency > Duration.zero,
                onChanged: controller.setLatency,
              ),
              SwitchListTile(
                title: const Text('Lose response after commit'),
                value: faults.loseResponseAfterCommit,
                onChanged: controller.setLoseResponse,
              ),
              const Divider(),
              const ListTile(
                title: Text('Other device'),
                subtitle: Text(
                    'Changes the note directly on the server, as if a second phone did it'),
              ),
              ListTile(
                leading: const Icon(Icons.edit_note),
                title: const Text('Simulate edit from other device'),
                onTap: () => _otherDeviceEdit(context),
              ),
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('Simulate delete from other device'),
                onTap: () => _otherDeviceDelete(context),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.list_alt),
                title: const Text('Queue inspector'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => QueueInspectorPage(controller: controller),
                )),
              ),
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: const Text('Wipe local data (keep server)'),
                onTap: () => _wipe(context),
              ),
            ],
          ),
        );
      },
    );
  }
}
