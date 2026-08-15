package cli

import (
	"strings"
	"testing"
)

func TestEmbeddedTemplates(t *testing.T) {
	for _, want := range []string{
		"# RUNNER - executor contract (MUSTER v2)",
		"muster verify",
		".muster/cards/<task-id>.notes.md",
		"Session over.",
		"## Hard rules",
		"## RECOVERY (humans only)",
		"muster redo",
		"muster doctor",
	} {
		if !strings.Contains(RunnerMD, want) {
			t.Fatalf("RUNNER.md missing %q", want)
		}
	}
	for _, want := range []string{"muster.db", "backup.db"} {
		if !strings.Contains(GitignoreTemplate, want) {
			t.Fatalf("gitignore missing %q", want)
		}
	}
	for _, want := range []string{"* text=auto eol=lf", "*.db binary -text"} {
		if !strings.Contains(GitattributesTemplate, want) {
			t.Fatalf("gitattributes missing %q", want)
		}
	}
}
