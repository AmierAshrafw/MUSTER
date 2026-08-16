// internal/bench/workload.go
package bench

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
)

type Card struct {
	ID         string
	Path       string
	Bytes      []byte
	Type       string
	CommitPath string
}

type Batch struct {
	Plan        string
	Impl        []Card
	Integration Card
}

type ManifestEntry struct {
	Index int    `json:"index"`
	ID    string `json:"id"`
	SHA   string `json:"sha256"`
}
type Manifest struct {
	Entries []ManifestEntry `json:"entries"`
	SHA     string          `json:"manifest_sha256"`
}

const implTemplate = `---
id: %[1]s
plan: %[2]s
type: impl
tier: any
depends_on: []
protected: []
commit_paths:
  - %[3]s
verify:
  - cmd: git --version
    expect_exit: 0
---
# %[1]s: bench impl task

## Context
Synthetic benchmark task. Fixed template; only the id varies.

## Steps
1. Create %[3]s containing the single line bench.

## Acceptance
- The commit path file exists.
`

const integrationTemplate = `---
id: %[1]s
plan: %[2]s
type: integration
tier: strong
depends_on:
%[3]s
verify:
  - cmd: git --version
    expect_exit: 0
---
# %[1]s: bench integration task

## Context
Synthetic benchmark integration task. Fixed template; only the id and deps vary.

## Steps
1. Confirm the batch is green.

## Acceptance
- git is present.
`

// Generate produces the fan-in workload for n tasks with the given seed. The
// seed is recorded but the workload is a pure function of (seed, n); no clock or
// randomness enters card bytes, so bytes are identical across versions.
//
// Requires n >= 2 (a fan-in batch needs >=1 impl + exactly 1 integration). Tasks
// are split across ceil(n/BatchMax) batches by an EVEN split, so no trailing
// batch is ever degenerate (size 1 -> implN 0 -> empty depends_on, which
// card.Parse rejects). For our N set (10/100/1000) this yields 1/1/4 batches.
func Generate(seed int64, n int) ([]Batch, Manifest) {
	nb := (n + BatchMax - 1) / BatchMax
	if nb < 1 {
		nb = 1
	}
	base, rem := n/nb, n%nb // even split; first `rem` batches get one extra
	var batches []Batch
	var entries []ManifestEntry
	idx := 0
	for bi := 0; bi < nb; bi++ {
		size := base
		if bi < rem {
			size++
		}
		plan := fmt.Sprintf("benchb%d", bi)
		implN := size - 1 // one slot reserved for the integration task
		var impl []Card
		var depLines []string
		for i := 0; i < implN; i++ {
			id := fmt.Sprintf("%s-01-t%06d", plan, idx)
			commitPath := "src/" + id + ".txt"
			bytes := []byte(fmt.Sprintf(implTemplate, id, plan, commitPath))
			c := Card{ID: id, Path: ".muster/cards/" + id + ".md", Bytes: bytes, Type: "impl", CommitPath: commitPath}
			impl = append(impl, c)
			depLines = append(depLines, "  - "+id)
			entries = append(entries, ManifestEntry{Index: idx, ID: id, SHA: sha(bytes)})
			idx++
		}
		intID := fmt.Sprintf("%s-99-integration", plan)
		intBytes := []byte(fmt.Sprintf(integrationTemplate, intID, plan, strings.Join(depLines, "\n")))
		integration := Card{ID: intID, Path: ".muster/cards/" + intID + ".md", Bytes: intBytes, Type: "integration"}
		entries = append(entries, ManifestEntry{Index: idx, ID: intID, SHA: sha(intBytes)})
		idx++
		batches = append(batches, Batch{Plan: plan, Impl: impl, Integration: integration})
	}
	return batches, Manifest{Entries: entries, SHA: manifestSHA(entries)}
}

func sha(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

func manifestSHA(entries []ManifestEntry) string {
	h := sha256.New()
	for _, e := range entries {
		fmt.Fprintf(h, "%d\x00%s\x00%s\n", e.Index, e.ID, e.SHA)
	}
	return hex.EncodeToString(h.Sum(nil))
}
