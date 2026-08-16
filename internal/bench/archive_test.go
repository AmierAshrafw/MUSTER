// internal/bench/archive_test.go
package bench

import (
	"os"
	"path/filepath"
	"testing"
)

func TestArchiveContentAddressedAndImmutable(t *testing.T) {
	dest := t.TempDir()
	exe := filepath.Join(t.TempDir(), "muster.exe")
	if err := os.WriteFile(exe, []byte("FAKE-EXE-BYTES"), 0o644); err != nil {
		t.Fatal(err)
	}
	batches, man := Generate(1, 10)
	spec := ArchiveSpec{
		Exe:        exe,
		Batches:    batches,
		Manifest:   man,
		BuildJSON:  []byte(`{"go":"go1.25.0"}`),
		Invocation: []byte(`{"n":[10]}`),
	}
	sha1, err := Archive(dest, spec)
	if err != nil {
		t.Fatal(err)
	}
	if sha1 == "" {
		t.Fatal("empty artifact sha")
	}
	// Same inputs -> same sha dir (idempotent, immutable).
	sha2, err := Archive(dest, spec)
	if err != nil {
		t.Fatal(err)
	}
	if sha1 != sha2 {
		t.Fatalf("archive sha not stable: %s vs %s", sha1, sha2)
	}
	// The materialized workload bytes (not just a hash) must be on disk.
	got, err := os.ReadFile(filepath.Join(dest, sha1, "workload", filepath.Base(batches[0].Impl[0].Path)))
	if err != nil {
		t.Fatalf("materialized workload missing: %v", err)
	}
	if string(got) != string(batches[0].Impl[0].Bytes) {
		t.Fatal("archived workload bytes differ from generated")
	}
	if _, err := os.Stat(filepath.Join(dest, sha1, "muster.exe")); err != nil {
		t.Fatalf("archived exe missing: %v", err)
	}
}
