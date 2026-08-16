// internal/bench/fixture_test.go
package bench

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNewRepoRoundTripsLF(t *testing.T) {
	fx, err := NewFixture(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// Write an LF file, add+commit via the fixture's git wrapper, then read the
	// committed blob back; it must be byte-identical (no CRLF injection).
	rel := "src/lf.txt"
	want := []byte("bench\n")
	if err := fx.WriteFile(rel, want); err != nil {
		t.Fatal(err)
	}
	if err := fx.Git("-c", "core.autocrlf=false", "add", rel); err != nil {
		t.Fatal(err)
	}
	if err := fx.Git("-c", "core.autocrlf=false", "commit", "-q", "-m", "add lf"); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(fx.Root, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatalf("round-trip mangled bytes: got %q want %q", got, want)
	}
}

func TestBuildMusterStampsVCS(t *testing.T) {
	repoRoot := repoRootForTest(t) // resolves ../.. from this package
	exe := filepath.Join(t.TempDir(), "muster.exe")
	info, err := BuildMuster(repoRoot, exe)
	if err != nil {
		t.Fatal(err)
	}
	if info.VCSRevision == "" {
		t.Fatalf("built exe has no vcs.revision; buildvcs stamping failed")
	}
	if info.GoVersion == "" {
		t.Fatalf("built exe has no go version")
	}
}

func repoRootForTest(t *testing.T) string {
	t.Helper()
	abs, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return abs
}
