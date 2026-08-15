package store

// migrations[i] is schema version i+1. Each runs inside one transaction; the
// runner records the new version in the same transaction.
var migrations = []string{`
CREATE TABLE tasks(
  id TEXT PRIMARY KEY,
  plan TEXT NOT NULL,
  seq INTEGER NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('impl','review','fix','integration')),
  tier TEXT NOT NULL CHECK (tier IN ('any','strong')),
  harness TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL CHECK (status IN ('backlog','inbox','doing','done','failed')),
  card_path TEXT NOT NULL,
  frontmatter_sha TEXT NOT NULL,
  reviews TEXT NOT NULL DEFAULT '',
  fixes TEXT NOT NULL DEFAULT '',
  head_at_claim TEXT NOT NULL DEFAULT '',
  claimed_at TEXT NOT NULL DEFAULT '',
  claimed_by TEXT NOT NULL DEFAULT '',
  generation INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE deps(
  task_id TEXT NOT NULL REFERENCES tasks(id),
  depends_on TEXT NOT NULL REFERENCES tasks(id),
  PRIMARY KEY (task_id, depends_on)
) WITHOUT ROWID;
CREATE TABLE events(
  id INTEGER PRIMARY KEY,
  task_id TEXT NOT NULL,
  actor TEXT NOT NULL,
  verb TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  prev_hash TEXT NOT NULL,
  hash TEXT NOT NULL
);
CREATE TRIGGER events_no_update BEFORE UPDATE ON events
BEGIN SELECT RAISE(ABORT, 'events are append-only'); END;
CREATE TRIGGER events_no_delete BEFORE DELETE ON events
BEGIN SELECT RAISE(ABORT, 'events are append-only'); END;
CREATE TABLE verdicts(
  task_id TEXT NOT NULL,
  reviewer TEXT NOT NULL,
  verdict TEXT NOT NULL CHECK (verdict IN ('pass','fail')),
  reason TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);
CREATE INDEX verdicts_task ON verdicts(task_id);
CREATE TABLE schema_version(version INTEGER NOT NULL);
INSERT INTO schema_version(version) VALUES (0);
`}
