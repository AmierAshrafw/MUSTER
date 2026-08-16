// internal/bench/version_test.go
package bench

import "testing"

func TestVersionConstantsPresent(t *testing.T) {
	if SchemaVersion != 2 {
		t.Fatalf("SchemaVersion = %d, want 2", SchemaVersion)
	}
	if BatchMax < 100 || BatchMax > 280 {
		t.Fatalf("BatchMax = %d, want a size-cap-safe value in [100,280]", BatchMax)
	}
	for name, v := range map[string]string{
		"HarnessVersion": HarnessVersion, "FixtureVersion": FixtureVersion,
		"GeneratorVersion": GeneratorVersion,
	} {
		if v == "" {
			t.Fatalf("%s is empty", name)
		}
	}
}
