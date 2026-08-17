package store

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func row(id, typ, tier string, deps ...string) IngestTask {
	return IngestTask{
		Task: Task{ID: id, Plan: "p", Seq: 1, Type: typ, Tier: tier,
			CardPath: ".muster/cards/" + id + ".md", FrontmatterSHA: "sha-" + id},
		Deps: deps,
	}
}

func TestIngestAndQueries(t *testing.T) {
	s := open(t)
	batch := []IngestTask{
		row("p-01-a", "impl", "any"),
		row("p-02-b", "impl", "any", "p-01-a"),
	}
	if err := s.Ingest(batch, "shard", "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	got, err := s.Task("p-02-b")
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || got.Status != "backlog" || got.FrontmatterSHA != "sha-p-02-b" {
		t.Fatalf("row: %+v", got)
	}
	if missing, _ := s.Task("nope"); missing != nil {
		t.Fatal("absent id must return nil")
	}
	bl, err := s.TasksByStatus("backlog")
	if err != nil || len(bl) != 2 {
		t.Fatalf("backlog: %v %v", bl, err)
	}
	evs, _ := s.Events("p-01-a")
	if len(evs) != 1 || evs[0].Verb != "ingest" {
		t.Fatalf("ingest event missing: %+v", evs)
	}
}

func TestIngestFailsClosedOnUnknownDep(t *testing.T) {
	s := open(t)
	err := s.Ingest([]IngestTask{row("p-01-a", "impl", "any", "ghost-99-x")}, "shard", "2026-01-01T00:00:00Z")
	if err == nil || !strings.Contains(err.Error(), "ghost-99-x") {
		t.Fatalf("unknown dep must fail closed: %v", err)
	}
	// the whole batch must roll back
	if got, _ := s.Task("p-01-a"); got != nil {
		t.Fatal("failed batch must not leave rows")
	}
}

func TestIngestRefusesDuplicateID(t *testing.T) {
	s := open(t)
	if err := s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	err := s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:01:00Z")
	if err == nil || !strings.Contains(err.Error(), "already on the board") {
		t.Fatalf("duplicate must refuse: %v", err)
	}
}

func TestStatusFlips(t *testing.T) {
	s := open(t)
	s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z")
	mustExec(t, s, `UPDATE tasks SET status='doing' WHERE id='p-01-a'`)
	if err := s.MarkDone("p-01-a", "claude/any", "2026-01-01T01:00:00Z"); err != nil {
		t.Fatal(err)
	}
	got, _ := s.Task("p-01-a")
	if got.Status != "done" {
		t.Fatalf("status: %s", got.Status)
	}
	if err := s.MarkDone("p-01-a", "claude/any", "2026-01-01T01:01:00Z"); err == nil {
		t.Fatal("MarkDone from done must error (guarded flip)")
	}
	if err := s.MarkInbox("p-01-a", "human", "2026-01-01T01:02:00Z"); err == nil {
		t.Fatal("redo from done must error")
	}
	mustExec(t, s, `UPDATE tasks SET status='failed' WHERE id='p-01-a'`)
	if err := s.MarkInbox("p-01-a", "human", "2026-01-01T01:03:00Z"); err != nil {
		t.Fatal(err)
	}
	got, _ = s.Task("p-01-a")
	if got.Status != "inbox" || got.ClaimedAt != "" || got.HeadAtClaim != "" {
		t.Fatalf("redo must clear claim fields: %+v", got)
	}
}

func TestVerdicts(t *testing.T) {
	s := open(t)
	s.Ingest([]IngestTask{row("p-02-r", "review", "strong")}, "shard", "2026-01-01T00:00:00Z")
	if err := s.InsertVerdict("p-02-r", "claude/strong", "fail", "wrong shape", "2026-01-01T02:00:00Z"); err != nil {
		t.Fatal(err)
	}
	vs, err := s.Verdicts("p-02-r")
	if err != nil || len(vs) != 1 || vs[0].Reason != "wrong shape" {
		t.Fatalf("verdicts: %+v %v", vs, err)
	}
}

func TestBackup(t *testing.T) {
	s := open(t)
	s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z")
	dst := filepath.Join(t.TempDir(), "backup.db")
	if err := s.Backup(dst); err != nil {
		t.Fatal(err)
	}

	// Mutate the source, then back up again: the overwrite path must land a
	// fresh snapshot at dst - not fail, and not leave the stale first snapshot.
	s.Ingest([]IngestTask{row("p-02-b", "impl", "any")}, "shard", "2026-01-01T00:01:00Z")
	if err := s.Backup(dst); err != nil { // second run must overwrite, not fail
		t.Fatal(err)
	}
	if _, err := os.Stat(dst); err != nil { // a backup file must exist at dst
		t.Fatal(err)
	}

	b, err := Open(dst)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	if got, _ := b.Task("p-01-a"); got == nil {
		t.Fatal("backup lost rows")
	}
	if got, _ := b.Task("p-02-b"); got == nil {
		t.Fatal("overwrite kept a stale snapshot")
	}
}

func TestBackupPreservesExistingOnRefreshFailure(t *testing.T) {
	s := open(t)
	s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z")
	dst := filepath.Join(t.TempDir(), "backup.db")
	if err := s.Backup(dst); err != nil {
		t.Fatal(err)
	}

	tmp := dst + ".tmp"
	if err := os.Mkdir(tmp, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tmp, "keep"), []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := s.Backup(dst); err == nil {
		t.Fatal("refresh with an unusable temp path must fail")
	}

	if _, err := os.Stat(dst); err != nil {
		t.Fatalf("existing backup was removed: %v", err)
	}
	b, err := Open(dst)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	got, _ := b.Task("p-01-a")
	if got == nil {
		t.Fatal("existing backup is no longer valid")
	}
}
