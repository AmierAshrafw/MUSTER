package store

import "testing"

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
