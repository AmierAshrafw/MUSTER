# MUSTER codex-executor mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a MUSTER orchestrator-loop skill that runs each RUN-tier task through OpenAI Codex (`gpt-5.6-luna` @ xhigh) as executor while the Claude orchestrator owns every `muster` verb, moving execution token-load onto the Codex subscription.

**Architecture:** The orchestrator runs `muster claim`/`verify`/`done` in the live checkout (real env, all integrity guards). Codex runs only file edits + a raw self-check + its notes, inside `--sandbox workspace-write`, then stops. A new read-only `muster fingerprint` verb lets the orchestrator detect any raw DB tamper by Codex across the run. Review-tier stays a Claude opus subagent by default.

**Tech Stack:** Go 1.26 (`muster` CLI, SQLite via `database/sql`), markdown skills, `codex exec` CLI.

**Spec:** `docs/superpowers/specs/2026-08-17-muster-codex-executor-design.md` (grounded + probe-validated).

---

## Plan decisions (sharp fog resolved)

- **PD1 - Fingerprint is a Go `muster fingerprint` read-only subcommand**, not a loose python helper. Rationale: MUSTER's thesis (D17) is protocol mechanics in code, and "the binary owns DB access"; a subcommand is unit-testable in the existing suite and arch-consistent. Probe 3 validated the content-digest logic; this ports it into Go. Rejected: python script poking the DB directly (faster but outside the binary, against D17/D27).
- **PD2 - Skill lives at `skills/auto-codex/SKILL.md`**, a standalone sibling of `skills/auto`. It inlines its own Close steps (as `auto` does) rather than depending on a shared include - skills are flat markdown, no include mechanism (YAGNI).
- **PD3 - Codex dispatch** = `codex exec -m gpt-5.6-luna -c model_reasoning_effort=xhigh --sandbox workspace-write "<prompt>"`, prompt as an arg via a file + `"$(cat file)"` (PS 5.1 quoting bug), the executor exports `GOCACHE`/`GOTMPDIR` at a temp-dir path in its OWN shell on each Go command line (env set on the `codex exec` parent does NOT cross into the sandbox; D26), and the prompt frames Codex as a dispatched subagent (triggers `using-superpowers`'s `<SUBAGENT-STOP>` so Codex skips its skill-preamble). All probe-confirmed.
- **PD4 - Progress signal = board re-read** (`muster board`) after `done`, not `done`'s exit code (completePass commits before post-commit checks; reconcile can bless a failed done). Routing = board counts + claim refusal message, never the bare exit code (every refusal is exit 1). Single-active-plan precondition inherited from `auto`.
- **PD5 - Crash handling = detect-and-halt only** (D12). A `doing` row at the top of a loop iteration means a crashed predecessor: STOP, report, human runs `muster redo`. No auto-reclaim.

## File structure

- Create: `internal/store/fingerprint.go` - `Store.Fingerprint()` content digest over tasks/deps/events/verdicts.
- Create: `internal/store/fingerprint_test.go` - digest stability + tamper-detection tests.
- Modify: `internal/cli/app.go:39` - add the `fingerprint` verb to `Dispatch`.
- Create: `internal/cli/fingerprint.go` - `App.Fingerprint()` prints the digest.
- Create: `internal/cli/fingerprint_test.go` - verb prints a stable non-empty digest.
- Create: `skills/auto-codex/SKILL.md` - the orchestrator loop.
- Create: `skills/auto-codex/codex-dispatch.md` - the per-task Codex prompt template + env recipe.

---

## Task 1: `muster fingerprint` store method

**Files:**
- Create: `internal/store/fingerprint.go`
- Test: `internal/store/fingerprint_test.go`

- [ ] **Step 1: Write the failing test**

```go
package store

import "testing"

func fpBoard(t *testing.T) *Store {
	t.Helper()
	s := open(t) // real store test helper (internal/store/store_test.go:8)
	// tasks.card_path and tasks.frontmatter_sha are TEXT NOT NULL with no
	// default (schema.go:14-15) - include them, or the INSERT fails setup. If
	// the tasks table has other NOT NULL columns, mirror the working seed at
	// internal/store/store_test.go:65-66.
	mustExec(t, s, `INSERT INTO tasks(id,plan,type,tier,harness,status,seq,card_path,frontmatter_sha) VALUES
		('p-01-a','p','impl','any','','inbox',1,'.muster/cards/p-01-a.md','sha-a'),
		('p-02-b','p','impl','any','codex','done',2,'.muster/cards/p-02-b.md','sha-b')`)
	return s
}

func TestFingerprint_StableOnNoOp(t *testing.T) {
	s := fpBoard(t)
	a, err := s.Fingerprint()
	if err != nil { t.Fatal(err) }
	b, err := s.Fingerprint()
	if err != nil { t.Fatal(err) }
	if a == "" || a != b {
		t.Fatalf("want stable non-empty digest, got %q then %q", a, b)
	}
}

func TestFingerprint_DetectsStatusForge(t *testing.T) {
	s := fpBoard(t)
	before, _ := s.Fingerprint()
	mustExec(t, s, `UPDATE tasks SET status='done' WHERE id='p-01-a'`)
	after, _ := s.Fingerprint()
	if before == after {
		t.Fatal("digest must change when a task status is forged to done")
	}
}

func TestFingerprint_DetectsEventInsert(t *testing.T) {
	s := fpBoard(t)
	before, _ := s.Fingerprint()
	mustExec(t, s, `INSERT INTO events(task_id,actor,verb,detail,created_at,prev_hash,hash)
		VALUES('p-01-a','codex','claim','x','2026-01-01','0','deadbeef')`)
	after, _ := s.Fingerprint()
	if before == after {
		t.Fatal("digest must change when an event is forged")
	}
}
```

Note: `open(t)` and `mustExec` are the real store test helpers (internal/store/store_test.go:8 and :85). Do not add new helpers.

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./internal/store -run TestFingerprint -v`
Expected: FAIL - `s.Fingerprint undefined`.

- [ ] **Step 3: Write the minimal implementation**

```go
package store

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
)

