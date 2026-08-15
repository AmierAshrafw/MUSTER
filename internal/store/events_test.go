package store

import (
	"strings"
	"testing"
)

func seedTask(t *testing.T, s *Store, id string) {
	t.Helper()
	mustExec(t, s, `INSERT INTO tasks(id, plan, seq, type, tier, status, card_path, frontmatter_sha)
		VALUES (?, 'p', 1, 'impl', 'any', 'backlog', ?, 'x')`, id, ".muster/cards/"+id+".md")
}

func TestAppendEventChains(t *testing.T) {
	s := open(t)
	seedTask(t, s, "p-01-a")
	if err := s.AppendEvent("p-01-a", "claude/any", "claim", "", "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if err := s.AppendEvent("p-01-a", "claude/any", "attempt", "1", "2026-01-01T00:01:00Z"); err != nil {
		t.Fatal(err)
	}
	evs, err := s.Events("p-01-a")
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 2 {
		t.Fatalf("events: %d", len(evs))
	}
	if evs[0].PrevHash != "" {
		t.Fatalf("genesis prev: %q", evs[0].PrevHash)
	}
	if evs[1].PrevHash != evs[0].Hash {
		t.Fatalf("chain broken: %q vs %q", evs[1].PrevHash, evs[0].Hash)
	}
	head, err := s.ChainHead()
	if err != nil {
		t.Fatal(err)
	}
	if head != evs[1].Hash {
		t.Fatalf("head: %q", head)
	}
	if err := s.VerifyChain(); err != nil {
		t.Fatalf("chain must verify: %v", err)
	}
}

func TestVerifyChainDetectsForgedInsert(t *testing.T) {
	s := open(t)
	seedTask(t, s, "p-01-a")
	if err := s.AppendEvent("p-01-a", "claude/any", "claim", "", "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	// UPDATE/DELETE are trigger-blocked; a confused writer can still INSERT a
	// row with a fabricated hash. VerifyChain must catch it.
	mustExec(t, s, `INSERT INTO events(task_id, actor, verb, detail, created_at, prev_hash, hash)
		VALUES ('p-01-a', 'gremlin', 'done', '', '2026-01-01T00:02:00Z', 'nonsense', 'forged')`)
	err := s.VerifyChain()
	if err == nil || !strings.Contains(err.Error(), "chain") {
		t.Fatalf("forged insert not detected: %v", err)
	}
}

func TestAttemptAndClaimCounts(t *testing.T) {
	s := open(t)
	seedTask(t, s, "p-01-a")
	stamp := func(i int) string { return "2026-01-01T00:0" + string(rune('0'+i)) + ":00Z" }
	s.AppendEvent("p-01-a", "claude/any", "claim", "", stamp(0))
	s.AppendEvent("p-01-a", "claude/any", "attempt", "1", stamp(1))
	s.AppendEvent("p-01-a", "claude/any", "attempt", "2", stamp(2))
	// redo + fresh claim resets the attempt window (D28 semantics)
	s.AppendEvent("p-01-a", "human", "redo", "", stamp(3))
	s.AppendEvent("p-01-a", "claude/any", "claim", "", stamp(4))
	s.AppendEvent("p-01-a", "claude/any", "attempt", "1", stamp(5))
	n, err := s.AttemptsSinceClaim("p-01-a")
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("attempts = %d, want 1 (window resets at the newest claim)", n)
	}
	cc, err := s.ClaimCount("p-01-a")
	if err != nil {
		t.Fatal(err)
	}
	if cc != 2 {
		t.Fatalf("claims = %d", cc)
	}
}
