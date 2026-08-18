# Orchestrator Auto-Recovery — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the orchestrator halting for a human on two deterministic, non-destructive conditions — a `done` refusal caused by a repo `.gitignore` swallowing MUSTER's own artifacts, and a false board-integrity breach in the Codex loop caused by a stale fingerprint baseline.

**Architecture:** Two independent fixes. (1) `muster done` (and the terminal-fail / review-reject completion paths) force-add MUSTER-owned `.muster/cards/*` artifacts with `git add -f`, while user `commit_paths` keep plain `git add` (an ignored user file may be deliberate policy). (2) The `auto-codex` skill brackets each Codex dispatch with a fresh fingerprint captured immediately before dispatch and checked immediately after, instead of one long-lived `FP_CLAIM` that a legitimate `verify` attempt event later invalidates.

**Tech Stack:** Go (stdlib + `os/exec` git seam in `internal/gitx`), SQLite store, Go `testing` (unit tests with a `gitx.Fake`; process-tier tests behind the `process` build tag driving the real built binary), Markdown skill prose.

---

## Background the engineer needs

- The only git-write seam is `internal/gitx`. `Repo.Add` (`internal/gitx/gitx.go:117`) runs
  `git -c core.autocrlf=false add -- <paths>` — **no `-f`**, so git refuses any path an
  active `.gitignore` matches. Once a path is tracked, gitignore no longer applies to it, so
  only the **first** staging of a not-yet-tracked artifact can hit this.
- MUSTER-owned artifacts always live under `.muster/cards/`: `<id>.result.md`, `<id>.notes.md`,
  `<id>.verify.log`, generation-history variants (`<id>.gen<N>.verify.log`, `.gen<N>.notes.md`,
  `.gen<N>.result.md`), and a stamped fix card `<fixID>.md`. The tool authors all of them; they
  must always be committable regardless of the containing repo's ignore rules.
- Three code sites do a first-stage of MUSTER artifacts and must switch to force:
  `completePass` (`internal/cli/done.go:93`), `failCommitAndFile` (`internal/cli/donefail.go:37`),
  and the reject commit in `doneFailReview` (`internal/cli/donefail.go:173`). The hook
  re-stage/amend block (`done.go:103-121`) re-adds *already-committed* files, which are tracked
  and never ignored — leave it as plain `Add`.
- Unit tests build an `App` with a `gitx.Fake` via `newApp(t)` (`internal/cli/app_test.go:17`) and
  seed rows with `seed(...)`. The `Fake` records staged paths; it does **not** enforce gitignore,
  so the real ignore-defeat is proven only at the process tier.
- Process tests build the real binary once (`test/process/main_test.go:16`) and drive it via
  `mustMuster` / `muster`. `defaultBoard(t)` gives a ready board; the full completion flow is
  `claim -harness claude -tier any` → `write src/hello.txt` → `verify` → `done`
  (see `test/process/loop_test.go:23-29`). The harness neutralizes the *global* excludes file but
  a repo-local `.gitignore` still applies.
- `muster fingerprint` (`internal/store/fingerprint.go:14`) hashes task rows, dep edges, the event
  count/max/tip, and the verdict count. `muster verify` appends an `attempt` event **before every
  run** (`internal/cli/verify.go:68`), which changes the fingerprint — this is the root of the
  false-breach bug the skill fix addresses.

## File structure

- `internal/gitx/gitx.go` — add `AddForce` to the `Git` interface and `Repo`.
- `internal/gitx/fake.go` — add a `Forced [][]string` recorder and `AddForce` to `Fake`.
- `internal/gitx/gitx_test.go` — extend the Fake test to cover `AddForce` recording.
- `internal/cli/done.go` — split staging in `completePass`.
- `internal/cli/donefail.go` — force MUSTER artifacts in `failCommitAndFile` and the reject commit.
- `internal/cli/done_force_test.go` *(new)* — unit tests asserting the force/plain routing.
- `test/process/gitignore_test.go` *(new)* — end-to-end regression: an ignored MUSTER `verify.log` still commits (force), and an ignored user `commit_path` is still refused (plain).
- `skills/auto-codex/SKILL.md` — fingerprint tight-bracket rewrite (item 2).

