// internal/bench/record_test.go
package bench

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestRunIDStableAndDistinguishesWarmup(t *testing.T) {
	base := Row{Measurement: "full_loop", N: 100, Seed: 1, GeneratorVersion: "1", RepOrdinal: 3}
	warm := base
	warm.Warmup = true
	if RunID(base) == "" {
		t.Fatal("empty run_id")
	}
	if RunID(base) == RunID(warm) {
		t.Fatal("warmup and timed rows must not share a run_id")
	}
	if RunID(base) != RunID(base) {
		t.Fatal("run_id must be deterministic")
	}
	diffN := base
	diffN.RepOrdinal = 4
	if RunID(base) == RunID(diffN) {
		t.Fatal("different rep ordinals must yield different run_ids")
	}
}

func TestWriteRowRoundTrips(t *testing.T) {
	var buf bytes.Buffer
	r := Row{
		SchemaVersion: SchemaVersion, Measurement: "full_loop", N: 10,
		AttemptStatus: "ok", WallNS: 123, RepOrdinal: 0, Seed: 1,
	}
	if err := WriteRow(&buf, r); err != nil {
		t.Fatal(err)
	}
	var back Row
	if err := json.Unmarshal(buf.Bytes(), &back); err != nil {
		t.Fatal(err)
	}
	if back.AttemptStatus != "ok" || back.WallNS != 123 || back.SchemaVersion != 2 {
		t.Fatalf("round-trip mismatch: %+v", back)
	}
}

func TestAttemptStatusAlwaysPresent(t *testing.T) {
	var buf bytes.Buffer
	// A failed attempt still records a row with a non-empty status.
	r := Row{SchemaVersion: SchemaVersion, Measurement: "full_loop", AttemptStatus: "timeout", ErrorDetail: "deadline exceeded"}
	if err := WriteRow(&buf, r); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(buf.Bytes(), []byte(`"attempt_status":"timeout"`)) {
		t.Fatalf("attempt_status missing: %s", buf.String())
	}
}

func TestBenchfmtExportStableDimsOnly(t *testing.T) {
	rows := []Row{
		{Measurement: "full_loop", N: 100, AttemptStatus: "ok", WallNS: 1234567890},
		{Measurement: "full_loop", N: 100, AttemptStatus: "ok", WallNS: 1231110000},
		{Measurement: "full_loop", N: 100, AttemptStatus: "timeout", WallNS: 0}, // omitted
	}
	var sb strings.Builder
	if err := WriteBenchfmt(&sb, rows); err != nil {
		t.Fatal(err)
	}
	out := sb.String()
	if strings.Count(out, "BenchmarkFullLoop/n=100") != 2 {
		t.Fatalf("expected 2 ok rows exported, got:\n%s", out)
	}
	if !strings.Contains(out, "1234567890 ns/op") {
		t.Fatalf("missing ns/op line:\n%s", out)
	}
	// No provenance/timestamps/sha in the export (would fragment benchstat grouping).
	if strings.Contains(out, "sha") || strings.Contains(out, "exe_") {
		t.Fatalf("benchfmt leaked provenance dims:\n%s", out)
	}
}
