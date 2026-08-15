//go:build process

package process

import (
	"strings"
	"testing"
)

const reviewCardP2 = `---
id: p2-02-review-hello
plan: p2
type: review
tier: strong
reviews: p2-01-hello
depends_on:
  - p2-01-hello
verify:
  - cmd: git --version
    expect_exit: 0
---
# p2-02-review-hello: review hello

## Context
Process-tier review fixture.

## Steps
1. Read the completion commit's diff. If wrong, author ONE fix card into
   .muster/staging/ and run muster done fail.

## Acceptance
- verdict filed
`

const stagedFixP2 = `---
id: p2-01-fix-hello
plan: p2
type: fix
tier: any
fixes: p2-01-hello
depends_on: []
protected: []
commit_paths:
  - src/hello.txt
verify:
  - cmd: findstr better src\hello.txt
    expect_exit: 0
---
# p2-01-fix-hello: make hello better

## Context
Reviewer-authored fix.

## Steps
1. Append the word better to src/hello.txt.

## Acceptance
- findstr finds better
`

func TestReviewCycleEndToEnd(t *testing.T) {
	skipOffWindows(t)
	intWithReview := strings.Replace(integrationCardP2,
		"depends_on:\n  - p2-01-hello", "depends_on:\n  - p2-01-hello\n  - p2-02-review-hello", 1)
	repo := boardWithCards(t, map[string]string{
		"p2-01-hello.md":        implCardP2,
		"p2-02-review-hello.md": reviewCardP2,
		"p2-99-int.md":          intWithReview,
	})
	// impl leg
	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	mustMuster(t, repo, "verify")
	mustMuster(t, repo, "done")
	// review leg: reject with a staged fix
	out := mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "strong")
	assertContains(t, out, "Claimed p2-02-review-hello")
	write(t, repo, ".muster/cards/p2-02-review-hello.notes.md", "hello is not better\n")
	write(t, repo, ".muster/staging/p2-01-fix-hello.md", stagedFixP2)
	out = mustMuster(t, repo, "done", "fail", "-reason", "hello lacks better")
	assertContains(t, out, "Review failed. Fix p2-01-fix1-hello queued (generation 1 of 2). Session over.")
	subject := strings.TrimSpace(run(t, repo, "git", "log", "-1", "--format=%s"))
	if subject != "muster(p2): reject p2-01-hello gen1" {
		t.Fatalf("subject: %s", subject)
	}
	// fix leg
	out = mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	assertContains(t, out, "Claimed p2-01-fix1-hello")
	write(t, repo, "src/hello.txt", "hello world better\n")
	mustMuster(t, repo, "verify")
	mustMuster(t, repo, "done")
	// review re-promoted: pass it this time
	out = mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "strong")
	assertContains(t, out, "Claimed p2-02-review-hello")
	write(t, repo, ".muster/cards/p2-02-review-hello.notes.md", "better confirmed\n")
	out = mustMuster(t, repo, "done", "pass")
	assertContains(t, out, "Done: p2-02-review-hello")
	show := mustMuster(t, repo, "show", "p2-02-review-hello")
	assertContains(t, show, "status: done", "verdict: fail", "verdict: pass")
}
