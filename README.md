# Offline Notes

Offline-first notes app with attachments, syncing against the provided `fake_server.dart`.

```
flutter pub get
flutter test
flutter run
```

## Architecture

- `lib/ui`, `lib/app`: screens and the controller. They only read and write the local database.
- `lib/data`: SQLite tables (`notes`, `attachments`, `outbox`, `sync_meta`) and the repository. Each change and its outbox entry are saved in one transaction.
- `lib/sync`: the outbox, conflict merge and `SyncEngine`. This is the only code that calls the server, and it has no Flutter imports.

Sync runs on start, resume, pull-to-refresh, reconnect and after local edits.

## Outbox

- One chain per note and per attachment, run in order (first in, first out). Unrelated chains don't wait on each other.
- An attachment's chain runs: create row → upload file → set `storage_path`. The row is only created after its note is on the server.
- Two lanes, text and file, drain in parallel inside one run. Only one run happens at a time.
- Retry waits 1 s, doubling up to 60 s, with jitter. After 5 attempts the entry is marked failed. Network failures are re-queued on reconnect.
- Edits to the same note are merged into one entry. A create followed by a delete before any push cancels out.
- On startup, entries left `in_flight` go back to `queued`. Resending is safe because of `AlreadyExists` handling and the version check.

## Conflict policy

Each note stores the last server version it saw. On `Conflict`, fields changed on only one side are merged automatically. If the same field changed on both sides, or a delete clashes with an edit, the note is marked **conflict** and the user picks "keep mine" or "keep theirs". "Keep theirs" saves the local text as a copy, so nothing is lost silently. The device clock is never used to decide who wins.

## Known gaps

- No resumable uploads: a failed upload sends the whole file again.
- No delete for a single attachment.
- No real connectivity listener and no background sync.