---

## Task 1: `AddForce` seam in gitx

**Files:**
- Modify: `internal/gitx/gitx.go:11-26` (interface), `internal/gitx/gitx.go:117-120` (Repo)
- Modify: `internal/gitx/fake.go:11-28` (struct), `internal/gitx/fake.go:46-49` (methods)
- Test: `internal/gitx/gitx_test.go`

- [ ] **Step 1: Write the failing test** — append to `internal/gitx/gitx_test.go`:

```go
func TestFakeAddForceRecords(t *testing.T) {
	f := &Fake{}
	if err := f.Add([]string{"src/app.go"}); err != nil {
		t.Fatal(err)
	}
	if err := f.AddForce([]string{".muster/cards/x.verify.log"}); err != nil {
		t.Fatal(err)
	}
	if len(f.Added) != 1 || f.Added[0][0] != "src/app.go" {
		t.Fatalf("plain Add not recorded: %v", f.Added)
	}
	if len(f.Forced) != 1 || f.Forced[0][0] != ".muster/cards/x.verify.log" {
		t.Fatalf("AddForce not recorded separately: %v", f.Forced)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/gitx/ -run TestFakeAddForceRecords -v`
Expected: FAIL to **compile** — `f.AddForce undefined` and `f.Forced undefined`.

- [ ] **Step 3: Add `AddForce` to the interface** — in `internal/gitx/gitx.go`, inside `type Git interface`, immediately after the `Add(paths []string) error` line (`:21`):

```go
	Add(paths []string) error
	AddForce(paths []string) error // -f: for MUSTER-owned artifacts the repo .gitignore may match
```

- [ ] **Step 4: Add `AddForce` to `Repo`** — in `internal/gitx/gitx.go`, immediately after the `Add` method (after `:120`):

```go
func (r *Repo) AddForce(paths []string) error {
	_, err := r.git(append([]string{"-c", "core.autocrlf=false", "add", "-f", "--"}, paths...)...)
	return err
}
```

- [ ] **Step 5: Add the recorder + method to `Fake`** — in `internal/gitx/fake.go`, add a field to the `Fake` struct next to `Added [][]string` (`:20`):

```go
	Added   [][]string
	Forced  [][]string
```

Then add the method after the existing `Add` method (after `:49`):

```go
func (f *Fake) AddForce(paths []string) error {
	f.Forced = append(f.Forced, paths)
	return nil
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `go test ./internal/gitx/ -run 'TestFakeAddForceRecords|TestFakeImplementsGit' -v`
Expected: PASS (both — `TestFakeImplementsGit` proves `Fake` still satisfies `Git`).

- [ ] **Step 7: Commit**

```bash
git add internal/gitx/gitx.go internal/gitx/fake.go internal/gitx/gitx_test.go
git commit -m "feat(gitx): AddForce seam for MUSTER-owned artifacts"
```

---

## Task 2: `completePass` splits force vs plain staging

**Files:**
- Modify: `internal/cli/done.go:82-95`
- Test: `internal/cli/done_force_test.go` (new)

- [ ] **Step 1: Write the failing test** — create `internal/cli/done_force_test.go`:

```go
package cli

import (
	"os"
	"path/filepath"
	"testing"

	"muster/internal/card"
	"muster/internal/store"
)

