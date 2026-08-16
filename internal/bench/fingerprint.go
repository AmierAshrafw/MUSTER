// internal/bench/fingerprint.go
package bench

import (
	"context"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Fingerprint is descriptive provenance (not causal). Tri-state string fields use
// "unknown" when a probe cannot answer — never a fabricated value.
type Fingerprint struct {
	OS                string `json:"os"`
	GoArch            string `json:"goarch"`
	GoVersion         string `json:"go_version"`
	GitVersion        string `json:"git_version"`
	BoxTag            string `json:"box_tag"`
	CPUModel          string `json:"cpu_model"`
	LogicalCores      int    `json:"logical_cores"`
	PhysicalCores     int    `json:"physical_cores"`    // 0 when the probe could not answer
	RAMTotalBytes     int64  `json:"ram_total_bytes"`   // 0 when the probe could not answer
	DefenderRealtime  string `json:"defender_realtime"` // "true"|"false"|"unknown"
	DefenderExclusion string `json:"defender_exclusions_cover_benchdir"`
	BenchTempVolume   string `json:"bench_temp_dir_volume"`
}

// probeFunc runs the batched PowerShell probe; injectable for tests.
type probeFunc func(context.Context) (string, error)

// captureFingerprint fills a Fingerprint. Runtime-derived fields always populate;
// PowerShell-derived fields degrade to "unknown" on any probe failure/timeout.
func captureFingerprint(probe probeFunc) Fingerprint {
	fp := Fingerprint{
		OS:                runtime.GOOS,
		GoArch:            runtime.GOARCH,
		GoVersion:         runtime.Version(),
		GitVersion:        gitVersion(),
		LogicalCores:      runtime.NumCPU(),
		DefenderRealtime:  "unknown",
		DefenderExclusion: "unknown",
		CPUModel:          "unknown",
		BenchTempVolume:   volumeOf(os.TempDir()),
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := probe(ctx)
	if err == nil {
		parseProbe(out, &fp)
	}
	fp.BoxTag = boxTag(fp.CPUModel) // composed AFTER the probe fills CPUModel
	return fp
}

// gitVersion reads `git --version`; "unknown" on failure. Not via PowerShell — a
// direct exec is cheaper and always available (git is a hard dependency).
func gitVersion() string {
	out, err := exec.Command("git", "--version").Output()
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(out))
}

// boxTag is a stable <short-cpu>-<hostname> tag (spec §5); comparisons are valid
// only within one tag. Falls back gracefully when parts are unknown.
func boxTag(cpuModel string) string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		h = "unknown-box"
	}
	short := "cpu"
	if fields := strings.Fields(cpuModel); len(fields) > 0 && cpuModel != "unknown" {
		short = strings.ToLower(fields[0])
	}
	return short + "-" + strings.ToLower(h)
}

func volumeOf(p string) string {
	if len(p) >= 2 && p[1] == ':' {
		return strings.ToUpper(p[:2])
	}
	return "unknown"
}

// parseProbe fills PS-derived fields from the batched probe output. Kept lenient:
// any field the probe omitted simply stays "unknown"/0.
func parseProbe(out string, fp *Fingerprint) {
	for _, line := range strings.Split(out, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		switch k {
		case "defender_realtime":
			fp.DefenderRealtime = v
		case "defender_exclusions":
			fp.DefenderExclusion = v // "present" | "none"
		case "cpu_model":
			fp.CPUModel = v
		case "physical_cores":
			if nCores, err := strconv.Atoi(strings.TrimSpace(v)); err == nil {
				fp.PhysicalCores = nCores
			}
		case "ram_total_bytes":
			if ram, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64); err == nil {
				fp.RAMTotalBytes = ram
			}
		}
	}
}
