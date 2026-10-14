import 'dart:io';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../data/models.dart';
import 'sync_badge.dart';

class AttachmentTile extends StatefulWidget {
  const AttachmentTile({
    super.key,
    required this.controller,
    required this.attachment,
  });

  final AppController controller;
  final Attachment attachment;

  @override
  State<AttachmentTile> createState() => _AttachmentTileState();
}

class _AttachmentTileState extends State<AttachmentTile> {
  late Future<File?> _file;

  @override
  void initState() {
    super.initState();
    _file = widget.controller.attachmentFile(widget.attachment.id);
  }

  @override
  void didUpdateWidget(AttachmentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.attachment;
    final now = widget.attachment;
    if (old.storagePath != now.storagePath || old.localPath != now.localPath) {
      _file = widget.controller.attachmentFile(now.id);
    }
  }

  void _retry() {
    setState(() {
      _file = widget.controller.attachmentFile(widget.attachment.id);
    });
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final attachment = widget.attachment;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FutureBuilder<File?>(
            future: _file,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 80,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return ListTile(
                  leading: const Icon(Icons.cloud_off),
                  title: const Text('Download failed'),
                  subtitle: Text('${snapshot.error}'),
                  trailing: TextButton(
                    onPressed: _retry,
                    child: const Text('Retry'),
                  ),
                );
              }
              final file = snapshot.data;
              if (file == null) {
                return const ListTile(
                  leading: Icon(Icons.hourglass_empty),
                  title: Text('Not uploaded yet'),
                );
              }
              if (attachment.isImage) {
                return Image.file(file, height: 200, fit: BoxFit.cover);
              }
              return const SizedBox.shrink();
            },
          ),
          ListTile(
            dense: true,
            leading: Icon(
              attachment.isImage ? Icons.image_outlined : Icons.insert_drive_file,
            ),
            title: Text(attachment.fileName),
            subtitle: Text(_size(attachment.sizeBytes)),
            trailing: SyncBadge(attachment.status),
          ),
        ],
      ),
    );
  }
}
