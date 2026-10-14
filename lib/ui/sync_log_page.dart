import 'dart:async';

import 'package:flutter/material.dart';

import '../sync/sync_log.dart';

class SyncLogPage extends StatefulWidget {
  const SyncLogPage({super.key, required this.log});

  final SyncLog log;

  @override
  State<SyncLogPage> createState() => _SyncLogPageState();
}

class _SyncLogPageState extends State<SyncLogPage> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Color? _color(String line) {
    if (line.contains('failed') || line.contains('gave up')) return Colors.red;
    if (line.contains('[conflict]')) return Colors.purple;
    if (line.contains('retry in')) return Colors.orange;
    if (line.contains('accepted') ||
        line.contains('created on server') ||
        line.contains('fully synced')) {
      return Colors.green.shade700;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.log.lines;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync log'),
        actions: [
          TextButton(
            onPressed: () => setState(widget.log.clear),
            child: const Text('Clear'),
          ),
        ],
      ),
      body: lines.isEmpty
          ? const Center(child: Text('Nothing logged yet'))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: lines.length,
              separatorBuilder: (_, _) => const Divider(height: 12),
              itemBuilder: (context, index) => SelectableText(
                lines[index],
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: _color(lines[index]),
                ),
              ),
            ),
    );
  }
}
