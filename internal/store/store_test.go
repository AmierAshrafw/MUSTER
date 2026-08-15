package store

import (
	"path/filepath"
	"testing"
)

func open(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "muster.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestOpenAppliesPragmas(t *testing.T) {
	s := open(t)
	for pragma, want := range map[string]string{
		"journal_mode": "wal",
		"synchronous":  "2", // FULL
		"foreign_keys": "1",
	} {
		var got string
		if err := s.db.QueryRow("PRAGMA " + pragma).Scan(&got); err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Fatalf("%s = %q, want %q", pragma, got, want)
		}
	}
}

func TestMigrateSetsVersionAndIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "m.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	var v int
	if err := s.db.QueryRow("SELECT version FROM schema_version").Scan(&v); err != nil {
		t.Fatal(err)
	}
	if v != 1 {
		t.Fatalf("version = %d", v)
	}
	s.Close()
	s2, err := Open(path) // reopen must not re-run migration 1
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	if err := s2.db.QueryRow("SELECT version FROM schema_version").Scan(&v); err != nil {
		t.Fatal(err)
	}
	if v != 1 {
		t.Fatalf("version after reopen = %d", v)
	}
}

func TestEventsAreAppendOnly(t *testing.T) {
	s := open(t)
	mustExec(t, s, `INSERT INTO tasks(id, plan, seq, type, tier, status, card_path, frontmatter_sha)
		VALUES ('p-01-a', 'p', 1, 'impl', 'any', 'backlog', '.muster/cards/p-01-a.md', 'x')`)
	mustExec(t, s, `INSERT INTO events(task_id, actor, verb, detail, created_at, prev_hash, hash)
		VALUES ('p-01-a', 't', 'claim', '', '2026-01-01T00:00:00Z', '', 'h1')`)
	if _, err := s.db.Exec(`UPDATE events SET verb='done'`); err == nil {
		t.Fatal("UPDATE on events must be blocked")
	}
	if _, err := s.db.Exec(`DELETE FROM events`); err == nil {
		t.Fatal("DELETE on events must be blocked")
	}
}

func TestStatusCheckConstraint(t *testing.T) {
	s := open(t)
	if _, err := s.db.Exec(`INSERT INTO tasks(id, plan, seq, type, tier, status, card_path, frontmatter_sha)
		VALUES ('p-01-a', 'p', 1, 'impl', 'any', 'flying', 'x', 'x')`); err == nil {
		t.Fatal("illegal status must be rejected")
	}
}

func mustExec(t *testing.T, s *Store, q string, args ...any) {
	t.Helper()
	if _, err := s.db.Exec(q, args...); err != nil {
		t.Fatal(err)
	}
}
