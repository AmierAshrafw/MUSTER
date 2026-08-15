package store

import (
	"reflect"
	"testing"
)

func TestPromoteLiftsOnlySatisfied(t *testing.T) {
	s := open(t)
	s.Ingest([]IngestTask{
		row("p-01-a", "impl", "any"),
		row("p-02-b", "impl", "any", "p-01-a"),
		row("p-03-c", "impl", "any", "p-02-b"),
	}, "shard", "2026-01-01T00:00:00Z")

	moved, err := s.Promote("system", "2026-01-01T00:01:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(moved, []string{"p-01-a"}) {
		t.Fatalf("moved: %v", moved)
	}
	moved, _ = s.Promote("system", "2026-01-01T00:02:00Z") // idempotent
	if len(moved) != 0 {
		t.Fatalf("second promote moved: %v", moved)
	}
	mustExec(t, s, `UPDATE tasks SET status='done' WHERE id='p-01-a'`)
	moved, _ = s.Promote("system", "2026-01-01T00:03:00Z")
	if !reflect.DeepEqual(moved, []string{"p-02-b"}) {
		t.Fatalf("after dep done: %v", moved)
	}
	got, _ := s.Task("p-03-c")
	if got.Status != "backlog" {
		t.Fatalf("p-03-c must stay blocked: %s", got.Status)
	}
}

func TestDeadBlocked(t *testing.T) {
	s := open(t)
	s.Ingest([]IngestTask{
		row("p-01-a", "impl", "any"),
		row("p-02-b", "impl", "any", "p-01-a"),
	}, "shard", "2026-01-01T00:00:00Z")
	mustExec(t, s, `UPDATE tasks SET status='failed' WHERE id='p-01-a'`)
	dead, err := s.DeadBlocked()
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(dead, []string{"p-02-b behind failed p-01-a"}) {
		t.Fatalf("dead: %v", dead)
	}
}

func TestBoardCounts(t *testing.T) {
	s := open(t)
	s.Ingest([]IngestTask{
		row("p-01-a", "impl", "any"),
		row("p-02-r", "review", "strong"),
		row("p-03-c", "impl", "any"),
		row("p-04-d", "impl", "any", "p-01-a"),
	}, "shard", "2026-01-01T00:00:00Z")
	mustExec(t, s, `UPDATE tasks SET status='inbox' WHERE id IN ('p-01-a','p-02-r')`)
	mustExec(t, s, `UPDATE tasks SET status='doing', claimed_at='2026-01-01T00:00:00Z',
		claimed_by='claude/any' WHERE id='p-03-c'`)
	b, err := s.Board()
	if err != nil {
		t.Fatal(err)
	}
	if b.InboxRun != 1 || b.InboxReview != 1 || b.Backlog != 1 || b.Done != 0 || b.Failed != 0 {
		t.Fatalf("counts: %+v", b)
	}
	if !reflect.DeepEqual(b.InboxIDs, []string{"p-01-a", "p-02-r"}) {
		t.Fatalf("inbox ids: %v", b.InboxIDs)
	}
	if len(b.Doing) != 1 || b.Doing[0].ID != "p-03-c" {
		t.Fatalf("doing: %+v", b.Doing)
	}
	if b.Total() != 4 {
		t.Fatalf("total: %d", b.Total())
	}
}
