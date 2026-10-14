const noteTextFields = ['title', 'body'];

enum MergeOutcome { alreadyApplied, retry, conflict }

class UpdateMerge {
  const UpdateMerge(this.outcome, [this.toSend = const {}]);

  final MergeOutcome outcome;
  final Map<String, Object?> toSend;
}

bool _isServerDeleted(Map<String, Object?> server) => server['deleted'] == true;

UpdateMerge mergeUpdate({
  required Map<String, Object?> base,
  required Map<String, Object?> server,
  required Map<String, Object?> mine,
  required List<Map<String, Object?>> sent,
}) {
  final restoring = mine['deleted'] == false;
  if (_isServerDeleted(server) && !restoring) {
    return const UpdateMerge(MergeOutcome.conflict);
  }
  final toSend = <String, Object?>{};
  for (final entry in mine.entries) {
    final key = entry.key;
    final theirs = server[key];
    if (theirs == entry.value) continue;
    if (key == 'deleted') {
      toSend[key] = entry.value;
      continue;
    }
    final ours = theirs == base[key] || sent.any((s) => s[key] == theirs);
    if (!ours) return const UpdateMerge(MergeOutcome.conflict);
    toSend[key] = entry.value;
  }
  if (toSend.isEmpty) return const UpdateMerge(MergeOutcome.alreadyApplied);
  return UpdateMerge(MergeOutcome.retry, toSend);
}

MergeOutcome mergeDelete({
  required Map<String, Object?> base,
  required Map<String, Object?> server,
  required Map<String, Object?> local,
}) {
  if (_isServerDeleted(server)) return MergeOutcome.alreadyApplied;
  for (final key in noteTextFields) {
    final theirs = server[key];
    if (theirs != base[key] && theirs != local[key]) {
      return MergeOutcome.conflict;
    }
  }
  return MergeOutcome.retry;
}