// Fingerprint returns a content digest of the integrity-relevant board state:
// task rows, dependency edges, the event-chain tip, and verdict count. It is
// WAL-agnostic (reads the merged view) and used by the codex-executor loop to
// detect any raw DB write by the sandboxed executor. Read-only.
func (s *Store) Fingerprint() (string, error) {
	var b strings.Builder
	rows, err := s.db.Query(`SELECT id,status,tier,COALESCE(harness,''),
		COALESCE(claimed_by,''),COALESCE(head_at_claim,'') FROM tasks ORDER BY id`)
	if err != nil {
		return "", err
	}
	for rows.Next() {
		var id, st, tier, h, cb, hac string
		if err := rows.Scan(&id, &st, &tier, &h, &cb, &hac); err != nil {
			rows.Close()
			return "", err
		}
		fmt.Fprintf(&b, "T|%s|%s|%s|%s|%s|%s\n", id, st, tier, h, cb, hac)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return "", err
	}
	dep, err := s.db.Query(`SELECT task_id,depends_on FROM deps ORDER BY task_id,depends_on`)
	if err != nil {
		return "", err
	}
	for dep.Next() {
		var a, d string
		if err := dep.Scan(&a, &d); err != nil {
			dep.Close()
			return "", err
		}
		fmt.Fprintf(&b, "D|%s|%s\n", a, d)
	}
	dep.Close()
	if err := dep.Err(); err != nil {
		return "", err
	}
	var evCount, evMax int
	var evHash string
	if err := s.db.QueryRow(`SELECT count(*),COALESCE(max(id),0),
		COALESCE((SELECT hash FROM events ORDER BY id DESC LIMIT 1),'')
		FROM events`).Scan(&evCount, &evMax, &evHash); err != nil {
		return "", err
	}
	var vdCount int
	if err := s.db.QueryRow(`SELECT count(*) FROM verdicts`).Scan(&vdCount); err != nil {
		return "", err
	}
	fmt.Fprintf(&b, "E|%d|%d|%s\nV|%d\n", evCount, evMax, evHash, vdCount)
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:]), nil
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `go test ./internal/store -run TestFingerprint -v`
Expected: PASS (all three).

- [ ] **Step 5: Commit**

```bash
git add internal/store/fingerprint.go internal/store/fingerprint_test.go
git commit -m "feat(store): content-digest Fingerprint for codex-executor tamper detection"
```

## Task 2: `muster fingerprint` verb

**Files:**
- Create: `internal/cli/fingerprint.go`
- Modify: `internal/cli/app.go:39` (Dispatch switch)
- Test: `internal/cli/fingerprint_test.go`

- [ ] **Step 1: Write the failing test**

```go
package cli

import (
	"strings"
	"testing"
)

func TestFingerprintVerb_PrintsDigest(t *testing.T) {
	a, _, out := newApp(t) // real helper returns (a, *gitx.Fake, out) (internal/cli/app_test.go:17)
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
```

