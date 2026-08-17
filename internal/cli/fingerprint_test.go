package cli

import (
	"strings"
	"testing"
)

func TestFingerprintVerb_PrintsDigest(t *testing.T) {
	a, _, out := newApp(t)                       // real helper returns (a, *gitx.Fake, out) (internal/cli/app_test.go:17)
	seed(t, a, "p-01-a", "impl", "any", "inbox") // real sig: seed(t,a,id,typ,tier,status,deps...) (app_test.go:42)
	code := a.Dispatch("fingerprint", nil)
	if code != 0 {
		t.Fatalf("want exit 0, got %d", code)
	}
	got := strings.TrimSpace(out.String())
	if len(got) != 64 { // sha256 hex
		t.Fatalf("want a 64-char hex digest, got %q", got)
	}
}
