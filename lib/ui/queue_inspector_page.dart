import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../data/models.dart';

class QueueInspectorPage extends StatefulWidget {
  const QueueInspectorPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<QueueInspectorPage> createState() => _QueueInspectorPageState();
}

class _QueueInspectorPageState extends State<QueueInspectorPage> {
  List<OutboxEntry> _entries = const [];
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_load);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _load());
    _load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_load);
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final entries = await widget.controller.queue();
    if (mounted) setState(() => _entries = entries);
  }

  Color _color(OutboxStatus status) => switch (status) {
        OutboxStatus.queued => Colors.orange,
        OutboxStatus.inFlight => Colors.blue,
        OutboxStatus.done => Colors.green,
        OutboxStatus.failed => Colors.red,
      };

  String _nextAttempt(OutboxEntry entry) {
    if (entry.status != OutboxStatus.queued) return '';
    final wait = entry.nextAttemptAt.difference(DateTime.now()).inSeconds;
    return wait > 0 ? ' · retry in ${wait}s' : ' · ready';
  }

  @override
  Widget build(BuildContext context) {
    final counts = <OutboxStatus, int>{};
    for (final e in _entries) {
      counts[e.status] = (counts[e.status] ?? 0) + 1;
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Queue'),
        actions: [
          TextButton(
            onPressed: widget.controller.retryFailed,
            child: const Text('Retry failed'),
          ),
          TextButton(
            onPressed: widget.controller.clearDone,
            child: const Text('Clear done'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 8,
              children: [
                for (final status in OutboxStatus.values)
                  Chip(
                    label: Text('${status.value}: ${counts[status] ?? 0}'),
                    side: BorderSide(color: _color(status)),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _entries.length,
              itemBuilder: (context, index) {
                final e = _entries[index];
                return ListTile(
                  isThreeLine: true,
                  leading: CircleAvatar(
                    backgroundColor: _color(e.status),
                    child: Text('${e.id}',
                        style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                  title: Text(
                      '${e.entityType} ${e.op} · ${e.status.value} · ${e.lane} lane'),
                  subtitle: Text(
                    'note ${e.noteId.substring(0, 8)} · attempts ${e.attempts}'
                    '${e.baseVersion == null ? '' : ' · base v${e.baseVersion}'}'
                    '${_nextAttempt(e)}\n'
                    '${jsonEncode(e.payload)}'
                    '${e.lastError == null ? '' : '\nerror: ${e.lastError}'}',
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