`newApp(t)` returns three values `(a, *gitx.Fake, out)` and `seed` requires `typ`+`tier` (internal/cli/app_test.go:17 and :42). Do not invent helpers.

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./internal/cli -run TestFingerprintVerb -v`
Expected: FAIL - Dispatch refuses `fingerprint` (exit 1).

- [ ] **Step 3: Write the verb**

Create `internal/cli/fingerprint.go`:

```go
package cli

import "fmt"

// Fingerprint prints a content digest of board state (read-only). The
// codex-executor loop captures it before and after a Codex run to detect any
// raw DB tamper by the sandboxed executor.
func (a *App) Fingerprint() int {
	fp, err := a.St.Fingerprint()
	if err != nil {
		return a.refuse("fingerprint failed: %v", err)
	}
	fmt.Fprintln(a.Out, fp)
	return 0
}
```

Add to the `Dispatch` switch in `internal/cli/app.go` (after the `doctor` case, before `default`):

```go
	case "fingerprint":
		return a.Fingerprint()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `go test ./internal/cli -run TestFingerprintVerb -v`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `go test ./...`
Expected: PASS (no regressions).

- [ ] **Step 6: Commit**

```bash
git add internal/cli/fingerprint.go internal/cli/fingerprint_test.go internal/cli/app.go
git commit -m "feat(cli): muster fingerprint verb (read-only board digest)"
```

## Task 3: Codex dispatch template

**Files:**
- Create: `skills/auto-codex/codex-dispatch.md`

This is the per-task recipe the orchestrator fills and runs. No code test; validated end-to-end in Task 5.

- [ ] **Step 1: Write the dispatch template file**

Create `skills/auto-codex/codex-dispatch.md` with exactly this content:

````markdown
# Codex run-task dispatch (filled per task by the orchestrator)

The orchestrator has already run `muster claim -harness codex -tier any`. Do NOT
run claim, done, verify, or any `muster` verb, and do NOT run git. You are a
dispatched executor with one job.

## Invocation

Write the filled prompt below to a scratch file, then:

```bash
codex exec -m gpt-5.6-luna -c model_reasoning_effort=xhigh \
  --sandbox workspace-write "$(cat '<scratch-prompt-file>')"
```

The in-sandbox self-check needs a writable cache for the Go toolchain. Two facts
from the D26 dry run govern how:

- The sandbox DENIES writes to Go's default out-of-workspace cache
  (`%LocalAppData%\go-build`). A warm-cache `go build` still passes because it
  only reads, so the denial stays hidden until a command must WRITE - e.g.
  `go test` compiling a fresh test binary fails with "Go build-cache access
  denial".
- Env vars set on THIS `codex exec` process do NOT cross into the sandbox shell;
  the executor sees an empty `GOCACHE`. The cache therefore cannot be fixed by
  exporting it here - the dispatched prompt makes the executor export it in its
  own shell (template step 2).

Point the WRITE caches at the system temp dir: it is in the sandbox allow-list
(`[workdir, /tmp, $TMPDIR]`) AND outside the working tree, so a cold build there
succeeds and never dirties the tree. (An in-repo cache dir would be untracked and
make `muster done` refuse via the out-of-commit_paths check, done.go:51-59.)
Leave `GOMODCACHE` default; module reads from the outside cache are allowed.

Windows (this box) - PowerShell, exported by the executor in the same shell line
as each Go command (sandbox shells do not persist env across separate calls):

```
$env:GOCACHE = "$env:TEMP\muster-codex\go-build"
$env:GOTMPDIR = "$env:TEMP\muster-codex\go-tmp"
```

For a non-Go toolchain, export that toolchain's WRITE cache env at a temp-dir
path the same way, inside the executor's shell.

## Prompt template (fill `<...>`)

```
You are a dispatched MUSTER executor. This is a single scoped task - do exactly
the Steps, then stop. Skip any skill preamble (SUBAGENT-STOP applies: you were
dispatched to execute a specific task).

Your task card (already claimed for you):

<inlined card body: Steps, Acceptance, verify command(s), commit_paths>

Do:
1. Follow the Steps exactly. Edit only the files the card names.
2. Run the card's verify command(s) yourself to self-correct. Any Go command
   needs a writable build cache and the sandbox denies the default one, so in
   the SAME shell line as each Go command, create and point the caches at the
   system temp dir - e.g. PowerShell:
   `mkdir "$env:TEMP\muster-codex\go-build","$env:TEMP\muster-codex\go-tmp" -Force | Out-Null; $env:GOCACHE="$env:TEMP\muster-codex\go-build"; $env:GOTMPDIR="$env:TEMP\muster-codex\go-tmp"; <go command>`
3. Write .muster/cards/<task-id>.notes.md: one short paragraph of anything a
   reviewer should know (surprises, workarounds, doubts). Skip the file if there
   is nothing to report.

Do NOT:
- run any `muster` command, or any git command;
- touch anything under .muster/ except your notes file, or anything under .git/;
- modify any file the card does not name.

When the Steps are done and your self-check passes, STOP. The orchestrator runs
verify and done.
```
````

