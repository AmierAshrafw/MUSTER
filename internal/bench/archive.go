// internal/bench/archive.go
package bench

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
)

// ArchiveSpec bundles the perishable, non-recreatable assets to preserve.
type ArchiveSpec struct {
	Exe        string
	Batches    []Batch
	Manifest   Manifest
	BuildJSON  []byte
	Invocation []byte
}

// Archive writes an immutable content-addressed dir under destRoot and returns
// its sha. Same inputs -> same sha. Real bytes are stored, not just hashes.
func Archive(destRoot string, spec ArchiveSpec) (string, error) {
	exeBytes, err := os.ReadFile(spec.Exe)
	if err != nil {
		return "", err
	}
	sum := sha256.New()
	sum.Write(exeBytes)
	sum.Write([]byte(spec.Manifest.SHA))
	sum.Write(spec.BuildJSON)
	sum.Write(spec.Invocation)
	shaHex := hex.EncodeToString(sum.Sum(nil))[:32]

	dir := filepath.Join(destRoot, shaHex)
	if _, err := os.Stat(dir); err == nil {
		return shaHex, nil // immutable: already materialized, never rewrite
	}
	tmp := dir + ".tmp"
	if err := os.MkdirAll(filepath.Join(tmp, "workload"), 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(tmp, "muster.exe"), exeBytes, 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(tmp, "build.json"), spec.BuildJSON, 0o644); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(tmp, "invocation.json"), spec.Invocation, 0o644); err != nil {
		return "", err
	}
	for _, b := range spec.Batches {
		all := append(append([]Card{}, b.Impl...), b.Integration)
		for _, c := range all {
			if err := os.WriteFile(filepath.Join(tmp, "workload", filepath.Base(c.Path)), c.Bytes, 0o644); err != nil {
				return "", err
			}
		}
	}
	if err := os.Rename(tmp, dir); err != nil {
		return "", err
	}
	return shaHex, nil
}
