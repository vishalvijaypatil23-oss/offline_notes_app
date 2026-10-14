const schemaVersion = 1;

const schemaStatements = [
  '''
CREATE TABLE notes (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL DEFAULT '',
  deleted INTEGER NOT NULL DEFAULT 0,
  base_version INTEGER,
  base_title TEXT,
  base_body TEXT,
  sync_status TEXT NOT NULL DEFAULT 'pending',
  conflict_row TEXT,
  updated_at INTEGER NOT NULL
)''',
  '''
CREATE TABLE attachments (
  id TEXT PRIMARY KEY,
  note_id TEXT NOT NULL,
  file_name TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  local_path TEXT,
  storage_path TEXT,
  base_version INTEGER,
  sync_status TEXT NOT NULL DEFAULT 'pending',
  created_at INTEGER NOT NULL
)''',
  'CREATE INDEX attachments_by_note ON attachments(note_id)',
  '''
CREATE TABLE outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  note_id TEXT NOT NULL,
  chain TEXT NOT NULL,
  lane TEXT NOT NULL,
  op TEXT NOT NULL,
  payload TEXT NOT NULL,
  sent_log TEXT NOT NULL DEFAULT '[]',
  base_version INTEGER,
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL,
  last_error TEXT,
  error_kind TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)''',
  'CREATE INDEX outbox_by_chain ON outbox(chain, status)',
  'CREATE INDEX outbox_by_lane ON outbox(lane, status, next_attempt_at)',
  'CREATE INDEX outbox_by_note ON outbox(note_id, status)',
  '''
CREATE TABLE sync_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
)''',
];
