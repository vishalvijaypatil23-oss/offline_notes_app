import 'package:flutter/material.dart';

import '../data/models.dart';

class SyncBadge extends StatelessWidget {
  const SyncBadge(this.status, {super.key});

  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (status) {
      SyncStatus.synced => (Icons.cloud_done_outlined, Colors.green),
      SyncStatus.pending => (Icons.cloud_upload_outlined, Colors.orange),
      SyncStatus.failed => (Icons.error_outline, Colors.red),
      SyncStatus.conflict => (Icons.call_split, Colors.purple),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(status.name, style: TextStyle(color: color, fontSize: 12)),
      ],
    );
  }
}

String clockTime(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