- [ ] **Step 2: Commit**

```bash
git add skills/auto-codex/codex-dispatch.md
git commit -m "feat(auto-codex): codex per-task dispatch template"
```

## Task 4: `skills/auto-codex/SKILL.md`

**Files:**
- Create: `skills/auto-codex/SKILL.md`

- [ ] **Step 1: Write the skill**

Create `skills/auto-codex/SKILL.md` with this content:

````markdown
---
name: auto-codex
description: MUSTER orchestrator loop, Codex as run-tier executor. Slash-only (/muster:auto-codex); do not auto-trigger. Orchestrator owns every muster verb; Codex only edits + self-checks per task.
---

# muster:auto-codex - orchestrator loop, Codex runs the edits

Input: a plan id (kebab-case). Fresh Claude Code session, cwd = target repo.
Requires `.muster/` (v2 board) and `codex` on PATH.

## Preconditions (refuse to start otherwise)

- Exactly one active plan on the board (every backlog/inbox/doing/staging task
  carries this plan id). `NextEligible` scans board-wide, so a second plan makes
  the loop drain the wrong tasks.
- `doing` empty. A non-empty `doing` is a crashed predecessor - human recovery
  (`muster redo <id>`), not this loop's job.

## Hard rules

- **Sequential only.** One task fully finishes before the next starts. One
  executor per checkout (D18); no worktree.
- **Orchestrator runs every `muster` verb** (claim, verify, done) and the
  `codex exec` subprocess. Codex runs no verb and no git.
- **Progress = board re-read**, never `done`'s exit code and never Codex's prose.
- **Review-tier is a Claude opus subagent** (default), full RUNNER, exactly like
  `skills/auto`. Codex handles run-tier only.

## Loop

1. `muster board`. Read the run / review / doing / failed / backlog / done lines.
2. `doing > 0`: STOP - crashed predecessor. Report the id; human runs
   `muster redo`. (Recovery framing is identical to `skills/auto`.)
3. `review > 0`: dispatch a Claude opus review subagent (run
   `muster claim -harness claude -tier strong`, follow `.muster/RUNNER.md`),
   foreground, wait. Then re-read the board (step 1). Do not resume a finished
   subagent.
4. Else `run > 0`: run the Codex run-task triad (below). Then re-read (step 1).
5. Else nothing claimable:
   - `failed > 0` or a DEAD backlog marker: STOP, report ids. Human recovery.
   - `backlog` clear and `done > 0`: perform Close (below). Stop.
   - Otherwise: STOP, report the board as printed (unexpected).

## Codex run-task triad (step 4 detail)

1. **Claim + fingerprint.**
   - `muster claim -harness codex -tier any`.
   - Refusal `nothing to claim for codex/any.` (the full identity string,
     claim.go:143): run tasks remain but none are codex-eligible - they are
     `harness:claude`-pinned. Dispatch a Claude
     run-mode subagent for them (`-harness claude -tier any`), as `skills/auto`
     does. Then re-read the board. (Do not treat the exit code alone as
     "nothing to do" - confirm against the board counts.)
   - Any other refusal: STOP, report verbatim.
   - On success, capture the printed card body. Run `muster fingerprint`; save
     the digest as FP_CLAIM.
2. **Dispatch Codex.** Fill `codex-dispatch.md`'s template with the card body
   and this task id, write it to a scratch file, and run the `codex exec` line
   with the temp-dir `GOCACHE`/`GOTMPDIR` env (codex-dispatch.md). Foreground;
   wait for exit. Give build/test steps a generous timeout (Codex's default
   per-command limit is ~10s).
3. **Verify + done.** After EVERY Codex dispatch (the initial one and each
   retry):
   - Confirm the `codex exec` process returned (foreground wait).
   - Run `muster fingerprint`; if it differs from FP_CLAIM, Codex wrote the DB -
     STOP and report a board-integrity breach (human recovery). Expected: equal.
     (Re-checking each retry, not just once, closes the retry-tamper gap.)
   - `muster verify`. FAIL with attempts remaining: re-dispatch Codex into the
     SAME claim (no re-claim) with the verify transcript appended, then repeat
     this fingerprint+verify block. Terminal fail (cap reached): STOP, report.
   - PASS: `muster done`.
   - Re-read `muster board`. Task moved to `done` = progress, loop. Task still
     `doing` or a `done` refusal: STOP, report the `done` output (human runs
     `redo`/`fail`).

