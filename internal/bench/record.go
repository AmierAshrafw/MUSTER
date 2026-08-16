// internal/bench/record.go
package bench

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"runtime"
)

// Row is one attempt record. Failed attempts are recorded too (no survivorship
// bias). Speculative paired columns (arm/pair/block) are intentionally absent;
// they arrive at SchemaVersion 3 with the paired runner.
type Row struct {
	SchemaVersion int    `json:"schema_version"`
	RunID         string `json:"run_id"`
	ExperimentID  string `json:"experiment_id"`
	SessionID     string `json:"session_id"`
	ActualOrder   int    `json:"actual_order_index"`

	AttemptStatus string `json:"attempt_status"` // ok|error|timeout|crash|cancelled
	ExitCode      int    `json:"exit_code"`
	ErrorDetail   string `json:"error_detail,omitempty"`
	Warmup        bool   `json:"warmup"`
	WarmupReason  string `json:"warmup_reason,omitempty"`
	Excluded      bool   `json:"excluded"`
	ExcludeReason string `json:"exclude_reason,omitempty"`

	Measurement string `json:"measurement"` // full_loop|cold_verb
	Verb        string `json:"verb,omitempty"`
	N           int    `json:"n"`
	RepOrdinal  int    `json:"rep_ordinal"`

	Seed             int64  `json:"seed"`
	GeneratorVersion string `json:"generator_version"`
	Topology         string `json:"topology"`
	WorkloadSHA      string `json:"workload_manifest_sha256"`
	BatchSizes       []int  `json:"batch_sizes"`
	BatchCount       int    `json:"batch_count"`
	ImplCount        int    `json:"impl_count"`
	IntegrationCount int    `json:"integration_count"`
	BoardStateSHA    string `json:"board_state_sha256,omitempty"`

	WallNS          int64   `json:"wall_ns"`
	PerTaskNSTrace  []int64 `json:"per_task_ns_trace,omitempty"`
	ChildMusterNS   int64   `json:"child_muster_ns_sum"`
	VerifierSpawns  int     `json:"verifier_spawns"`
	GitCommitCount  int     `json:"git_commit_count"`
	ExecutorWriteNS int64   `json:"executor_write_ns"`
	StartedUTC      string  `json:"started_utc"`
	EndedUTC        string  `json:"ended_utc"`

	ExeSHA256      string      `json:"exe_sha256"`
	ExeBuildInfo   ExeInfo     `json:"exe_buildinfo"`
	BuildRecipeSHA string      `json:"build_recipe_sha256"`
	HarnessVersion string      `json:"harness_version"`
	HarnessSHA256  string      `json:"harness_sha256"`
	FixtureVersion string      `json:"fixture_version"`
	ArtifactSHA    string      `json:"artifact_sha"`
	Env            Fingerprint `json:"env"`
}

// RunID is a deterministic id over the stratum keys (no clock/random). Warmup is
// part of the key so a warmup rep and its same-ordinal timed rep never collide.
func RunID(r Row) string {
	key := fmt.Sprintf("%s\x00%s\x00%d\x00%d\x00%d\x00%s\x00%t",
		r.ExperimentID, r.Measurement+r.Verb, r.N, r.Seed, r.RepOrdinal, r.GeneratorVersion, r.Warmup)
	h := sha256.Sum256([]byte(key))
	return hex.EncodeToString(h[:16])
}

// WriteRow appends one JSON object + newline (JSONL). Fills RunID if empty.
func WriteRow(w io.Writer, r Row) error {
	if r.RunID == "" {
		r.RunID = RunID(r)
	}
	b, err := json.Marshal(r)
	if err != nil {
		return err
	}
	if _, err := w.Write(append(b, '\n')); err != nil {
		return err
	}
	return nil
}

// WriteBenchfmt emits Go benchmark format (design 14313) for later benchstat
// convenience. Only successful rows; only stable comparison dims in the name.
func WriteBenchfmt(w io.Writer, rows []Row) error {
	fmt.Fprintf(w, "goos: %s\ngoarch: %s\npkg: muster-bench\n", runtime.GOOS, runtime.GOARCH)
	for _, r := range rows {
		if r.AttemptStatus != "ok" || r.Warmup {
			continue
		}
		name := benchName(r)
		if _, err := fmt.Fprintf(w, "%s 1 %d ns/op\n", name, r.WallNS); err != nil {
			return err
		}
	}
	return nil
}

func benchName(r Row) string {
	switch r.Measurement {
	case "cold_verb":
		return fmt.Sprintf("BenchmarkColdVerb/%s/n=%d", r.Verb, r.N)
	default:
		return fmt.Sprintf("BenchmarkFullLoop/n=%d", r.N)
	}
}
