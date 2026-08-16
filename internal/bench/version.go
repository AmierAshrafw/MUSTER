// internal/bench/version.go
// Package bench is the MUSTER v2.0 performance-baseline recorder. It measures
// board mechanics against the real muster.exe in temp git repos and records
// self-describing observations. See docs/superpowers/specs/2026-08-16-muster-bench-recorder-design.md.
package bench

const (
	// SchemaVersion is the JSONL row schema. Bumped to 3 when the paired runner
	// adds arm/pair/block columns.
	SchemaVersion = 2

	// HarnessVersion / FixtureVersion / GeneratorVersion pin the measurement
	// apparatus; every row records them so drift is detectable.
	HarnessVersion   = "1"
	FixtureVersion   = "1"
	GeneratorVersion = "1"

	// BatchMax is the max tasks per ingest batch. The real cap is the 300-line /
	// 16 KB card size limit (lint rule 6): the integration card lists every
	// sibling in depends_on, one line each. Pinned by TestBatchMaxUnderSizeCap.
	BatchMax = 250
)
