package store

import "testing"

func fpBoard(t *testing.T) *Store {
	t.Helper()
	s := open(t) // real store test helper (internal/store/store_test.go:8)
	// tasks.card_path and tasks.frontmatter_sha are TEXT NOT NULL with no
	// default (schema.go:14-15) - include them, or the INSERT fails setup. If
	// the tasks table has other NOT NULL columns, mirror the working seed at
	// internal/store/store_test.go:65-66.
	mustExec(t, s, `INSERT INTO tasks(id,plan,type,tier,harness,status,seq,card_path,frontmatter_sha) VALUES
		('p-01-a','p','impl','any','','inbox',1,'.muster/cards/p-01-a.md','sha-a'),
		('p-02-b','p','impl','any','codex','done',2,'.muster/cards/p-02-b.md','sha-b')`)
	return s
}

func TestFingerprint_StableOnNoOp(t *testing.T) {
	s := fpBoard(t)
	a, err := s.Fingerprint()
	if err != nil { t.Fatal(err) }
	b, err := s.Fingerprint()
	if err != nil { t.Fatal(err) }
	if a == "" || a != b {
		t.Fatalf("want stable non-empty digest, got %q then %q", a, b)
	}
}

func TestFingerprint_DetectsStatusForge(t *testing.T) {
	s := fpBoard(t)
	before, _ := s.Fingerprint()
	mustExec(t, s, `UPDATE tasks SET status='done' WHERE id='p-01-a'`)
	after, _ := s.Fingerprint()
	if before == after {
		t.Fatal("digest must change when a task status is forged to done")
	}
}

func TestFingerprint_DetectsEventInsert(t *testing.T) {
	s := fpBoard(t)
	before, _ := s.Fingerprint()
	mustExec(t, s, `INSERT INTO events(task_id,actor,verb,detail,created_at,prev_hash,hash)
		VALUES('p-01-a','codex','claim','x','2026-01-01','0','deadbeef')`)
	after, _ := s.Fingerprint()
	if before == after {
		t.Fatal("digest must change when an event is forged")
	}
}
