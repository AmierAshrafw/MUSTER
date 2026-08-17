package store

import (
	"strings"
	"testing"
)

func must(t *testing.T, err error) { t.Helper(); if err != nil { t.Fatal(err) } }

func TestReconcileReadHelpers(t *testing.T) {
	s := open(t)
	// impl + a review that references it via reviews, + a dependent
	must(t, s.Ingest([]IngestTask{
		row("p-01-a", "impl", "any"),
		{Task: Task{ID: "p-02-r", Plan: "p", Seq: 2, Type: "review", Tier: "strong",
			CardPath: ".muster/cards/p-02-r.md", FrontmatterSHA: "sha", Reviews: "p-01-a"},
			Deps: []string{"p-01-a"}},
	}, "shard", "2026-01-01T00:00:00Z"))

	if has, _ := s.HasTombstone("p-01-a"); has {
		t.Fatal("no tombstone yet")
	}
	inbound, _ := s.InboundDeps("p-01-a")
	if len(inbound) != 1 || inbound[0] != "p-02-r" {
		t.Fatalf("inbound deps: %v", inbound)
	}
	refs, _ := s.SemanticRefs("p-01-a")
	if len(refs) != 1 || refs[0] != "p-02-r" {
		t.Fatalf("semantic refs: %v", refs)
	}
}

func TestReconcileEligibilityGates(t *testing.T) {
	s := open(t)
	must(t, s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z"))
	// pristine backlog orphan -> eligible (no failures)
	info, fails, err := s.ReconcileEligibility("p-01-a")
	if err != nil || info == nil || len(fails) != 0 {
		t.Fatalf("expected eligible: info=%v fails=%v err=%v", info, fails, err)
	}
	// a claimed row -> ineligible
	mustExec(t, s, `UPDATE tasks SET status='doing', claimed_by='x' WHERE id='p-01-a'`)
	_, fails, _ = s.ReconcileEligibility("p-01-a")
	if len(fails) == 0 {
		t.Fatal("claimed/doing row must be ineligible")
	}
	// unknown id -> nil info, nil fails, nil err (caller checks HasTombstone)
	info, fails, err = s.ReconcileEligibility("nope")
	if info != nil || fails != nil || err != nil {
		t.Fatalf("unknown id: info=%v fails=%v err=%v", info, fails, err)
	}
}

func TestReconcilePrunesAndIsIdempotent(t *testing.T) {
	s := open(t)
	must(t, s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z"))

	pruned, err := s.Reconcile("p-01-a", "human", "leftover smoke card", "2026-01-02T00:00:00Z")
	if err != nil || !pruned {
		t.Fatalf("first reconcile: pruned=%v err=%v", pruned, err)
	}
	if got, _ := s.Task("p-01-a"); got != nil {
		t.Fatal("row must be gone")
	}
	deps, _ := s.Deps("p-01-a")
	if len(deps) != 0 {
		t.Fatalf("deps must be gone: %v", deps)
	}
	// tombstone event present, chain still verifies
	evs, _ := s.Events("p-01-a")
	last := evs[len(evs)-1]
	if last.Verb != "tombstone" || last.Actor != "human" ||
		!strings.Contains(last.Detail, "leftover smoke card") {
		t.Fatalf("tombstone event wrong: %+v", last)
	}
	if err := s.VerifyChain(); err != nil {
		t.Fatalf("chain broken after prune: %v", err)
	}
	// second call is idempotent success (row already gone, tombstone present)
	pruned, err = s.Reconcile("p-01-a", "human", "", "2026-01-02T00:01:00Z")
	if err != nil || pruned {
		t.Fatalf("second reconcile should be idempotent no-op: pruned=%v err=%v", pruned, err)
	}
}

func TestReconcileRefusesNonPristineInTx(t *testing.T) {
	s := open(t)
	must(t, s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z"))
	// give it a claim event -> not pristine
	must(t, s.AppendEvent("p-01-a", "claude/any", "claim", "", "2026-01-01T01:00:00Z"))
	if _, err := s.Reconcile("p-01-a", "human", "", "2026-01-02T00:00:00Z"); err == nil {
		t.Fatal("reconcile must refuse a non-pristine row in-tx")
	}
	if got, _ := s.Task("p-01-a"); got == nil {
		t.Fatal("row must survive a refused reconcile")
	}
}

func TestReconcileRefusesReferencedRow(t *testing.T) {
	s := open(t)
	// p-02-r references p-01-a via reviews AND depends_on (inbound dep + semantic ref)
	must(t, s.Ingest([]IngestTask{
		row("p-01-a", "impl", "any"),
		{Task: Task{ID: "p-02-r", Plan: "p", Seq: 2, Type: "review", Tier: "strong",
			CardPath: ".muster/cards/p-02-r.md", FrontmatterSHA: "sha", Reviews: "p-01-a"},
			Deps: []string{"p-01-a"}},
	}, "shard", "2026-01-01T00:00:00Z"))
	_, fails, err := s.ReconcileEligibility("p-01-a")
	if err != nil || len(fails) == 0 {
		t.Fatalf("referenced impl must be ineligible: fails=%v err=%v", fails, err)
	}
	if _, err := s.Reconcile("p-01-a", "human", "", "2026-01-02T00:00:00Z"); err == nil {
		t.Fatal("Reconcile must refuse a row referenced via deps/reviews")
	}
	if got, _ := s.Task("p-01-a"); got == nil {
		t.Fatal("referenced row must survive")
	}
}

func TestIngestRefusesReconciledID(t *testing.T) {
	s := open(t)
	must(t, s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z"))
	if _, err := s.Reconcile("p-01-a", "human", "", "2026-01-02T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	err := s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-03T00:00:00Z")
	if err == nil || !strings.Contains(err.Error(), "reconciled") {
		t.Fatalf("re-ingest of a reconciled id must refuse, got: %v", err)
	}
}
