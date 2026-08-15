package store

import (
	"path/filepath"
	"sync"
	"testing"
)

func seedInbox(t *testing.T, s *Store, id, tier, harness string) {
	t.Helper()
	mustExec(t, s, `INSERT INTO tasks(id, plan, seq, type, tier, harness, status, card_path, frontmatter_sha)
		VALUES (?, 'p', 1, 'impl', ?, ?, 'inbox', ?, 'x')`, id, tier, harness, ".muster/cards/"+id+".md")
}

func TestNextEligibleOrderAndPinning(t *testing.T) {
	s := open(t)
	seedInbox(t, s, "p-03-c", "any", "")
	seedInbox(t, s, "p-01-a", "strong", "")
	seedInbox(t, s, "p-02-b", "any", "codex")

	got, err := s.NextEligible("any", "claude")
	if err != nil {
		t.Fatal(err)
	}
	// p-01-a is strong (tier equality excludes it), p-02-b is pinned codex:
	// the lowest eligible id for claude/any is p-03-c.
	if got == nil || got.ID != "p-03-c" {
		t.Fatalf("eligible: %+v", got)
	}
	strong, err := s.NextEligible("strong", "claude")
	if err != nil {
		t.Fatal(err)
	}
	if strong == nil || strong.ID != "p-01-a" {
		t.Fatalf("strong session must take only strong tasks: %+v", strong)
	}
	codex, err := s.NextEligible("any", "codex")
	if err != nil {
		t.Fatal(err)
	}
	if codex == nil || codex.ID != "p-02-b" {
		t.Fatalf("codex pin: %+v", codex)
	}
}

func TestClaimTaskFlipsAndStamps(t *testing.T) {
	s := open(t)
	seedInbox(t, s, "p-01-a", "any", "")
	ok, err := s.ClaimTask("p-01-a", "claude/any", "abc123", "2026-01-01T00:00:00Z")
	if err != nil || !ok {
		t.Fatalf("claim: %v %v", ok, err)
	}
	got, _ := s.Task("p-01-a")
	if got.Status != "doing" || got.HeadAtClaim != "abc123" || got.ClaimedBy != "claude/any" ||
		got.ClaimedAt != "2026-01-01T00:00:00Z" {
		t.Fatalf("stamps: %+v", got)
	}
	evs, _ := s.Events("p-01-a")
	if len(evs) != 1 || evs[0].Verb != "claim" {
		t.Fatalf("claim event: %+v", evs)
	}
}

func TestClaimTaskRefusesWhenDoingOccupied(t *testing.T) {
	s := open(t)
	seedInbox(t, s, "p-01-a", "any", "")
	seedInbox(t, s, "p-02-b", "any", "")
	if ok, _ := s.ClaimTask("p-01-a", "claude/any", "h", "2026-01-01T00:00:00Z"); !ok {
		t.Fatal("first claim must win")
	}
	_, err := s.ClaimTask("p-02-b", "claude/any", "h", "2026-01-01T00:01:00Z")
	if err != ErrDoingOccupied {
		t.Fatalf("second claim must hit ErrDoingOccupied: %v", err)
	}
}

func TestClaimTaskRacedAway(t *testing.T) {
	s := open(t)
	seedInbox(t, s, "p-01-a", "any", "")
	mustExec(t, s, `UPDATE tasks SET status='done' WHERE id='p-01-a'`)
	ok, err := s.ClaimTask("p-01-a", "claude/any", "h", "2026-01-01T00:00:00Z")
	if err != nil || ok {
		t.Fatalf("stale candidate must return ok=false: %v %v", ok, err)
	}
}

func TestClaimRaceTwoConnections(t *testing.T) {
	// Two Store handles on the same FILE = two SQLite connections, the
	// in-process stand-in for the two-process race (the real two-process proof
	// is in the process tier). Exactly one winner per round, every round.
	for round := 0; round < 10; round++ {
		path := filepath.Join(t.TempDir(), "race.db")
		a, err := Open(path)
		if err != nil {
			t.Fatal(err)
		}
		b, err := Open(path)
		if err != nil {
			t.Fatal(err)
		}
		seedInbox(t, a, "p-01-a", "any", "")

		var wg sync.WaitGroup
		results := make([]bool, 2)
		errs := make([]error, 2)
		for i, st := range []*Store{a, b} {
			wg.Add(1)
			go func(i int, st *Store) {
				defer wg.Done()
				results[i], errs[i] = st.ClaimTask("p-01-a", "racer", "h", "2026-01-01T00:00:00Z")
			}(i, st)
		}
		wg.Wait()
		wins := 0
		for i := range results {
			if errs[i] != nil && errs[i] != ErrDoingOccupied {
				t.Fatalf("round %d racer %d: %v", round, i, errs[i])
			}
			if results[i] {
				wins++
			}
		}
		if wins != 1 {
			t.Fatalf("round %d: %d winners", round, wins)
		}
		a.Close()
		b.Close()
	}
}