// writeArtifact drops a file under the repo root so fileExistsAt sees it.
func writeArtifact(t *testing.T, a *App, rel string) {
	t.Helper()
	p := filepath.Join(a.Root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestCompletePassForcesMusterArtifactsOnly(t *testing.T) {
	a, fake, _ := newApp(t)
	seed(t, a, "p-01-x", "impl", "any", "doing")
	tk, err := a.St.Task("p-01-x")
	if err != nil || tk == nil {
		t.Fatalf("seed task missing: %v", err)
	}
	// the task's own live sidecars + one user commit_path
	writeArtifact(t, a, ".muster/cards/p-01-x.notes.md")
	writeArtifact(t, a, ".muster/cards/p-01-x.verify.log")
	writeArtifact(t, a, "src/hello.txt")
	c := &card.Card{ID: "p-01-x", Plan: "p", Type: "impl", CommitPaths: []string{"src/hello.txt"}}

	if code := a.completePass(tk, c, passOpts{DoneCheckPass: true}); code != 0 {
		t.Fatalf("completePass exited %d", code)
	}

	// MUSTER artifacts (result.md written by completePass, plus notes + verify.log) go through AddForce
	forced := flat(fake.Forced)
	for _, want := range []string{".muster/cards/p-01-x.result.md", ".muster/cards/p-01-x.notes.md", ".muster/cards/p-01-x.verify.log"} {
		if !contains(forced, want) {
			t.Fatalf("expected %s force-added; forced=%v", want, forced)
		}
	}
	// user commit_paths must NOT be force-added
	if contains(forced, "src/hello.txt") {
		t.Fatalf("user commit_path must not be force-added; forced=%v", forced)
	}
	if !contains(flat(fake.Added), "src/hello.txt") {
		t.Fatalf("user commit_path must be plain-added; added=%v", fake.Added)
	}
	// the completion commit must carry every path
	if len(fake.Commits) != 1 {
		t.Fatalf("expected one completion commit, got %d", len(fake.Commits))
	}
	for _, want := range []string{".muster/cards/p-01-x.result.md", "src/hello.txt"} {
		if !contains(fake.Commits[0].Paths, want) {
			t.Fatalf("commit missing %s; paths=%v", want, fake.Commits[0].Paths)
		}
	}
	_ = store.Task{}
}

func flat(xs [][]string) []string {
	var out []string
	for _, x := range xs {
		out = append(out, x...)
	}
	return out
}

func contains(xs []string, want string) bool {
	for _, x := range xs {
		if x == want {
			return true
		}
	}
	return false
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/cli/ -run TestCompletePassForcesMusterArtifactsOnly -v`
Expected: FAIL — current code force-adds nothing (`fake.Forced` is empty; everything goes through plain `Add`), so the first assertion to fire is that `.muster/cards/p-01-x.result.md` is missing from `forced`.

- [ ] **Step 3: Split the staging in `completePass`** — in `internal/cli/done.go`, replace the block at `:82-95`:

```go
	paths := []string{rel}
	for _, side := range []string{t.ID + ".notes.md", t.ID + ".verify.log"} {
		if p := ".muster/cards/" + side; fileExistsAt(a.Root, p) {
			paths = append(paths, p)
		}
	}
	for _, cp := range c.CommitPaths {
		if fileExistsAt(a.Root, cp) {
			paths = append(paths, cp)
		}
	}
	if err := a.G.Add(paths); err != nil {
		return a.refuse("git add failed: %v", err)
	}
```

with:

```go
	// MUSTER-owned artifacts: force-add so a containing repo's .gitignore can
	// never make a mandatory sidecar uncommittable. User commit_paths keep plain
	// add - an ignored user path may be deliberate repo policy (do not override).
	musterPaths := []string{rel}
	for _, side := range []string{t.ID + ".notes.md", t.ID + ".verify.log"} {
		if p := ".muster/cards/" + side; fileExistsAt(a.Root, p) {
			musterPaths = append(musterPaths, p)
		}
	}
	var userPaths []string
	for _, cp := range c.CommitPaths {
		if fileExistsAt(a.Root, cp) {
			userPaths = append(userPaths, cp)
		}
	}
	if err := a.G.AddForce(musterPaths); err != nil {
		return a.refuse("git add failed: %v", err)
	}
	if len(userPaths) > 0 {
		if err := a.G.Add(userPaths); err != nil {
			return a.refuse("git add failed: %v", err)
		}
	}
	paths := append(append([]string{}, musterPaths...), userPaths...)
```

(The following `a.crashPoint("before-commit")`, `a.G.Commit(msg, paths)`, and the hook re-stage/amend block are unchanged — they keep using `paths`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/cli/ -run TestCompletePassForcesMusterArtifactsOnly -v`
Expected: PASS

- [ ] **Step 5: Run the full cli + gitx suites to catch regressions**

Run: `go test ./internal/cli/ ./internal/gitx/`
Expected: PASS (ok for both packages)

- [ ] **Step 6: Commit**

```bash
git add internal/cli/done.go internal/cli/done_force_test.go
git commit -m "fix(done): force-add MUSTER-owned artifacts, plain-add user commit_paths"
```

---

## Task 3: force MUSTER artifacts in the fail + reject paths

**Files:**
- Modify: `internal/cli/donefail.go:37` (`failCommitAndFile`), `internal/cli/donefail.go:173` (reject commit)
- Test: `internal/cli/done_force_test.go` (extend)

- [ ] **Step 1: Write the failing test** — append to `internal/cli/done_force_test.go`:

```go
func TestFailCommitForcesMusterArtifacts(t *testing.T) {
	a, fake, _ := newApp(t)
	seed(t, a, "p-02-y", "integration", "strong", "doing")
	tk, _ := a.St.Task("p-02-y")
	writeArtifact(t, a, ".muster/cards/p-02-y.notes.md")
	writeArtifact(t, a, ".muster/cards/p-02-y.verify.log")
	c := &card.Card{ID: "p-02-y", Plan: "p", Type: "integration"}

	if code := a.failCommitAndFile(tk, c, "drift", true); code != -1 {
		t.Fatalf("failCommitAndFile returned %d, want -1", code)
	}
	forced := flat(fake.Forced)
	for _, want := range []string{".muster/cards/p-02-y.result.md", ".muster/cards/p-02-y.notes.md", ".muster/cards/p-02-y.verify.log"} {
		if !contains(forced, want) {
			t.Fatalf("fail path must force %s; forced=%v", want, forced)
		}
	}
	if len(flat(fake.Added)) != 0 {
		t.Fatalf("fail path stages only MUSTER artifacts; plain Add should be empty, got %v", fake.Added)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/cli/ -run TestFailCommitForcesMusterArtifacts -v`
Expected: FAIL — the artifacts land in `fake.Added` (plain), so the `Forced` assertions fail.

- [ ] **Step 3: Force in `failCommitAndFile`** — in `internal/cli/donefail.go:37`, change:

```go
	if err := a.G.Add(paths); err != nil {
		return a.refuse("git add failed: %v", err)
	}
```

to (all `paths` here are MUSTER-owned sidecars):

```go
	if err := a.G.AddForce(paths); err != nil {
		return a.refuse("git add failed: %v", err)
	}
```

- [ ] **Step 4: Force in the reject commit** — in `internal/cli/donefail.go:173` (inside `doneFailReview`, where `paths` holds `fixRel`, `genResultRel`, and the gen-suffixed log/notes — all under `.muster/cards/`), change the same two lines:

```go
	if err := a.G.Add(paths); err != nil {
		return a.refuse("git add failed: %v", err)
	}
```

to:

```go
	if err := a.G.AddForce(paths); err != nil {
		return a.refuse("git add failed: %v", err)
	}
```

- [ ] **Step 5: Run the fail-path test + full cli suite**

Run: `go test ./internal/cli/ -run TestFailCommitForcesMusterArtifacts -v && go test ./internal/cli/`
Expected: PASS, then `ok muster/internal/cli`

- [ ] **Step 6: Commit**

```bash
git add internal/cli/donefail.go internal/cli/done_force_test.go
git commit -m "fix(donefail): force-add MUSTER artifacts on terminal-fail and reject commits"
```

> **Coverage note (accepted gap):** the reject-commit change at `internal/cli/donefail.go:173`
> (fix card + gen-history artifacts) is left untested directly. Reaching `doneFailReview` needs a
> full harness (a valid staged fix card in `.muster/staging/`, lint-lite pass, generation cap
> state) that is disproportionate for a one-line `Add`→`AddForce` change **mechanically identical**
> to the `failCommitAndFile` change proven by `TestFailCommitForcesMusterArtifacts` in this task.
> If a regression here is a concern later, add a `doneFailReview` reject-path unit test; for Phase 1
> the sibling test + code review cover it.

---

## Task 4: process regression — `.gitignore *.log` no longer stalls `done`

**Files:**
- Test: `test/process/gitignore_test.go` (new)

- [ ] **Step 1: Write the failing test** — create `test/process/gitignore_test.go`:

```go
//go:build process

package process

import (
	"strings"
	"testing"
)

// A containing repo that ignores *.log must not stall `done`: MUSTER's own
// verify.log is force-added, so the completion commit still lands.
func TestDoneCommitsIgnoredVerifyLog(t *testing.T) {
	skipOffWindows(t) // the fixture verify uses findstr (Windows-only)
	repo := defaultBoard(t)
	// the blanket rule that swallowed .muster/cards/*.verify.log in the field.
	// Commit it BEFORE claim: an untracked .gitignore would itself trip
	// donePreconditions' "changed outside commit_paths" guard (it is not matched
	// by *.log), which is not the behavior under test. The real incident's ignore
	// file is a tracked repo file too.
	write(t, repo, ".gitignore", "*.log\n")
	gitCommit(t, repo, "ignore logs", ".gitignore")

	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	out := mustMuster(t, repo, "verify")
	assertContains(t, out, "VERIFY PASS (attempt 1)")

	out = mustMuster(t, repo, "done")
	assertContains(t, out, "Done: p2-01-hello", "Session over.")

	// the verify.log is actually committed despite the ignore rule
	ls := run(t, repo, "git", "ls-files", ".muster/cards/p2-01-hello.verify.log")
	if strings.TrimSpace(ls) == "" {
		t.Fatalf("verify.log must be tracked after done; git ls-files empty")
	}
}

// The mirror invariant: a USER commit_path the repo ignores is NOT force-added -
// `done` refuses, preserving the user's deliberate ignore intent (spec item 1).
func TestDoneRefusesIgnoredCommitPath(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	// ignore the task's own commit_path (src/hello.txt). The file still exists on
	// disk so verify's findstr passes; only the plain `git add` at completion fails.
	write(t, repo, ".gitignore", "src/hello.txt\n")
	gitCommit(t, repo, "ignore hello", ".gitignore")

	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	out := mustMuster(t, repo, "verify")
	assertContains(t, out, "VERIFY PASS (attempt 1)")

	out, code := muster(t, repo, nil, "done")
	if code == 0 {
		t.Fatalf("done must refuse an ignored user commit_path (user intent preserved), got exit 0:\n%s", out)
	}
	assertContains(t, out, "git add failed")
}
```

- [ ] **Step 2: Understand this is a regression guard, not a reproducible TDD red**

> `go test -tags process` rebuilds the binary from current source (`main_test.go` builds in `TestMain`), so once Tasks 1-3 land there is no way to witness the red state in the normal flow — this test is a **post-fix regression guard**, not a genuine failing-first TDD step. To confirm it *would* have caught the bug, temporarily revert `done.go`'s `AddForce(musterPaths)` back to `Add(musterPaths)`, run the command below (Expected: FAIL — `done` exits non-zero with `git add failed: ... paths are ignored by one of your .gitignore files: .muster/cards/p2-01-hello.verify.log`), then restore `AddForce`.

Run: `go test -tags process ./test/process/ -run TestDoneCommitsIgnoredVerifyLog -v`
Expected on the fixed tree: PASS.

- [ ] **Step 3: No new implementation** — Tasks 1-3 already implement the fix. This task only adds the guard test.

- [ ] **Step 4: Run test to verify it passes on the fixed tree**

Run: `go test -tags process ./test/process/ -run 'TestDoneCommitsIgnoredVerifyLog|TestDoneRefusesIgnoredCommitPath' -v`
Expected: PASS (both — the ignored MUSTER artifact commits; the ignored user commit_path is refused).

- [ ] **Step 5: Run the whole process suite (no regressions)**

Run: `go test -tags process ./test/process/`
Expected: `ok muster/test/process`

- [ ] **Step 6: Commit**

```bash
git add test/process/gitignore_test.go
git commit -m "test(process): done commits an ignored verify.log (gitignore regression)"
```

---

## Task 5: fingerprint tight-bracket in the `auto-codex` skill (item 2)

**Files:**
- Modify: `skills/auto-codex/SKILL.md:44-70` (the Codex run-task triad)

This is skill prose, not Go — there is no unit test; correctness is by review against the
sequence. The defect: `FP_CLAIM` is captured once at claim and re-checked each retry, but
`muster verify` legitimately appends an `attempt` event that changes the fingerprint, so the
second dispatch's check trips a false breach. The fix brackets each dispatch: capture the
baseline immediately before dispatch, check immediately after Codex returns (before `verify`),
compare against that bracket's baseline.

- [ ] **Step 1: Rewrite triad step 1 (claim only — drop the claim-time fingerprint)** — in `skills/auto-codex/SKILL.md`, replace the two lines at `:55-56`:

```
   - On success, capture the printed card body. Run `muster fingerprint`; save
     the digest as FP_CLAIM.
```

with:

```
   - On success, capture the printed card body. (No fingerprint here - the guard
     brackets each Codex dispatch instead, so a legitimate `verify` attempt event
     between dispatches can never look like tampering.)
```

- [ ] **Step 2: Rewrite triad step 2 (capture the pre-dispatch baseline)** — replace the block at `:57-61`:

```
2. **Dispatch Codex.** Fill `codex-dispatch.md`'s template with the card body
   and this task id, write it to a scratch file, and run the `codex exec` line
   with the temp-dir `GOCACHE`/`GOTMPDIR` env (codex-dispatch.md). Foreground;
   wait for exit. Give build/test steps a generous timeout (Codex's default
   per-command limit is ~10s).
```

with:

```
2. **Dispatch Codex (bracketed).** Immediately before dispatch, run
   `muster fingerprint` and save the digest as FP_BEFORE - this opens the
   integrity bracket. Fill `codex-dispatch.md`'s template with the card body and
   this task id, write it to a scratch file, and run the `codex exec` line with
   the temp-dir `GOCACHE`/`GOTMPDIR` env (codex-dispatch.md). Foreground; wait for
   exit. Give build/test steps a generous timeout (Codex's default per-command
   limit is ~10s). Capture FP_BEFORE fresh for EVERY dispatch (initial and each
   retry), never reuse a prior one.
```

- [ ] **Step 3: Rewrite triad step 3 (close the bracket, then verify)** — replace the block at `:62-70`:

```
3. **Verify + done.** After EVERY Codex dispatch (the initial one and each
   retry):
   - Confirm the `codex exec` process returned (foreground wait).
   - Run `muster fingerprint`; if it differs from FP_CLAIM, Codex wrote the DB -
     STOP and report a board-integrity breach (human recovery). Expected: equal.
     (Re-checking each retry, not just once, closes the retry-tamper gap.)
   - `muster verify`. FAIL with attempts remaining: re-dispatch Codex into the
     SAME claim (no re-claim) with the verify transcript appended, then repeat
     this fingerprint+verify block. Terminal fail (cap reached): STOP, report.
```

with:

```
3. **Close the bracket, then verify + done.** After EVERY Codex dispatch (the
   initial one and each retry):
   - Confirm the `codex exec` process returned (foreground wait), AND that no
     Codex child process survives it. The bracket only holds if the Codex process
     tree is dead here - a lingering grandchild could write the DB after the check.
     If you cannot guarantee the tree is dead, treat any post-check difference as a
     breach rather than re-baselining over it.
   - Run `muster fingerprint` and compare to FP_BEFORE (this bracket's baseline,
     NOT a claim-time value). Differs -> Codex wrote the DB during its own window:
     STOP and report a board-integrity breach (human recovery). Expected: equal.
   - Only now run `muster verify` (its attempt event lands OUTSIDE every bracket,
     so it never trips the guard). FAIL with attempts remaining: re-dispatch Codex
     into the SAME claim (no re-claim) with the verify transcript appended, opening
     a FRESH bracket (new FP_BEFORE) per step 2. Terminal fail (cap reached): STOP,
     report.
```

- [ ] **Step 4: Grep-verify no stale `FP_CLAIM` reference remains**

Run: `grep -n "FP_CLAIM" skills/auto-codex/SKILL.md`
Expected: no output (all references replaced by FP_BEFORE / removed).

- [ ] **Step 5: Commit**

```bash
git add skills/auto-codex/SKILL.md
git commit -m "fix(auto-codex): bracket the fingerprint per dispatch to kill false breach"
```

---

## Task 6: rebuild + install the binary, and land the spec

**Files:** none (build + docs)

- [ ] **Step 1: Full test sweep**

Run: `go test ./... && go test -tags process ./test/process/`
Expected: all `ok`.

- [ ] **Step 2: Rebuild the binary (bootstrap — the installed binary is what runs `done`)**

Run: `go build -o muster.exe ./cmd/muster`
Expected: no output, `muster.exe` rebuilt. Install/copy it wherever the working `muster` on PATH resolves, so future `muster done` calls use the fixed staging. (Item 1 is inert until this happens; item 2 is skill prose and needs no rebuild.)

- [ ] **Step 3: Commit the design spec alongside the code**

```bash
git add docs/superpowers/specs/2026-08-18-orchestrator-auto-recovery-phase1-design.md docs/superpowers/plans/2026-08-18-orchestrator-auto-recovery-phase1.md
git commit -m "docs(specs): Phase 1 orchestrator auto-recovery design + plan"
```

---

## Deferred to Phase 2 (do NOT build here — named prerequisites in the spec)

- Auto-invoked healer before the `doing` halt — needs an exclusive-ownership lease + a hardened,
  evidence-checked `reconcile` (ancestry, commit-content, single-`doing`, fail-closed).
- Spawn-failure → `install-required` — needs a pre-burn `LookPath` preflight, a stable exit
  signal, and RUNNER-template + installed-board migration.

## Self-review notes

- **Spec coverage:** item 1 → Tasks 1-4; item 2 → Task 5; delivery/binary-bootstrap → Task 6;
  deferred items explicitly not built. All spec sections map to a task. Spec testing-intent (b)
  "gitignored commit_paths refused" → `TestDoneRefusesIgnoredCommitPath` (Task 4). Spec
  testing-intent (a) reject-path + gen-history force → **accepted coverage gap** (Task 3 note):
  a one-line change identical to the tested `failCommitAndFile`; full `doneFailReview` harness
  disproportionate for Phase 1.
- **Type consistency:** `AddForce(paths []string) error` is identical across the interface
  (`gitx.go`), `Repo` (`gitx.go`), and `Fake` (`fake.go`); `Fake.Forced [][]string` mirrors
  `Fake.Added`. Test helpers `flat`/`contains`/`writeArtifact` are defined once in
  `done_force_test.go` and reused by Task 3's added test.
- **No placeholders:** every code and prose step shows the exact content.
```
