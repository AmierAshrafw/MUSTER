// internal/bench/workload_test.go
package bench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"muster/internal/card"
)

func TestGenerateDeterministic(t *testing.T) {
	_, m1 := Generate(1, 100)
	_, m2 := Generate(1, 100)
	if m1.SHA != m2.SHA {
		t.Fatalf("manifest SHA not deterministic: %s vs %s", m1.SHA, m2.SHA)
	}
	if len(m1.Entries) != 100 {
		t.Fatalf("manifest has %d entries, want 100", len(m1.Entries))
	}
}

func TestGenerateGoldenManifest(t *testing.T) {
	_, m := Generate(1, 10)
	// GOLDEN: regenerate intentionally if the template changes on purpose.
	const golden = "d965df384073104e2b5957638c624fb66300e46506c43d553c3983edbb815632"
	if golden != "" && m.SHA != golden {
		t.Fatalf("manifest SHA changed: got %s, want golden %s", m.SHA, golden)
	}
}

func TestGenerateFanInTopology(t *testing.T) {
	batches, _ := Generate(1, 10)
	if len(batches) != 1 {
		t.Fatalf("N=10 should be one batch, got %d", len(batches))
	}
	b := batches[0]
	if len(b.Impl) != 9 {
		t.Fatalf("want 9 impl, got %d", len(b.Impl))
	}
	if b.Integration.Type != "integration" {
		t.Fatalf("integration task type = %q", b.Integration.Type)
	}
	if !strings.Contains(b.Integration.ID, "-99-") {
		t.Fatalf("integration id %q must carry seq 99", b.Integration.ID)
	}
	if b.Integration.CommitPath != "" {
		t.Fatalf("integration must have no commit path")
	}
	// Integration depends on every impl in the batch.
	body := string(b.Integration.Bytes)
	for _, im := range b.Impl {
		if !strings.Contains(body, "- "+im.ID) {
			t.Fatalf("integration depends_on missing %s", im.ID)
		}
	}
}

func TestGenerateNoSeqKey(t *testing.T) {
	batches, _ := Generate(1, 10)
	for _, b := range batches {
		all := append(append([]Card{}, b.Impl...), b.Integration)
		for _, c := range all {
			// A "seq:" frontmatter line is an unknown-key Parse error.
			for _, line := range strings.Split(string(c.Bytes), "\n") {
				if strings.HasPrefix(strings.TrimSpace(line), "seq:") {
					t.Fatalf("card %s emits forbidden seq key", c.ID)
				}
			}
		}
	}
}

func TestBatchCountAndSizes(t *testing.T) {
	// N just over one batch splits into two.
	batches, _ := Generate(1, BatchMax+1)
	if len(batches) != 2 {
		t.Fatalf("N=BatchMax+1 should be 2 batches, got %d", len(batches))
	}
}

// lintBatch materializes one batch to a temp dir and lints it in Full mode.
func lintBatch(t *testing.T, b Batch) []string {
	t.Helper()
	dir := t.TempDir()
	var paths []string
	all := append(append([]Card{}, b.Impl...), b.Integration)
	for _, c := range all {
		p := filepath.Join(dir, filepath.Base(c.Path))
		if err := os.WriteFile(p, c.Bytes, 0o644); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, p)
	}
	return card.Lint(paths, func(string) bool { return false }, card.Full)
}

func TestWorkloadLintsClean(t *testing.T) {
	for _, n := range []int{10, BatchMax, BatchMax + 1, 1000} {
		batches, _ := Generate(1, n)
		for bi, b := range batches {
			if findings := lintBatch(t, b); len(findings) > 0 {
				t.Fatalf("N=%d batch %d lint findings: %v", n, bi, findings)
			}
		}
	}
}

func TestWorkloadParsesClean(t *testing.T) {
	batches, _ := Generate(1, 10)
	all := append(append([]Card{}, batches[0].Impl...), batches[0].Integration)
	for _, c := range all {
		if _, errs := card.Parse(string(c.Bytes), false); len(errs) > 0 {
			t.Fatalf("card %s Parse errors: %v", c.ID, errs)
		}
	}
}
