// internal/bench/fingerprint_test.go
package bench

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestFingerprintFaultTolerant(t *testing.T) {
	// A probe that always errors must yield tri-state "unknown", not a panic.
	fp := captureFingerprint(func(context.Context) (string, error) {
		return "", errors.New("simulated probe failure")
	})
	if fp.DefenderRealtime != "unknown" {
		t.Fatalf("DefenderRealtime = %q, want unknown on probe failure", fp.DefenderRealtime)
	}
	if fp.BoxTag == "" {
		t.Fatalf("BoxTag must be populated from Go runtime even when PS fails")
	}
	if fp.OS == "" || fp.GoArch == "" {
		t.Fatalf("runtime-derived fields must be present")
	}
}

func TestFingerprintProbeTimeoutIsUnknown(t *testing.T) {
	fp := captureFingerprint(func(ctx context.Context) (string, error) {
		<-ctx.Done() // simulate a hung WMI provider
		return "", ctx.Err()
	})
	if fp.DefenderRealtime != "unknown" {
		t.Fatalf("timed-out probe must map to unknown")
	}
	_ = time.Second
}