## Close (performed directly, no subagent)

Mirror `skills/close` (v2 arm): when the board is empty except `done`, this loop
reports the closeable state and runs the plan's close. Nothing moves in v2 beyond
what `muster` does. Report the archived/closed count. Stop.

## Halt conditions (exhaustive)

- Plan closed (success).
- `doing` occupied at top of loop - crashed predecessor (human recovery).
- A `done` refusal or a task stuck `doing` after the triad (human recovery).
- Fingerprint mismatch after a Codex run - board-integrity breach (human).
- `failed` non-empty or a DEAD backlog task (human recovery).
- Unexpected board state - reported.

No other exit path. No task/turn cap.
````

- [ ] **Step 2: Validate against invariants (self-check, no code)**

Confirm the skill states: sequential-only, orchestrator-owns-verbs, board-reread progress signal, fingerprint check, single-plan + empty-doing preconditions, review=opus-subagent. All present.

- [ ] **Step 3: Commit**

```bash
git add skills/auto-codex/SKILL.md
git commit -m "feat(auto-codex): orchestrator loop skill (Codex run-tier executor)"
```

## Task 5: End-to-end validation (D26 dry run)

**Files:** none committed to the repo beyond a throwaway probe plan on a scratch branch.

Not a TDD task - a manual integration gate. Run on a scratch branch off the
current branch; delete after.

- [ ] **Step 1: Build the binary**

Run: `go build -o muster.exe ./cmd/muster`
Expected: exit 0. (The `main` package is under `./cmd/muster`; the repo root has
no Go files, so a bare `.` target fails - D26.)

- [ ] **Step 2: Author one throwaway impl card** (`probe` plan): create a scratch
  file with exact content; a network-free verify (e.g. `findstr <marker> <file>`,
  `expect_exit: 0`); `harness: codex`, `tier: any`; `commit_paths` = that file;
  `protected: []`; `depends_on: []`. Commit the card, `muster ingest <card>`.

- [ ] **Step 3: Run the triad by hand** exactly as the skill describes: claim →
  fingerprint → `codex exec` (filled template, temp-dir caches exported in the
  executor's own shell on each Go command line) → confirm process returned →
  fingerprint equal → `muster verify` → `muster done` → `muster board`.
  D26 outcome: a temp-dir `GOCACHE`/`GOTMPDIR` does build inside the sandbox - a
  cold build wrote 1037 cache files at exit 0 with no sandbox error when set
  in-shell (env on the `codex exec` parent does NOT cross in; the executor saw
  `GOCACHE=""` until it exported the caches itself).
  Expected: task reaches `done`; both fingerprints equal; git shows exactly one
  `muster(probe): done <id>` commit. All confirmed in the D26 run.

- [ ] **Step 4: Crash-recovery check.** Repeat, but kill the `codex exec` process
  mid-run. Confirm: `doing` occupied at the next `muster board`; the loop's rule
  says STOP; `muster redo <id>` returns it to inbox; a fresh triad completes it.
  D26 outcome: VALIDATED - killing Codex mid-run left the task in `doing` and the
  board DB untouched (fingerprint identical before and after the kill); `muster
  redo` + re-claim did NOT auto-file (marker absent) and handed the card back; a
  fresh dispatch completed it with one clean `muster(probe): done <id>` commit.

- [ ] **Step 5: Record the verify pass rate** toward D26 (~10 real tasks total
  before routing bulk work). Note results in the spec's "Needs testing" section
  or a dogfood log. Delete the scratch branch and probe plan.

---

## Not yet specified

- Per-toolchain write-cache env for non-Go verify blocks (npm/dotnet/pip/cargo) -
  fill when a real plan needs one (Go is confirmed).
- The retry-transcript format handed back to Codex on a verify failure (Task 5
  will surface the minimal useful shape).
- ~~Confirm a temp-dir (`%TEMP%`) `GOCACHE` builds inside Codex's sandbox.~~
  RESOLVED (D26): a temp-dir `GOCACHE`/`GOTMPDIR` exported in the executor's own
  shell builds in-sandbox (cold build, 1037 cache files, exit 0). Temp-dir chosen
  over in-repo to avoid the dirty-tree/`done`-refuse coupling (plan-review W2).

## Out of scope

- Codex-sol review tier (opt-in variant; default is Claude opus).
- Worktrees / parallel executors (D18 KIV).
- Automated new-session spawning (D31 end-state).
- Fixing pre-existing MUSTER-core issues (probe bypasses donePreconditions M5;
  cross-task sidecar contamination N1) - separate work.
- Rebuilding the reviewer.
