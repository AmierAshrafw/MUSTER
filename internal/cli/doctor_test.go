package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDoctorCleanBoard(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	// card exists on disk and at HEAD with the ingested sha
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-01-w.md"), []byte(claimCard), 0o644)
	if code := a.Dispatch("doctor", nil); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	if !strings.Contains(out.String(), "DOCTOR OK - board consistent.") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestDoctorFindsChainTamper(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-01-w.md"), []byte(claimCard), 0o644)
	a.St.DB().Exec(`INSERT INTO events(task_id, actor, verb, detail, created_at, prev_hash, hash)
		VALUES ('demo-01-w', 'gremlin', 'done', '', 'x', 'bad', 'forged')`)
	if code := a.Dispatch("doctor", nil); code != 1 {
		t.Fatal("must fail")
	}
	if !strings.Contains(out.String(), "DOCTOR FAIL events:") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestDoctorFindsMissingAndOrphanCards(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox") // no disk file: missing
	orphan := strings.NewReplacer("demo-01-w", "demo-07-orphan").Replace(claimCard)
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-07-orphan.md"), []byte(orphan), 0o644)
	if code := a.Dispatch("doctor", nil); code != 1 {
		t.Fatal("must fail")
	}
	s := out.String()
	if !strings.Contains(s, "DOCTOR FAIL cards: demo-01-w has no file on disk") {
		t.Fatalf("missing-card finding absent:\n%s", s)
	}
	if !strings.Contains(s, "DOCTOR FAIL cards: demo-07-orphan.md has no board row") {
		t.Fatalf("orphan finding absent:\n%s", s)
	}
}

func TestDoctorFindsShaDriftStaleDoingAndStaging(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-01-w.md"), []byte(claimCard), 0o644)
	a.St.DB().Exec(`UPDATE tasks SET frontmatter_sha='stale', claimed_at='2025-12-01T00:00:00Z' WHERE id='demo-01-w'`)
	os.WriteFile(filepath.Join(a.Dir, "staging", "stray.md"), []byte("x"), 0o644)
	if code := a.Dispatch("doctor", nil); code != 1 {
		t.Fatal("must fail")
	}
	s := out.String()
	for _, want := range []string{
		"DOCTOR FAIL drift: demo-01-w frontmatter sha differs from HEAD",
		"DOCTOR FAIL claims: demo-01-w doing since 2025-12-01T00:00:00Z",
		"DOCTOR FAIL staging: stray.md",
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %q:\n%s", want, s)
		}
	}
}

func TestDoctorFindsUnreconciledDone(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-01-w.md"), []byte(claimCard), 0o644)
	a.St.DB().Exec(`UPDATE tasks SET head_at_claim='head0', claimed_at='2026-01-02T00:00:00Z' WHERE id='demo-01-w'`)
	fake.GrepSHAs = []string{"deadbeef"}
	if code := a.Dispatch("doctor", nil); code != 1 {
		t.Fatal("must fail")
	}
	if !strings.Contains(out.String(), "DOCTOR FAIL drift: demo-01-w has a done commit but status doing") {
		t.Fatalf("out: %s", out.String())
	}
}
