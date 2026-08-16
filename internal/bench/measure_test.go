// internal/bench/measure_test.go
package bench

import "testing"

func TestMusterArgsForLifecycle(t *testing.T) {
	// The lifecycle command builder must produce the verified verb argv.
	if got := claimArgs("any"); got[0] != "claim" {
		t.Fatalf("claim argv = %v", got)
	}
	if !contains(claimArgs("any"), "-harness") || !contains(claimArgs("any"), "-tier") {
		t.Fatalf("claim must pass -harness and -tier: %v", claimArgs("any"))
	}
	// The tier value must be threaded through, not hard-pinned (impl=any, integration=strong).
	if !contains(claimArgs("any"), "any") || !contains(claimArgs("strong"), "strong") {
		t.Fatalf("claim must thread the requested tier")
	}
	if implDoneArgs()[0] != "done" || len(implDoneArgs()) != 1 {
		t.Fatalf("impl done takes no verdict: %v", implDoneArgs())
	}
	if intDoneArgs()[0] != "done" || intDoneArgs()[1] != "pass" {
		t.Fatalf("integration done must be 'done pass': %v", intDoneArgs())
	}
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}
