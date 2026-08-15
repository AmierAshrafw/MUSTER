# MUSTER v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.
> **This plan will actually be executed via `/muster:shard` on the v1 board (dogfood).**
> See "Sharding notes" below before sharding.

**Goal:** Build MUSTER v2: a single static Go binary (`muster.exe`) backed by SQLite
(`.muster/muster.db`) that replaces the v1 PowerShell/sh script pair, keeping git as the
audit log (one commit per task at done) and moving all hot-path state out of git.

**Architecture:** `.muster/` is v2's own root in a target repo: immutable card files +
sidecars in `.muster/cards/` (git-tracked), all mutable state in a WAL-mode SQLite file
(gitignored). The B-prime split: the card file owns what a task IS, the DB owns what
HAPPENED. Hot path (claim/verify/promote) does zero git writes; `done` performs the one
commit per task, commit-first, with `status=done` derived (a claim-time reconciler heals
a crash between commit and DB flip). The Go module lives at this repo's root; verbs are
thin CLI wrappers over four internal packages (card, store, gitx, verify).

**Tech Stack:** Go >= 1.24, modernc.org/sqlite (pure Go, no CGO), go:embed for init
templates, `go test` unit tier on temp SQLite files (no git, no subprocess except the
verify runner's own trivial spawns), small process tier driving the real `muster.exe`
against temp git fixtures.

---

## Authority

`docs/superpowers/specs/2026-08-15-muster-v2-design.md` (below: "spec") is the settled
contract. On any conflict between this plan and the spec, **the spec wins**. The v1
sources under `tasks/bin/` and the checklists `tests/ContractMatrix.psd1` +
`tests/BlackBoxInventory.psd1` are the behavior reference for everything the spec says
survives "unchanged" or "near-verbatim"; Appendix A maps every contract-matrix row to
its v2 disposition.

Judged calls this plan makes where the spec is silent or underdetermined:

1. **Claim's stale-staging guard is the doing-occupied DB check.** Spec D-v2-5 says
   claim refuses while a staged fix is pending via "DB check, not folder scan". The DB
   cannot know about a hand-authored file in `.muster/staging/`, so the honest DB check
   is: a crashed review session leaves its review task in `status=doing`, and claim
   refuses on any doing row. An orphaned staging file with an empty doing set is caught
   by `done fail`'s exactly-one check and listed by `muster doctor`, not by claim.
2. **Hook policy is behavior, not configuration.** Init detects and prints active git
   hooks; `done` always runs one re-stage + amend cycle when a hook mutates the tree
   during the completion commit, then refuses if the tree is still dirty. No stored
   policy knob (nothing would read it).
3. **Verify-runner unit tests spawn trivial child processes** (`cmd /c exit 0` class).
   The spec's "zero subprocess" unit-tier rule is relaxed for the one component whose
   job is spawning processes. Still zero git and zero `muster.exe` in the unit tier.
4. **Only Task 1 needs the network** (`go mod download` for modernc.org/sqlite); it is
   pinned `harness: claude` at shard time. Every later verify block compiles from the
   warm local module cache, network-free.
5. **`muster` has no `close` verb, and the close skill's v2 arm is report-only.** v1's
   archive ritual existed because `done/` was claim-scan surface and dependency lookup
   walked folders; v2 resolves deps in the DB and scans no folders, so nothing needs to
   move. Cards are permanent history in `.muster/cards/`.
6. **`reviews` and `fixes` are DB columns** beyond the spec's minimum schema. Generation
   counting (`done fail` cap) and review re-blocking need the relations queryable.
7. **`done fail` (review) is crash-resumable.** The reject path is also commit-first; if
   the reject commit lands but the process dies before the DB flip, rerunning
   `muster done fail` detects the committed-but-unrecorded fix card and completes the DB
   half instead of refusing. Same derive-from-git philosophy as the done reconciler.
8. **Attempt counter = event rows, burned before any command runs** (replaces v1's
   marker commits, keeping D28's kill-safety: killing verify mid-run still counts).
9. **Generation and claimed_at never appear in frontmatter.** The v2 parser rejects
   unknown frontmatter keys outright; `generation` is a DB column stamped at fix ingest,
   `claimed_at` is a DB column stamped at claim.
10. **Wrapper skills root-sense instead of hard-repointing.** During the dogfood build,
    this repo's v1 board executes this very plan; a hard repoint would break in-flight
    dispatch. Each wrapper picks v2 when `.muster/` exists at the repo root, else v1.
    This repo gains `.muster/` only at post-close cutover, so dogfood is unaffected.
11. **Cutover is not a board task.** `muster init` refuses on a live v1 tree, and the
    v1 board is live for exactly as long as this plan is executing on it. Cutover is a
    short human checklist (Appendix B) run after `/muster:close` archives this plan.
    The dogfood gate (spec section 9.3: v2 shards and runs a plan before v1 dies) is
    satisfied in the process tier: a full ingest-claim-verify-done loop against a real
    temp git repo using the real binary (Task 26), plus the checklist's first step.
12. **Tier pinning collapses to equality.** v1's two rules (strong tasks need a strong
    session; strong sessions take only strong tasks) are, with exactly two tiers,
    equivalent to `task.tier == session.tier`. The claim query uses equality.

## Preconditions (human, before dispatch)

- Install Go >= 1.24 and confirm `go version` works in a fresh shell
  (`winget install GoLang.Go`, then reopen the terminal). Not installed at plan time.
- git >= 2.40 on PATH (present: 2.54).
- Recommended (spec D-v2-4): add a Windows Defender exclusion for this repo clone;
  measured done-commit latency is Defender-dominated.

## File structure

```
go.mod                                module muster
go.sum
cmd/muster/main.go                    verb dispatch, exit-code mapping
internal/card/card.go                 strict frontmatter parser + per-type schema
internal/card/card_test.go
internal/card/lint.go                 shard-lint (full/lite/single modes)
internal/card/lint_test.go
internal/store/store.go               Open/Close/migrations/pragmas
internal/store/driver.go              blank import of modernc.org/sqlite
internal/store/schema.go              DDL (migration 1)
internal/store/events.go              hash-chained append-only events
internal/store/tasks.go               ingest insert, queries, status flips
internal/store/claim.go               atomic claim transaction
internal/store/board.go               promote, board counts, dead-blocked
internal/store/*_test.go
internal/gitx/gitx.go                 Git interface + real exec implementation
internal/gitx/fake.go                 in-memory fake for cli unit tests
internal/verify/verify.go             tokenizer, runner, transcript writer
internal/verify/verify_test.go
internal/cli/app.go                   App wiring, refusals, board rendering
internal/cli/ingest.go                muster ingest
internal/cli/claim.go                 muster claim (+ reconciler + probe)
internal/cli/verify.go                muster verify
internal/cli/result.go                result-sidecar assembly + backup
internal/cli/done.go                  muster done (pass path)
internal/cli/donefail.go              muster done fail (review + integration)
internal/cli/human.go                 muster redo / fail / reimport
internal/cli/board.go                 muster board / show
internal/cli/doctor.go                muster doctor
internal/cli/initcmd.go               muster init (+ v1 decommission)
internal/cli/templates/RUNNER.md      embedded: executor contract v2
internal/cli/templates/muster.gitignore
internal/cli/templates/muster.gitattributes
internal/cli/*_test.go                unit tier: temp db + fake git, no subprocess
test/process/process_test.go          process tier (build tag "process")
test/process/v1fixture.go             frozen synthetic v1 board builder
skills/{run,review,shard,init,close,auto}/SKILL.md   root-sensing repoint (edit)
docs/v2-cutover.md                    cutover checklist (Appendix B, as a file)
```

## Conventions (all tasks)

- **Module:** `module muster`, `go 1.24` directive. Import paths `muster/internal/...`.
- **Formatting/vetting:** intermediate tasks verify with `go build`, `go vet`, and
  `go test` of the touched package; Task 27 (final sweep) runs the whole suite plus a
  gofmt cleanliness check. Write gofmt-clean code throughout (tabs, standard import
  grouping); do not rely on the sweep to fix style.
- **Time:** all timestamps ISO-8601 UTC `2006-01-02T15:04:05Z`. CLI code takes
  `Now func() time.Time` for testability; store methods take pre-formatted strings.
- **Exit codes (kept from v1):** 0 success/pass, 1 refusal, 2 verify attempt failed
  (retry allowed), 3 terminal. Refusals are ONE line starting `MUSTER refuse: `.
- **Files the binary writes:** UTF-8, no BOM, LF line endings (Go writes verbatim -
  templates and generated text use `\n` only).
- **Commits by the binary:** always explicit pathspec (`git commit -m <msg> -- <paths>`),
  always `-c core.autocrlf=false`, never `git add -A`, never bare commit. New files need
  `git add <path>` first.
- **Commit message grammar (kept):** `muster(<plan>): done <id>`,
  `muster(<plan>): fail <id>`, `muster(<plan>): reject <implId> gen<g>`,
  `muster: init`. No claim/attempt/promote commits exist in v2.
- **DB:** WAL, synchronous=FULL, busy_timeout=5000ms, foreign_keys=ON. Every
  multi-statement write is one transaction. `BEGIN IMMEDIATE` for the claim tx.
- **Statuses:** `backlog | inbox | doing | done | failed` (DB CHECK constraint).
- **Actors (events.actor):** `shard` (ingest), `<harness>/<tier>` (claim/verify/done),
  `human` (redo/fail/reimport), `system` (promote/reconcile/warn).
- **Tests:** unit tier = `go test ./internal/...` - temp dir + temp SQLite FILE per
  test (real WAL), `gitx.Fake` for git, zero subprocess (exception: verify runner).
  Process tier = `go test -tags process ./test/process` - real binary, real git.
- **Test commits:** conventional-commit subject, no co-author trailer. One commit per
  task minimum (more per plan steps).
- **No em dash** in any authored file; plain hyphen.

## Sharding notes (for /muster:shard - read before sharding)

1. **Plan id:** `v2build`. Cards `v2build-NN-<slug>.md`. Snapshot to
   `tasks/plan-v2build.md` (v1 board - this plan runs on v1).
2. **Size cap vs code volume.** Cards cap at 300 lines / 16 KB; several tasks below
   carry more code than fits one card. Split such a task into 2-3 sequential cards at
   step boundaries (tests card, then implementation card(s)), chained with
   `depends_on`. Intermediate cards verify with `go build` / `go vet` only (code
   compiles; tests may still be red); the LAST card of the task runs the package tests
   green. Never split a single function across cards.
3. **Lint check 5 vs Go package paths.** v1 lint requires every `/`-containing verify
   token to appear in `protected` or `commit_paths`. Go invocations like
   `go test ./internal/store` therefore need the literal token (e.g.
   `./internal/store`) added as an extra `commit_paths` entry. Dead entries are
   harmless: done stages only paths that exist, and the scope whitelist ignores
   entries nothing matches. Example card frontmatter:
   ```
   commit_paths:
     - internal/store/claim.go
     - internal/store/claim_test.go
     - ./internal/store
   ```
4. **Lint check 14 (test runner needs protected).** `go test` is on the runner list;
   every card whose verify runs it must protect its test files. Self-authored test
   files are dual-listed: `protected` AND `commit_paths` (D30).
5. **Timeouts.** First compilation of modernc.org/sqlite is slow. Give every
   `go build`/`go test` verify entry `timeout_seconds: 600`.
6. **Task 1 card is `harness: claude`** (network for `go mod download`). All other
   cards are network-free.
7. **Do not shard Appendix B** (cutover checklist) into a card - it is a human
   checklist that runs only after this plan closes (Authority note 11).
8. **Review tasks:** add review cards (tier strong) for the riskiest tasks - suggested:
   Task 6 (claim transaction), Task 17 (done pass path), Task 18 (done fail review),
   Task 26 (process tier). Downstream tasks then depend on the REVIEW id (D19).
9. **Verify content checks:** where a step below says "Expected: PASS", the card's
   verify entry uses `expect_exit: 0` plus an `expect_contains` on `ok` (go test
   prints `ok  	muster/internal/<pkg>`) - `expect_contains: "ok"` is sufficient.

---
### Task 1: Go module scaffold + verb dispatch skeleton

**Files:**
- Create: `go.mod`, `go.sum` (via `go get`)
- Create: `cmd/muster/main.go`
- Create: `internal/store/driver.go`

The only network-touching task (Authority note 4). Shard pins its card
`harness: claude`.

- [ ] **Step 1: Initialize the module and pin the driver**

```bash
go mod init muster
go get modernc.org/sqlite@latest
go mod download
```

`go.mod` must read `go 1.24` (edit the directive down if `go mod init` wrote a higher
patch version; `go mod edit -go=1.24`).

- [ ] **Step 2: Write the driver anchor**

`internal/store/driver.go`:

```go
// Package store owns all SQLite state: schema, migrations, and every board
// transaction. The blank import registers the pure-Go driver under name "sqlite".
package store

import _ "modernc.org/sqlite"
```

- [ ] **Step 3: Write the dispatch skeleton**

`cmd/muster/main.go`:

```go
// muster is the MUSTER v2 board CLI: a single static binary owning every board
// state transition. Verbs are implemented in internal/cli; this file only maps
// argv to a verb and the verb's return value to a process exit code.
package main

import (
	"fmt"
	"os"
)

var verbs = []string{
	"init", "ingest", "claim", "verify", "done", "promote",
	"board", "show", "redo", "fail", "reimport", "doctor",
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}
	verb := os.Args[1]
	for _, v := range verbs {
		if verb == v {
			fmt.Printf("MUSTER refuse: verb %q is not implemented yet.\n", verb)
			os.Exit(1)
		}
	}
	usage()
	os.Exit(1)
}

func usage() {
	fmt.Println("usage: muster <verb> [args]")
	fmt.Println("verbs: init ingest claim verify done promote board show redo fail reimport doctor")
}
```

(Each later task replaces one stub arm with a real call into `internal/cli`; Task 11
introduces the `internal/cli.App` wiring and rewrites this dispatch once.)

- [ ] **Step 4: Verify**

Run: `go build ./...` then `go vet ./...`
Expected: both exit 0, no output.

- [ ] **Step 5: Commit**

```bash
git add go.mod go.sum cmd/muster/main.go internal/store/driver.go
git commit -m "feat(v2): Go module scaffold, sqlite driver pinned, verb dispatch stub"
```

---

### Task 2: card - strict frontmatter parser + per-type schema

**Files:**
- Create: `internal/card/card.go`
- Create: `internal/card/card_test.go`

Ports v1 `Read-Frontmatter` (strict YAML subset, spec v1 2.5) and `Test-TaskSchema`
into one call. v2 differences: unknown keys are rejected (Authority note 9), so
`claimed_at` and `generation` in frontmatter are errors; `seq` is derived from the id.

- [ ] **Step 1: Write the failing tests**

`internal/card/card_test.go`:

```go
package card

import (
	"strings"
	"testing"
)

const goodImpl = `---
id: demo-01-widget
plan: demo
type: impl
tier: any
depends_on: []
protected:
  - tests/widget_test.go
commit_paths:
  - src/widget.go
  - tests/widget_test.go
verify:
  - cmd: go test ./tests
    expect_exit: 0
---
# demo-01-widget: build the widget

## Context
ctx

## Steps
1. do

## Acceptance
- done
`

func parseOK(t *testing.T, text string) *Card {
	t.Helper()
	c, errs := Parse(text, false)
	if len(errs) > 0 {
		t.Fatalf("unexpected errors: %v", errs)
	}
	return c
}

func TestParseGoodImpl(t *testing.T) {
	c := parseOK(t, goodImpl)
	if c.ID != "demo-01-widget" || c.Plan != "demo" || c.Type != "impl" || c.Tier != "any" {
		t.Fatalf("fields: %+v", c)
	}
	if c.Seq != 1 {
		t.Fatalf("seq: %d", c.Seq)
	}
	if len(c.DependsOn) != 0 || len(c.Protected) != 1 || len(c.CommitPaths) != 2 {
		t.Fatalf("lists: %+v", c)
	}
	if len(c.Verify) != 1 || c.Verify[0].Cmd != "go test ./tests" || c.Verify[0].ExpectExit != "0" {
		t.Fatalf("verify: %+v", c.Verify)
	}
	if !strings.Contains(c.Body, "## Steps") {
		t.Fatalf("body lost")
	}
	if len(c.FrontmatterSHA) != 64 {
		t.Fatalf("sha: %q", c.FrontmatterSHA)
	}
}

func TestShaCoversFrontmatterOnly(t *testing.T) {
	a := parseOK(t, goodImpl)
	b := parseOK(t, strings.Replace(goodImpl, "## Context\nctx", "## Context\nother", 1))
	if a.FrontmatterSHA != b.FrontmatterSHA {
		t.Fatalf("body change moved the sha")
	}
	c := parseOK(t, strings.Replace(goodImpl, "tier: any", "tier: strong", 1))
	if a.FrontmatterSHA == c.FrontmatterSHA {
		t.Fatalf("frontmatter change kept the sha")
	}
}

func errContains(t *testing.T, text, want string) {
	t.Helper()
	_, errs := Parse(text, false)
	for _, e := range errs {
		if strings.Contains(e, want) {
			return
		}
	}
	t.Fatalf("errors %v lack %q", errs, want)
}

func TestParseErrors(t *testing.T) {
	errContains(t, "no marker", "missing opening --- marker")
	errContains(t, "---\nid: x\n", "missing closing --- marker")
	errContains(t, strings.Replace(goodImpl, "plan: demo", "Bad Line", 1), "unparseable frontmatter line")
	errContains(t, strings.Replace(goodImpl, "plan: demo", "plan: &anchor", 1), "anchors/aliases are not allowed")
	errContains(t, strings.Replace(goodImpl, "plan: demo", "plan: demo\nclaimed_at: x", 1), "unknown frontmatter key")
	errContains(t, strings.Replace(goodImpl, "plan: demo", "plan: demo\ngeneration: 1", 1), "unknown frontmatter key")
	errContains(t, strings.Replace(goodImpl, "depends_on: []", "depends_on:", 1), "empty value - use [] for an empty list")
}

func TestSchemaErrors(t *testing.T) {
	errContains(t, strings.Replace(goodImpl, "type: impl", "type: chore", 1), "type: illegal value")
	errContains(t, strings.Replace(goodImpl, "tier: any", "tier: mega", 1), "tier: illegal value")
	errContains(t, strings.Replace(goodImpl, "id: demo-01-widget", "id: Demo_01", 1), "id: must be kebab-case")
	// impl needs protected + commit_paths
	errContains(t, strings.Replace(goodImpl, "commit_paths:\n  - src/widget.go\n  - tests/widget_test.go\n", "", 1), "commit_paths: required on impl tasks")
	// review needs reviews; commit_paths forbidden
	rev := strings.NewReplacer(
		"type: impl", "type: review",
		"id: demo-01-widget", "id: demo-02-review-widget",
		"# demo-01-widget: build the widget", "# demo-02-review-widget: review").Replace(goodImpl)
	_, errs := Parse(rev, false)
	joined := strings.Join(errs, "|")
	if !strings.Contains(joined, "reviews: required on review tasks") {
		t.Fatalf("missing reviews error: %v", errs)
	}
	if !strings.Contains(joined, "commit_paths: must be omitted on review tasks") {
		t.Fatalf("missing commit_paths error: %v", errs)
	}
}

func TestVerifySchema(t *testing.T) {
	errContains(t, strings.Replace(goodImpl, "    expect_exit: 0", "    expect_wrong: 0", 1), "verify: unknown key")
	errContains(t, strings.Replace(goodImpl, "    expect_exit: 0", "    expect_exit: soon", 1), "verify: expect_exit must be an integer")
	errContains(t, strings.Replace(goodImpl, "  - cmd: go test ./tests\n    expect_exit: 0", "  - cmd: go test ./tests", 1), "verify: entry needs expect_exit and/or expect_contains")
	errContains(t, strings.Replace(goodImpl, "verify:\n  - cmd: go test ./tests\n    expect_exit: 0", "verify: inline", 1), "verify: must be a block list")
}

func TestStagedMode(t *testing.T) {
	fix := strings.NewReplacer(
		"type: impl", "type: fix",
		"id: demo-01-widget", "id: demo-01-fix-widget",
		"# demo-01-widget: build the widget", "# demo-01-fix-widget: fix").Replace(goodImpl)
	fix = strings.Replace(fix, "plan: demo", "plan: demo\nfixes: demo-01-widget", 1)
	c, errs := Parse(fix, true)
	if len(errs) > 0 {
		t.Fatalf("staged fix should parse: %v", errs)
	}
	if c.Fixes != "demo-01-widget" {
		t.Fatalf("fixes: %q", c.Fixes)
	}
}

func TestQuoteStripping(t *testing.T) {
	q := strings.Replace(goodImpl, `  - cmd: go test ./tests`, `  - cmd: "go test ./tests"`, 1)
	c := parseOK(t, q)
	if c.Verify[0].Cmd != "go test ./tests" {
		t.Fatalf("quotes not stripped: %q", c.Verify[0].Cmd)
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/card`
Expected: FAIL (undefined: Parse, Card).

- [ ] **Step 3: Implement the parser + schema**

`internal/card/card.go`:

```go
// Package card parses and validates MUSTER task cards: a strict YAML-subset
// frontmatter (v1 spec 2.5 semantics, unknown keys rejected) plus a markdown
// body. Values stay strings; the verify runner parses integers at use time.
package card

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

type VerifyEntry struct {
	Cmd            string
	ExpectExit     string
	ExpectContains string
	TimeoutSeconds string
}

type Card struct {
	ID, Plan, Type, Tier, Harness string
	Seq                           int
	DependsOn, Protected          []string
	CommitPaths                   []string
	Reviews, Fixes                string
	Verify                        []VerifyEntry
	Body                          string
	FrontmatterSHA                string
}

var (
	kebab   = regexp.MustCompile(`^[a-z0-9-]+$`)
	keyLine = regexp.MustCompile(`^([a-z_]+):(.*)$`)
	seqPat  = regexp.MustCompile(`-(\d{2})-`)
)

// scalar and list keys the schema knows; anything else is an error.
var scalarKeys = map[string]bool{
	"id": true, "plan": true, "type": true, "tier": true,
	"harness": true, "reviews": true, "fixes": true,
}
var listKeys = map[string]bool{
	"depends_on": true, "protected": true, "commit_paths": true,
}

func stripQuotes(v string) string {
	if len(v) >= 2 && strings.HasPrefix(v, `"`) && strings.HasSuffix(v, `"`) {
		return v[1 : len(v)-1]
	}
	return v
}

// Parse parses text into a Card and validates the schema for its type.
// staged=true is lint-lite mode for a reviewer-authored fix (fix filename
// pattern is checked by lint, not here). A non-empty error list means the
// card is invalid; the returned Card is still populated as far as parsing got.
func Parse(text string, staged bool) (*Card, []string) {
	c := &Card{DependsOn: []string{}, Protected: []string{}, CommitPaths: []string{}}
	var errs []string
	scalars := map[string]string{}
	lists := map[string][]string{}

	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	if len(lines) < 3 || lines[0] != "---" {
		return c, []string{"missing opening --- marker"}
	}
	close := 0
	for j := 1; j < len(lines); j++ {
		if lines[j] == "---" {
			close = j
			break
		}
	}
	if close == 0 {
		return c, []string{"missing closing --- marker"}
	}

	sum := sha256.Sum256([]byte(strings.Join(lines[0:close+1], "\n")))
	c.FrontmatterSHA = hex.EncodeToString(sum[:])

	i := 1
	for i < close {
		line := lines[i]
		if strings.TrimSpace(line) == "" {
			i++
			continue
		}
		m := keyLine.FindStringSubmatch(line)
		if m == nil {
			errs = append(errs, "unparseable frontmatter line: "+line)
			i++
			continue
		}
		key, val := m[1], strings.TrimSpace(m[2])

		if key == "verify" {
			if val != "" {
				return c, append(errs, "verify: must be a block list")
			}
			i++
			for i < close {
				vl := lines[i]
				if em := regexp.MustCompile(`^  - ([a-z_]+): (.+)$`).FindStringSubmatch(vl); em != nil {
					c.Verify = append(c.Verify, VerifyEntry{})
					setVerifyKey(&c.Verify[len(c.Verify)-1], em[1], stripQuotes(strings.TrimSpace(em[2])), &errs)
					i++
				} else if em := regexp.MustCompile(`^    ([a-z_]+): (.+)$`).FindStringSubmatch(vl); em != nil {
					if len(c.Verify) == 0 {
						return c, append(errs, "verify: continuation before first entry: "+vl)
					}
					setVerifyKey(&c.Verify[len(c.Verify)-1], em[1], stripQuotes(strings.TrimSpace(em[2])), &errs)
					i++
				} else {
					break
				}
			}
			if len(c.Verify) == 0 {
				errs = append(errs, "verify: empty block")
			}
			scalars["verify"] = "present"
			continue
		}

		if !scalarKeys[key] && !listKeys[key] {
			errs = append(errs, "unknown frontmatter key: "+key)
			i++
			continue
		}
		switch {
		case val == "[]":
			lists[key] = []string{}
			i++
		case val == "":
			var items []string
			i++
			for i < close {
				im := regexp.MustCompile(`^\s+- (.+)$`).FindStringSubmatch(lines[i])
				if im == nil {
					break
				}
				items = append(items, stripQuotes(strings.TrimSpace(im[1])))
				i++
			}
			if len(items) == 0 {
				errs = append(errs, key+": empty value - use [] for an empty list")
			}
			lists[key] = items
		default:
			if strings.HasPrefix(val, "&") || strings.HasPrefix(val, "*") {
				errs = append(errs, key+": anchors/aliases are not allowed")
			}
			if listKeys[key] {
				errs = append(errs, key+": must be a list")
				i++
				continue
			}
			scalars[key] = stripQuotes(val)
			i++
		}
	}
	if close+1 < len(lines) {
		c.Body = strings.Join(lines[close+1:], "\n")
	}

	c.ID = scalars["id"]
	c.Plan = scalars["plan"]
	c.Type = scalars["type"]
	c.Tier = scalars["tier"]
	c.Harness = scalars["harness"]
	c.Reviews = scalars["reviews"]
	c.Fixes = scalars["fixes"]
	if v, ok := lists["depends_on"]; ok {
		c.DependsOn = v
	}
	if v, ok := lists["protected"]; ok {
		c.Protected = v
	}
	if v, ok := lists["commit_paths"]; ok {
		c.CommitPaths = v
	}
	if sm := seqPat.FindStringSubmatch(c.ID); sm != nil {
		c.Seq, _ = strconv.Atoi(sm[1])
	}

	errs = append(errs, schemaErrors(c, scalars, lists, staged)...)
	return c, errs
}

func setVerifyKey(e *VerifyEntry, key, val string, errs *[]string) {
	switch key {
	case "cmd":
		e.Cmd = val
	case "expect_exit":
		e.ExpectExit = val
	case "expect_contains":
		e.ExpectContains = val
	case "timeout_seconds":
		e.TimeoutSeconds = val
	default:
		*errs = append(*errs, "verify: unknown key '"+key+"'")
	}
}

func schemaErrors(c *Card, scalars map[string]string, lists map[string][]string, staged bool) []string {
	var e []string
	req := []string{"id", "plan", "type", "tier", "verify"}
	for _, r := range req {
		if _, ok := scalars[r]; !ok {
			e = append(e, "missing required field: "+r)
		}
	}
	if _, ok := lists["depends_on"]; !ok {
		e = append(e, "missing required field: depends_on")
	}
	if len(e) > 0 {
		return e
	}
	switch c.Type {
	case "impl", "review", "fix", "integration":
	default:
		return []string{fmt.Sprintf("type: illegal value '%s'", c.Type)}
	}
	if c.Tier != "any" && c.Tier != "strong" {
		e = append(e, fmt.Sprintf("tier: illegal value '%s'", c.Tier))
	}
	if c.Harness != "" && c.Harness != "claude" && c.Harness != "codex" {
		e = append(e, fmt.Sprintf("harness: illegal value '%s'", c.Harness))
	}
	if !kebab.MatchString(c.ID) {
		e = append(e, "id: must be kebab-case [a-z0-9-]+")
	}
	if !kebab.MatchString(c.Plan) {
		e = append(e, "plan: must be kebab-case [a-z0-9-]+")
	}
	if c.Type == "review" && c.Reviews == "" {
		e = append(e, "reviews: required on review tasks")
	}
	if c.Type == "fix" && c.Fixes == "" {
		e = append(e, "fixes: required on fix tasks")
	}
	if c.Type == "impl" || c.Type == "fix" {
		if _, ok := lists["protected"]; !ok {
			e = append(e, "protected: required on "+c.Type+" tasks")
		}
		if _, ok := lists["commit_paths"]; !ok {
			e = append(e, "commit_paths: required on "+c.Type+" tasks")
		}
	} else if _, ok := lists["commit_paths"]; ok {
		e = append(e, "commit_paths: must be omitted on "+c.Type+" tasks (outputs are sidecars only)")
	}
	for _, en := range c.Verify {
		if en.Cmd == "" {
			e = append(e, "verify: entry missing cmd")
		}
		if en.ExpectExit == "" && en.ExpectContains == "" {
			e = append(e, "verify: entry needs expect_exit and/or expect_contains")
		}
		for name, v := range map[string]string{"expect_exit": en.ExpectExit, "timeout_seconds": en.TimeoutSeconds} {
			if v != "" {
				if _, err := strconv.Atoi(v); err != nil {
					e = append(e, "verify: "+name+" must be an integer")
				}
			}
		}
	}
	_ = staged // fix-filename pattern and staged-only rules live in lint (Task 10)
	return e
}
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/card`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/card/card.go internal/card/card_test.go
git commit -m "feat(v2): card frontmatter parser + per-type schema validation"
```

---
### Task 3: store - open, pragmas, migrations, schema v1

**Files:**
- Create: `internal/store/store.go`
- Create: `internal/store/schema.go`
- Create: `internal/store/store_test.go`

- [ ] **Step 1: Write the failing tests**

`internal/store/store_test.go`:

```go
package store

import (
	"path/filepath"
	"testing"
)

func open(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "muster.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestOpenAppliesPragmas(t *testing.T) {
	s := open(t)
	for pragma, want := range map[string]string{
		"journal_mode": "wal",
		"synchronous":  "2", // FULL
		"foreign_keys": "1",
	} {
		var got string
		if err := s.db.QueryRow("PRAGMA " + pragma).Scan(&got); err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Fatalf("%s = %q, want %q", pragma, got, want)
		}
	}
}

func TestMigrateSetsVersionAndIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "m.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	var v int
	if err := s.db.QueryRow("SELECT version FROM schema_version").Scan(&v); err != nil {
		t.Fatal(err)
	}
	if v != 1 {
		t.Fatalf("version = %d", v)
	}
	s.Close()
	s2, err := Open(path) // reopen must not re-run migration 1
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	if err := s2.db.QueryRow("SELECT version FROM schema_version").Scan(&v); err != nil {
		t.Fatal(err)
	}
	if v != 1 {
		t.Fatalf("version after reopen = %d", v)
	}
}

func TestEventsAreAppendOnly(t *testing.T) {
	s := open(t)
	mustExec(t, s, `INSERT INTO tasks(id, plan, seq, type, tier, status, card_path, frontmatter_sha)
		VALUES ('p-01-a', 'p', 1, 'impl', 'any', 'backlog', '.muster/cards/p-01-a.md', 'x')`)
	mustExec(t, s, `INSERT INTO events(task_id, actor, verb, detail, created_at, prev_hash, hash)
		VALUES ('p-01-a', 't', 'claim', '', '2026-01-01T00:00:00Z', '', 'h1')`)
	if _, err := s.db.Exec(`UPDATE events SET verb='done'`); err == nil {
		t.Fatal("UPDATE on events must be blocked")
	}
	if _, err := s.db.Exec(`DELETE FROM events`); err == nil {
		t.Fatal("DELETE on events must be blocked")
	}
}

func TestStatusCheckConstraint(t *testing.T) {
	s := open(t)
	if _, err := s.db.Exec(`INSERT INTO tasks(id, plan, seq, type, tier, status, card_path, frontmatter_sha)
		VALUES ('p-01-a', 'p', 1, 'impl', 'any', 'flying', 'x', 'x')`); err == nil {
		t.Fatal("illegal status must be rejected")
	}
}

func mustExec(t *testing.T, s *Store, q string, args ...any) {
	t.Helper()
	if _, err := s.db.Exec(q, args...); err != nil {
		t.Fatal(err)
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/store`
Expected: FAIL (undefined: Open, Store).

- [ ] **Step 3: Implement**

`internal/store/schema.go`:

```go
package store

// migrations[i] is schema version i+1. Each runs inside one transaction; the
// runner records the new version in the same transaction.
var migrations = []string{`
CREATE TABLE tasks(
  id TEXT PRIMARY KEY,
  plan TEXT NOT NULL,
  seq INTEGER NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('impl','review','fix','integration')),
  tier TEXT NOT NULL CHECK (tier IN ('any','strong')),
  harness TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL CHECK (status IN ('backlog','inbox','doing','done','failed')),
  card_path TEXT NOT NULL,
  frontmatter_sha TEXT NOT NULL,
  reviews TEXT NOT NULL DEFAULT '',
  fixes TEXT NOT NULL DEFAULT '',
  head_at_claim TEXT NOT NULL DEFAULT '',
  claimed_at TEXT NOT NULL DEFAULT '',
  claimed_by TEXT NOT NULL DEFAULT '',
  generation INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE deps(
  task_id TEXT NOT NULL REFERENCES tasks(id),
  depends_on TEXT NOT NULL REFERENCES tasks(id),
  PRIMARY KEY (task_id, depends_on)
) WITHOUT ROWID;
CREATE TABLE events(
  id INTEGER PRIMARY KEY,
  task_id TEXT NOT NULL,
  actor TEXT NOT NULL,
  verb TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  prev_hash TEXT NOT NULL,
  hash TEXT NOT NULL
);
CREATE TRIGGER events_no_update BEFORE UPDATE ON events
BEGIN SELECT RAISE(ABORT, 'events are append-only'); END;
CREATE TRIGGER events_no_delete BEFORE DELETE ON events
BEGIN SELECT RAISE(ABORT, 'events are append-only'); END;
CREATE TABLE verdicts(
  task_id TEXT NOT NULL,
  reviewer TEXT NOT NULL,
  verdict TEXT NOT NULL CHECK (verdict IN ('pass','fail')),
  reason TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);
CREATE INDEX verdicts_task ON verdicts(task_id);
CREATE TABLE schema_version(version INTEGER NOT NULL);
INSERT INTO schema_version(version) VALUES (0);
`}
```

`internal/store/store.go`:

```go
package store

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"time"
)

type Store struct {
	db *sql.DB
}

// Open opens (creating if absent) the board database at path, applies the
// operational pragmas, and runs any pending migrations. The returned Store is
// safe for use from one process; cross-process safety comes from SQLite
// locking plus busy_timeout.
func Open(path string) (*Store, error) {
	dsn := "file:" + filepath.ToSlash(path) + "?" + strings.Join([]string{
		"_pragma=journal_mode(WAL)",
		"_pragma=synchronous(FULL)",
		"_pragma=busy_timeout(5000)",
		"_pragma=foreign_keys(1)",
	}, "&")
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// One connection: the CLI is short-lived and single-threaded except the
	// claim race, which is cross-process, not cross-goroutine.
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	var have int
	if err := s.db.QueryRow("SELECT version FROM schema_version").Scan(&have); err != nil {
		have = 0 // fresh file: migration 1 creates schema_version at version 0
	}
	for v := have; v < len(migrations); v++ {
		if err := s.applyMigration(v); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) applyMigration(v int) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(migrations[v]); err != nil {
		return fmt.Errorf("migration %d: %w", v+1, err)
	}
	if _, err := tx.Exec("UPDATE schema_version SET version = ?", v+1); err != nil {
		return fmt.Errorf("migration %d: %w", v+1, err)
	}
	return tx.Commit()
}

// IsoNow formats t as the board's canonical UTC timestamp.
func IsoNow(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05Z") }
```

The fresh-file case in `migrate` works because migration 1 itself creates
`schema_version` at version 0 and `applyMigration` bumps it to 1 inside the
same transaction - a crash mid-migration leaves version untouched.

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/store`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/store/store.go internal/store/schema.go internal/store/store_test.go
git commit -m "feat(v2): store open/pragmas/migrations + schema v1 with append-only events"
```

---

### Task 4: store - hash-chained events

**Files:**
- Create: `internal/store/events.go`
- Create: `internal/store/events_test.go`

Chain rule (spec D-v2-4): `hash = sha256hex(prev_hash + "\n" + task_id + "\n" +
actor + "\n" + verb + "\n" + detail + "\n" + created_at)`. Genesis `prev_hash` is
the empty string. The chain is board-global in `events.id` order.

- [ ] **Step 1: Write the failing tests**

`internal/store/events_test.go`:

```go
package store

import (
	"strings"
	"testing"
)

func seedTask(t *testing.T, s *Store, id string) {
	t.Helper()
	mustExec(t, s, `INSERT INTO tasks(id, plan, seq, type, tier, status, card_path, frontmatter_sha)
		VALUES (?, 'p', 1, 'impl', 'any', 'backlog', ?, 'x')`, id, ".muster/cards/"+id+".md")
}

func TestAppendEventChains(t *testing.T) {
	s := open(t)
	seedTask(t, s, "p-01-a")
	if err := s.AppendEvent("p-01-a", "claude/any", "claim", "", "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if err := s.AppendEvent("p-01-a", "claude/any", "attempt", "1", "2026-01-01T00:01:00Z"); err != nil {
		t.Fatal(err)
	}
	evs, err := s.Events("p-01-a")
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 2 {
		t.Fatalf("events: %d", len(evs))
	}
	if evs[0].PrevHash != "" {
		t.Fatalf("genesis prev: %q", evs[0].PrevHash)
	}
	if evs[1].PrevHash != evs[0].Hash {
		t.Fatalf("chain broken: %q vs %q", evs[1].PrevHash, evs[0].Hash)
	}
	head, err := s.ChainHead()
	if err != nil {
		t.Fatal(err)
	}
	if head != evs[1].Hash {
		t.Fatalf("head: %q", head)
	}
	if err := s.VerifyChain(); err != nil {
		t.Fatalf("chain must verify: %v", err)
	}
}

func TestVerifyChainDetectsForgedInsert(t *testing.T) {
	s := open(t)
	seedTask(t, s, "p-01-a")
	if err := s.AppendEvent("p-01-a", "claude/any", "claim", "", "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	// UPDATE/DELETE are trigger-blocked; a confused writer can still INSERT a
	// row with a fabricated hash. VerifyChain must catch it.
	mustExec(t, s, `INSERT INTO events(task_id, actor, verb, detail, created_at, prev_hash, hash)
		VALUES ('p-01-a', 'gremlin', 'done', '', '2026-01-01T00:02:00Z', 'nonsense', 'forged')`)
	err := s.VerifyChain()
	if err == nil || !strings.Contains(err.Error(), "chain") {
		t.Fatalf("forged insert not detected: %v", err)
	}
}

func TestAttemptAndClaimCounts(t *testing.T) {
	s := open(t)
	seedTask(t, s, "p-01-a")
	stamp := func(i int) string { return "2026-01-01T00:0" + string(rune('0'+i)) + ":00Z" }
	s.AppendEvent("p-01-a", "claude/any", "claim", "", stamp(0))
	s.AppendEvent("p-01-a", "claude/any", "attempt", "1", stamp(1))
	s.AppendEvent("p-01-a", "claude/any", "attempt", "2", stamp(2))
	// redo + fresh claim resets the attempt window (D28 semantics)
	s.AppendEvent("p-01-a", "human", "redo", "", stamp(3))
	s.AppendEvent("p-01-a", "claude/any", "claim", "", stamp(4))
	s.AppendEvent("p-01-a", "claude/any", "attempt", "1", stamp(5))
	n, err := s.AttemptsSinceClaim("p-01-a")
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("attempts = %d, want 1 (window resets at the newest claim)", n)
	}
	cc, err := s.ClaimCount("p-01-a")
	if err != nil {
		t.Fatal(err)
	}
	if cc != 2 {
		t.Fatalf("claims = %d", cc)
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/store`
Expected: FAIL (undefined: AppendEvent and friends).

- [ ] **Step 3: Implement**

`internal/store/events.go`:

```go
package store

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
)

type Event struct {
	ID                                                int64
	TaskID, Actor, Verb, Detail, CreatedAt, PrevHash, Hash string
}

func eventHash(prev, taskID, actor, verb, detail, createdAt string) string {
	sum := sha256.Sum256([]byte(prev + "\n" + taskID + "\n" + actor + "\n" + verb + "\n" + detail + "\n" + createdAt))
	return hex.EncodeToString(sum[:])
}

// execer covers *sql.DB, *sql.Tx and *sql.Conn-backed transactions so event
// appends compose into larger transactions (claim, done, cycle).
type execer interface {
	Exec(query string, args ...any) (sql.Result, error)
	QueryRow(query string, args ...any) *sql.Row
}

func appendEventOn(q execer, taskID, actor, verb, detail, createdAt string) error {
	var prev string
	err := q.QueryRow("SELECT hash FROM events ORDER BY id DESC LIMIT 1").Scan(&prev)
	if err == sql.ErrNoRows {
		prev = ""
	} else if err != nil {
		return err
	}
	h := eventHash(prev, taskID, actor, verb, detail, createdAt)
	_, err = q.Exec(`INSERT INTO events(task_id, actor, verb, detail, created_at, prev_hash, hash)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, taskID, actor, verb, detail, createdAt, prev, h)
	return err
}

// AppendEvent appends one event as its own transaction.
func (s *Store) AppendEvent(taskID, actor, verb, detail, createdAt string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := appendEventOn(tx, taskID, actor, verb, detail, createdAt); err != nil {
		return err
	}
	return tx.Commit()
}

// Events returns a task's events in append order.
func (s *Store) Events(taskID string) ([]Event, error) {
	rows, err := s.db.Query(`SELECT id, task_id, actor, verb, detail, created_at, prev_hash, hash
		FROM events WHERE task_id = ? ORDER BY id`, taskID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Event
	for rows.Next() {
		var e Event
		if err := rows.Scan(&e.ID, &e.TaskID, &e.Actor, &e.Verb, &e.Detail, &e.CreatedAt, &e.PrevHash, &e.Hash); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// ChainHead returns the newest event hash, or "" on an empty board.
func (s *Store) ChainHead() (string, error) {
	var h string
	err := s.db.QueryRow("SELECT hash FROM events ORDER BY id DESC LIMIT 1").Scan(&h)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return h, err
}

// VerifyChain recomputes every hash in id order and checks linkage.
func (s *Store) VerifyChain() error {
	rows, err := s.db.Query(`SELECT id, task_id, actor, verb, detail, created_at, prev_hash, hash
		FROM events ORDER BY id`)
	if err != nil {
		return err
	}
	defer rows.Close()
	prev := ""
	for rows.Next() {
		var e Event
		if err := rows.Scan(&e.ID, &e.TaskID, &e.Actor, &e.Verb, &e.Detail, &e.CreatedAt, &e.PrevHash, &e.Hash); err != nil {
			return err
		}
		if e.PrevHash != prev {
			return fmt.Errorf("event %d: chain linkage broken (prev_hash %q, expected %q)", e.ID, e.PrevHash, prev)
		}
		want := eventHash(e.PrevHash, e.TaskID, e.Actor, e.Verb, e.Detail, e.CreatedAt)
		if e.Hash != want {
			return fmt.Errorf("event %d: chain hash mismatch", e.ID)
		}
		prev = e.Hash
	}
	return rows.Err()
}

// AttemptsSinceClaim counts attempt events newer than the task's newest claim
// event. A redo followed by a re-claim therefore starts a fresh window.
func (s *Store) AttemptsSinceClaim(taskID string) (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM events
		WHERE task_id = ? AND verb = 'attempt'
		  AND id > COALESCE((SELECT MAX(id) FROM events WHERE task_id = ? AND verb = 'claim'), 0)`,
		taskID, taskID).Scan(&n)
	return n, err
}

// ClaimCount counts a task's claim events (recovery-probe gate: > 1 means a
// prior session claimed this task before the current one).
func (s *Store) ClaimCount(taskID string) (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM events WHERE task_id = ? AND verb = 'claim'`, taskID).Scan(&n)
	return n, err
}
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/store`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/store/events.go internal/store/events_test.go
git commit -m "feat(v2): hash-chained append-only events with attempt/claim windows"
```

---
### Task 5: store - ingest insert, task queries, status flips, backup

**Files:**
- Create: `internal/store/tasks.go`
- Create: `internal/store/tasks_test.go`

- [ ] **Step 1: Write the failing tests**

`internal/store/tasks_test.go`:

```go
package store

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func row(id, typ, tier string, deps ...string) IngestTask {
	return IngestTask{
		Task: Task{ID: id, Plan: "p", Seq: 1, Type: typ, Tier: tier,
			CardPath: ".muster/cards/" + id + ".md", FrontmatterSHA: "sha-" + id},
		Deps: deps,
	}
}

func TestIngestAndQueries(t *testing.T) {
	s := open(t)
	batch := []IngestTask{
		row("p-01-a", "impl", "any"),
		row("p-02-b", "impl", "any", "p-01-a"),
	}
	if err := s.Ingest(batch, "shard", "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	got, err := s.Task("p-02-b")
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || got.Status != "backlog" || got.FrontmatterSHA != "sha-p-02-b" {
		t.Fatalf("row: %+v", got)
	}
	if missing, _ := s.Task("nope"); missing != nil {
		t.Fatal("absent id must return nil")
	}
	bl, err := s.TasksByStatus("backlog")
	if err != nil || len(bl) != 2 {
		t.Fatalf("backlog: %v %v", bl, err)
	}
	evs, _ := s.Events("p-01-a")
	if len(evs) != 1 || evs[0].Verb != "ingest" {
		t.Fatalf("ingest event missing: %+v", evs)
	}
}

func TestIngestFailsClosedOnUnknownDep(t *testing.T) {
	s := open(t)
	err := s.Ingest([]IngestTask{row("p-01-a", "impl", "any", "ghost-99-x")}, "shard", "2026-01-01T00:00:00Z")
	if err == nil || !strings.Contains(err.Error(), "ghost-99-x") {
		t.Fatalf("unknown dep must fail closed: %v", err)
	}
	// the whole batch must roll back
	if got, _ := s.Task("p-01-a"); got != nil {
		t.Fatal("failed batch must not leave rows")
	}
}

func TestIngestRefusesDuplicateID(t *testing.T) {
	s := open(t)
	if err := s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	err := s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:01:00Z")
	if err == nil || !strings.Contains(err.Error(), "already on the board") {
		t.Fatalf("duplicate must refuse: %v", err)
	}
}

func TestStatusFlips(t *testing.T) {
	s := open(t)
	s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z")
	mustExec(t, s, `UPDATE tasks SET status='doing' WHERE id='p-01-a'`)
	if err := s.MarkDone("p-01-a", "claude/any", "2026-01-01T01:00:00Z"); err != nil {
		t.Fatal(err)
	}
	got, _ := s.Task("p-01-a")
	if got.Status != "done" {
		t.Fatalf("status: %s", got.Status)
	}
	if err := s.MarkDone("p-01-a", "claude/any", "2026-01-01T01:01:00Z"); err == nil {
		t.Fatal("MarkDone from done must error (guarded flip)")
	}
	if err := s.MarkInbox("p-01-a", "human", "2026-01-01T01:02:00Z"); err == nil {
		t.Fatal("redo from done must error")
	}
	mustExec(t, s, `UPDATE tasks SET status='failed' WHERE id='p-01-a'`)
	if err := s.MarkInbox("p-01-a", "human", "2026-01-01T01:03:00Z"); err != nil {
		t.Fatal(err)
	}
	got, _ = s.Task("p-01-a")
	if got.Status != "inbox" || got.ClaimedAt != "" || got.HeadAtClaim != "" {
		t.Fatalf("redo must clear claim fields: %+v", got)
	}
}

func TestVerdicts(t *testing.T) {
	s := open(t)
	s.Ingest([]IngestTask{row("p-02-r", "review", "strong")}, "shard", "2026-01-01T00:00:00Z")
	if err := s.InsertVerdict("p-02-r", "claude/strong", "fail", "wrong shape", "2026-01-01T02:00:00Z"); err != nil {
		t.Fatal(err)
	}
	vs, err := s.Verdicts("p-02-r")
	if err != nil || len(vs) != 1 || vs[0].Reason != "wrong shape" {
		t.Fatalf("verdicts: %+v %v", vs, err)
	}
}

func TestBackup(t *testing.T) {
	s := open(t)
	s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z")
	dst := filepath.Join(t.TempDir(), "backup.db")
	if err := s.Backup(dst); err != nil {
		t.Fatal(err)
	}
	if err := s.Backup(dst); err != nil { // second run must overwrite, not fail
		t.Fatal(err)
	}
	if _, err := os.Stat(dst); err != nil {
		t.Fatal(err)
	}
	b, err := Open(dst)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	got, _ := b.Task("p-01-a")
	if got == nil {
		t.Fatal("backup lost rows")
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/store`
Expected: FAIL (undefined: IngestTask etc.).

- [ ] **Step 3: Implement**

`internal/store/tasks.go`:

```go
package store

import (
	"database/sql"
	"fmt"
	"os"
	"sort"
)

type Task struct {
	ID, Plan                      string
	Seq                           int
	Type, Tier, Harness, Status   string
	CardPath, FrontmatterSHA      string
	Reviews, Fixes                string
	HeadAtClaim, ClaimedAt, ClaimedBy string
	Generation                    int
}

type IngestTask struct {
	Task Task
	Deps []string
}

const taskCols = `id, plan, seq, type, tier, harness, status, card_path,
	frontmatter_sha, reviews, fixes, head_at_claim, claimed_at, claimed_by, generation`

func scanTask(row interface{ Scan(...any) error }) (*Task, error) {
	var t Task
	err := row.Scan(&t.ID, &t.Plan, &t.Seq, &t.Type, &t.Tier, &t.Harness, &t.Status,
		&t.CardPath, &t.FrontmatterSHA, &t.Reviews, &t.Fixes,
		&t.HeadAtClaim, &t.ClaimedAt, &t.ClaimedBy, &t.Generation)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &t, nil
}

// Ingest inserts a linted batch: all task rows, then all deps, one transaction.
// Deps must resolve inside the batch or against rows already on the board -
// unknown ids fail the whole batch (spec D-v2-3: fail closed). Duplicate ids
// refuse. status starts at backlog; promote lifts the dep-free ones.
func (s *Store) Ingest(batch []IngestTask, actor, now string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	inBatch := map[string]bool{}
	for _, it := range batch {
		inBatch[it.Task.ID] = true
	}
	for _, it := range batch {
		var exists int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM tasks WHERE id = ?`, it.Task.ID).Scan(&exists); err != nil {
			return err
		}
		if exists > 0 {
			return fmt.Errorf("%s: already on the board", it.Task.ID)
		}
		t := it.Task
		if _, err := tx.Exec(`INSERT INTO tasks(id, plan, seq, type, tier, harness, status,
			card_path, frontmatter_sha, reviews, fixes, generation)
			VALUES (?, ?, ?, ?, ?, ?, 'backlog', ?, ?, ?, ?, ?)`,
			t.ID, t.Plan, t.Seq, t.Type, t.Tier, t.Harness,
			t.CardPath, t.FrontmatterSHA, t.Reviews, t.Fixes, t.Generation); err != nil {
			return err
		}
	}
	for _, it := range batch {
		for _, dep := range it.Deps {
			if !inBatch[dep] {
				var n int
				if err := tx.QueryRow(`SELECT COUNT(*) FROM tasks WHERE id = ?`, dep).Scan(&n); err != nil {
					return err
				}
				if n == 0 {
					return fmt.Errorf("%s: depends_on '%s' exists nowhere - ingest fails closed", it.Task.ID, dep)
				}
			}
			if _, err := tx.Exec(`INSERT INTO deps(task_id, depends_on) VALUES (?, ?)`, it.Task.ID, dep); err != nil {
				return err
			}
		}
	}
	for _, it := range batch {
		if err := appendEventOn(tx, it.Task.ID, actor, "ingest", "", now); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// Task returns one row, nil when absent.
func (s *Store) Task(id string) (*Task, error) {
	return scanTask(s.db.QueryRow(`SELECT `+taskCols+` FROM tasks WHERE id = ?`, id))
}

// TasksByStatus returns rows in id order.
func (s *Store) TasksByStatus(status string) ([]Task, error) {
	rows, err := s.db.Query(`SELECT `+taskCols+` FROM tasks WHERE status = ? ORDER BY id`, status)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Task
	for rows.Next() {
		t, err := scanTask(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *t)
	}
	return out, rows.Err()
}

// Doing returns the doing rows (the board invariant is 0 or 1; callers refuse on more).
func (s *Store) Doing() ([]Task, error) { return s.TasksByStatus("doing") }

func (s *Store) flip(id, to, actor, verb, detail, now string, clearClaim bool, froms []string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	set := `status = ?`
	if clearClaim {
		set += `, head_at_claim = '', claimed_at = '', claimed_by = ''`
	}
	args := []any{to, id}
	marks := ""
	for i, f := range froms {
		if i > 0 {
			marks += ","
		}
		marks += "?"
		args = append(args, f)
	}
	res, err := tx.Exec(`UPDATE tasks SET `+set+` WHERE id = ? AND status IN (`+marks+`)`, args...)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return fmt.Errorf("%s: cannot flip to %s (status not in %v)", id, to, froms)
	}
	if err := appendEventOn(tx, id, actor, verb, detail, now); err != nil {
		return err
	}
	return tx.Commit()
}

// MarkDone flips doing -> done (done pass path and the claim-time reconciler).
func (s *Store) MarkDone(id, actor, now string) error {
	return s.flip(id, "done", actor, "done", "", now, false, []string{"doing"})
}

// MarkFailed flips doing/inbox/backlog -> failed (terminal verify, review cap,
// human fail verb - including giving up a dead-blocked backlog task).
func (s *Store) MarkFailed(id, actor, detail, now string) error {
	return s.flip(id, "failed", actor, "fail", detail, now, false, []string{"doing", "inbox", "backlog"})
}

// MarkInbox is redo: doing/failed -> inbox with claim fields cleared; the next
// claim event starts a fresh attempt window.
func (s *Store) MarkInbox(id, actor, now string) error {
	return s.flip(id, "inbox", actor, "redo", "", now, true, []string{"doing", "failed"})
}

// InsertVerdict records a review/integration verdict row.
func (s *Store) InsertVerdict(taskID, reviewer, verdict, reason, now string) error {
	_, err := s.db.Exec(`INSERT INTO verdicts(task_id, reviewer, verdict, reason, created_at)
		VALUES (?, ?, ?, ?, ?)`, taskID, reviewer, verdict, reason, now)
	return err
}

// Verdicts returns a task's verdicts in insert order.
func (s *Store) Verdicts(taskID string) ([]Verdict, error) {
	rows, err := s.db.Query(`SELECT task_id, reviewer, verdict, reason, created_at
		FROM verdicts WHERE task_id = ? ORDER BY rowid`, taskID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Verdict
	for rows.Next() {
		var v Verdict
		if err := rows.Scan(&v.TaskID, &v.Reviewer, &v.Verdict, &v.Reason, &v.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

type Verdict struct {
	TaskID, Reviewer, Verdict, Reason, CreatedAt string
}

// Deps returns a task's dependency ids, sorted.
func (s *Store) Deps(taskID string) ([]string, error) {
	rows, err := s.db.Query(`SELECT depends_on FROM deps WHERE task_id = ?`, taskID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var d string
		if err := rows.Scan(&d); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	sort.Strings(out)
	return out, rows.Err()
}

// Backup refreshes dst via VACUUM INTO (spec D-v2-4). VACUUM INTO refuses an
// existing target, so stale backups are removed first.
func (s *Store) Backup(dst string) error {
	if err := os.Remove(dst); err != nil && !os.IsNotExist(err) {
		return err
	}
	_, err := s.db.Exec(`VACUUM INTO ?`, dst)
	return err
}
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/store`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/store/tasks.go internal/store/tasks_test.go
git commit -m "feat(v2): store ingest (fail-closed deps), queries, guarded flips, backup"
```

---

### Task 6: store - atomic claim transaction (riskiest piece first)

**Files:**
- Create: `internal/store/claim.go`
- Create: `internal/store/claim_test.go`

Spec section 4: `BEGIN IMMEDIATE`, select-eligible + guarded UPDATE + claim event,
nothing slow inside the transaction. `head_at_claim` is captured by the CALLER
before the transaction (git read outside the tx).

- [ ] **Step 1: Write the failing tests**

`internal/store/claim_test.go`:

```go
package store

import (
	"path/filepath"
	"sync"
	"testing"
)

func seedInbox(t *testing.T, s *Store, id, tier, harness string) {
	t.Helper()
	mustExec(t, s, `INSERT INTO tasks(id, plan, seq, type, tier, harness, status, card_path, frontmatter_sha)
		VALUES (?, 'p', 1, 'impl', ?, ?, 'inbox', ?, 'x')`, id, tier, harness, ".muster/cards/"+id+".md")
}

func TestNextEligibleOrderAndPinning(t *testing.T) {
	s := open(t)
	seedInbox(t, s, "p-03-c", "any", "")
	seedInbox(t, s, "p-01-a", "strong", "")
	seedInbox(t, s, "p-02-b", "any", "codex")

	got, err := s.NextEligible("any", "claude")
	if err != nil {
		t.Fatal(err)
	}
	// p-01-a is strong (tier equality excludes it), p-02-b is pinned codex:
	// the lowest eligible id for claude/any is p-03-c.
	if got == nil || got.ID != "p-03-c" {
		t.Fatalf("eligible: %+v", got)
	}
	strong, err := s.NextEligible("strong", "claude")
	if err != nil {
		t.Fatal(err)
	}
	if strong == nil || strong.ID != "p-01-a" {
		t.Fatalf("strong session must take only strong tasks: %+v", strong)
	}
	codex, err := s.NextEligible("any", "codex")
	if err != nil {
		t.Fatal(err)
	}
	if codex == nil || codex.ID != "p-02-b" {
		t.Fatalf("codex pin: %+v", codex)
	}
}

func TestClaimTaskFlipsAndStamps(t *testing.T) {
	s := open(t)
	seedInbox(t, s, "p-01-a", "any", "")
	ok, err := s.ClaimTask("p-01-a", "claude/any", "abc123", "2026-01-01T00:00:00Z")
	if err != nil || !ok {
		t.Fatalf("claim: %v %v", ok, err)
	}
	got, _ := s.Task("p-01-a")
	if got.Status != "doing" || got.HeadAtClaim != "abc123" || got.ClaimedBy != "claude/any" ||
		got.ClaimedAt != "2026-01-01T00:00:00Z" {
		t.Fatalf("stamps: %+v", got)
	}
	evs, _ := s.Events("p-01-a")
	if len(evs) != 1 || evs[0].Verb != "claim" {
		t.Fatalf("claim event: %+v", evs)
	}
}

func TestClaimTaskRefusesWhenDoingOccupied(t *testing.T) {
	s := open(t)
	seedInbox(t, s, "p-01-a", "any", "")
	seedInbox(t, s, "p-02-b", "any", "")
	if ok, _ := s.ClaimTask("p-01-a", "claude/any", "h", "2026-01-01T00:00:00Z"); !ok {
		t.Fatal("first claim must win")
	}
	_, err := s.ClaimTask("p-02-b", "claude/any", "h", "2026-01-01T00:01:00Z")
	if err != ErrDoingOccupied {
		t.Fatalf("second claim must hit ErrDoingOccupied: %v", err)
	}
}

func TestClaimTaskRacedAway(t *testing.T) {
	s := open(t)
	seedInbox(t, s, "p-01-a", "any", "")
	mustExec(t, s, `UPDATE tasks SET status='done' WHERE id='p-01-a'`)
	ok, err := s.ClaimTask("p-01-a", "claude/any", "h", "2026-01-01T00:00:00Z")
	if err != nil || ok {
		t.Fatalf("stale candidate must return ok=false: %v %v", ok, err)
	}
}

func TestClaimRaceTwoConnections(t *testing.T) {
	// Two Store handles on the same FILE = two SQLite connections, the
	// in-process stand-in for the two-process race (the real two-process proof
	// is in the process tier). Exactly one winner per round, every round.
	for round := 0; round < 10; round++ {
		path := filepath.Join(t.TempDir(), "race.db")
		a, err := Open(path)
		if err != nil {
			t.Fatal(err)
		}
		b, err := Open(path)
		if err != nil {
			t.Fatal(err)
		}
		seedInbox(t, a, "p-01-a", "any", "")

		var wg sync.WaitGroup
		results := make([]bool, 2)
		errs := make([]error, 2)
		for i, st := range []*Store{a, b} {
			wg.Add(1)
			go func(i int, st *Store) {
				defer wg.Done()
				results[i], errs[i] = st.ClaimTask("p-01-a", "racer", "h", "2026-01-01T00:00:00Z")
			}(i, st)
		}
		wg.Wait()
		wins := 0
		for i := range results {
			if errs[i] != nil && errs[i] != ErrDoingOccupied {
				t.Fatalf("round %d racer %d: %v", round, i, errs[i])
			}
			if results[i] {
				wins++
			}
		}
		if wins != 1 {
			t.Fatalf("round %d: %d winners", round, wins)
		}
		a.Close()
		b.Close()
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/store`
Expected: FAIL (undefined: NextEligible, ClaimTask, ErrDoingOccupied).

- [ ] **Step 3: Implement**

`internal/store/claim.go`:

```go
package store

import (
	"errors"
	"strings"
	"time"
)

// ErrDoingOccupied - one executor per checkout (D18): a doing row exists.
var ErrDoingOccupied = errors.New("doing occupied")

// NextEligible peeks the lowest-id inbox task for this session identity.
// Tier pinning is equality (Authority note 12); a task with harness '' accepts
// any harness. Read-only: the caller runs its slow checks (git dirty scan,
// HEAD card read) against this candidate, then calls ClaimTask.
func (s *Store) NextEligible(tier, harness string) (*Task, error) {
	return scanTask(s.db.QueryRow(`SELECT `+taskCols+` FROM tasks
		WHERE status = 'inbox' AND tier = ? AND (harness = '' OR harness = ?)
		ORDER BY id LIMIT 1`, tier, harness))
}

// ClaimTask atomically claims the given candidate: BEGIN IMMEDIATE, re-check
// the doing invariant, guarded UPDATE (status still inbox), claim event,
// COMMIT. Returns (false, nil) when the candidate was raced away or changed
// status - the caller loops back to NextEligible. Nothing slow runs inside
// the transaction (spec section 4).
func (s *Store) ClaimTask(id, claimedBy, headAtClaim, now string) (bool, error) {
	if err := s.beginImmediate(); err != nil {
		return false, err
	}
	rollback := func() { s.db.Exec("ROLLBACK") }

	var doing int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM tasks WHERE status = 'doing'`).Scan(&doing); err != nil {
		rollback()
		return false, err
	}
	if doing > 0 {
		rollback()
		return false, ErrDoingOccupied
	}
	res, err := s.db.Exec(`UPDATE tasks SET status = 'doing', claimed_at = ?, claimed_by = ?, head_at_claim = ?
		WHERE id = ? AND status = 'inbox'`, now, claimedBy, headAtClaim, id)
	if err != nil {
		rollback()
		return false, err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		rollback()
		return false, nil
	}
	if err := appendEventOn(s.db, id, claimedBy, "claim", "", now); err != nil {
		rollback()
		return false, err
	}
	if _, err := s.db.Exec("COMMIT"); err != nil {
		rollback()
		return false, err
	}
	return true, nil
}

// beginImmediate takes the write lock up front so the select-then-update pair
// cannot interleave with another writer. SetMaxOpenConns(1) guarantees every
// statement between BEGIN and COMMIT runs on this same connection. Retries
// cover SQLITE_BUSY beyond busy_timeout (the losing racer waits, then wins the
// lock after the winner commits and simply finds the row already doing).
func (s *Store) beginImmediate() error {
	var err error
	for i := 0; i < 5; i++ {
		if _, err = s.db.Exec("BEGIN IMMEDIATE"); err == nil {
			return nil
		}
		if !strings.Contains(err.Error(), "locked") && !strings.Contains(err.Error(), "busy") {
			return err
		}
		time.Sleep(100 * time.Millisecond)
	}
	return err
}
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/store`
Expected: PASS, including 10/10 race rounds with exactly one winner.

- [ ] **Step 5: Commit**

```bash
git add internal/store/claim.go internal/store/claim_test.go
git commit -m "feat(v2): atomic claim transaction with BEGIN IMMEDIATE + race test"
```

---

### Task 7: store - promote, dead-blocked, board counts

**Files:**
- Create: `internal/store/board.go`
- Create: `internal/store/board_test.go`

- [ ] **Step 1: Write the failing tests**

`internal/store/board_test.go`:

```go
package store

import (
	"reflect"
	"testing"
)

func TestPromoteLiftsOnlySatisfied(t *testing.T) {
	s := open(t)
	s.Ingest([]IngestTask{
		row("p-01-a", "impl", "any"),
		row("p-02-b", "impl", "any", "p-01-a"),
		row("p-03-c", "impl", "any", "p-02-b"),
	}, "shard", "2026-01-01T00:00:00Z")

	moved, err := s.Promote("system", "2026-01-01T00:01:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(moved, []string{"p-01-a"}) {
		t.Fatalf("moved: %v", moved)
	}
	moved, _ = s.Promote("system", "2026-01-01T00:02:00Z") // idempotent
	if len(moved) != 0 {
		t.Fatalf("second promote moved: %v", moved)
	}
	mustExec(t, s, `UPDATE tasks SET status='done' WHERE id='p-01-a'`)
	moved, _ = s.Promote("system", "2026-01-01T00:03:00Z")
	if !reflect.DeepEqual(moved, []string{"p-02-b"}) {
		t.Fatalf("after dep done: %v", moved)
	}
	got, _ := s.Task("p-03-c")
	if got.Status != "backlog" {
		t.Fatalf("p-03-c must stay blocked: %s", got.Status)
	}
}

func TestDeadBlocked(t *testing.T) {
	s := open(t)
	s.Ingest([]IngestTask{
		row("p-01-a", "impl", "any"),
		row("p-02-b", "impl", "any", "p-01-a"),
	}, "shard", "2026-01-01T00:00:00Z")
	mustExec(t, s, `UPDATE tasks SET status='failed' WHERE id='p-01-a'`)
	dead, err := s.DeadBlocked()
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(dead, []string{"p-02-b behind failed p-01-a"}) {
		t.Fatalf("dead: %v", dead)
	}
}

func TestBoardCounts(t *testing.T) {
	s := open(t)
	s.Ingest([]IngestTask{
		row("p-01-a", "impl", "any"),
		row("p-02-r", "review", "strong"),
		row("p-03-c", "impl", "any"),
		row("p-04-d", "impl", "any", "p-01-a"),
	}, "shard", "2026-01-01T00:00:00Z")
	mustExec(t, s, `UPDATE tasks SET status='inbox' WHERE id IN ('p-01-a','p-02-r')`)
	mustExec(t, s, `UPDATE tasks SET status='doing', claimed_at='2026-01-01T00:00:00Z',
		claimed_by='claude/any' WHERE id='p-03-c'`)
	b, err := s.Board()
	if err != nil {
		t.Fatal(err)
	}
	if b.InboxRun != 1 || b.InboxReview != 1 || b.Backlog != 1 || b.Done != 0 || b.Failed != 0 {
		t.Fatalf("counts: %+v", b)
	}
	if !reflect.DeepEqual(b.InboxIDs, []string{"p-01-a", "p-02-r"}) {
		t.Fatalf("inbox ids: %v", b.InboxIDs)
	}
	if len(b.Doing) != 1 || b.Doing[0].ID != "p-03-c" {
		t.Fatalf("doing: %+v", b.Doing)
	}
	if b.Total() != 4 {
		t.Fatalf("total: %d", b.Total())
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/store`
Expected: FAIL.

- [ ] **Step 3: Implement**

`internal/store/board.go`:

```go
package store

import "sort"

// Promote lifts every backlog task whose dependencies are all done (spec 4.4
// re-homed: a status flip, no file moves, no commit). Idempotent; one
// transaction; one promote event per lifted task. Returns lifted ids sorted.
func (s *Store) Promote(actor, now string) ([]string, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	rows, err := tx.Query(`SELECT id FROM tasks t WHERE status = 'backlog'
		AND NOT EXISTS (
			SELECT 1 FROM deps d JOIN tasks dt ON dt.id = d.depends_on
			WHERE d.task_id = t.id AND dt.status != 'done')
		ORDER BY id`)
	if err != nil {
		return nil, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, id := range ids {
		if _, err := tx.Exec(`UPDATE tasks SET status = 'inbox' WHERE id = ? AND status = 'backlog'`, id); err != nil {
			return nil, err
		}
		if err := appendEventOn(tx, id, actor, "promote", "", now); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	if ids == nil {
		ids = []string{}
	}
	sort.Strings(ids)
	return ids, nil
}

// DeadBlocked lists backlog tasks stuck behind a failed dependency (D12):
// "<id> behind failed <dep>", first failed dep per task, id order.
func (s *Store) DeadBlocked() ([]string, error) {
	rows, err := s.db.Query(`SELECT t.id, MIN(d.depends_on) FROM tasks t
		JOIN deps d ON d.task_id = t.id
		JOIN tasks f ON f.id = d.depends_on AND f.status = 'failed'
		WHERE t.status = 'backlog' GROUP BY t.id ORDER BY t.id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id, dep string
		if err := rows.Scan(&id, &dep); err != nil {
			return nil, err
		}
		out = append(out, id+" behind failed "+dep)
	}
	return out, rows.Err()
}

type BoardCounts struct {
	InboxRun, InboxReview, Backlog, Done, Failed int
	InboxIDs, FailedIDs                          []string
	Doing                                        []Task
	Dead                                         []string
}

func (b *BoardCounts) Total() int {
	return b.InboxRun + b.InboxReview + b.Backlog + b.Done + b.Failed + len(b.Doing)
}

// Board gathers everything the status block and board line print.
func (s *Store) Board() (*BoardCounts, error) {
	b := &BoardCounts{InboxIDs: []string{}, FailedIDs: []string{}}
	inbox, err := s.TasksByStatus("inbox")
	if err != nil {
		return nil, err
	}
	for _, t := range inbox {
		b.InboxIDs = append(b.InboxIDs, t.ID)
		if t.Tier == "strong" {
			b.InboxReview++
		} else {
			b.InboxRun++
		}
	}
	if b.Doing, err = s.Doing(); err != nil {
		return nil, err
	}
	for status, dst := range map[string]*int{"backlog": &b.Backlog, "done": &b.Done, "failed": &b.Failed} {
		ts, err := s.TasksByStatus(status)
		if err != nil {
			return nil, err
		}
		*dst = len(ts)
		if status == "failed" {
			for _, t := range ts {
				b.FailedIDs = append(b.FailedIDs, t.ID)
			}
		}
	}
	if b.Dead, err = s.DeadBlocked(); err != nil {
		return nil, err
	}
	return b, nil
}
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/store`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/store/board.go internal/store/board_test.go
git commit -m "feat(v2): promote/dead-blocked/board queries in the store"
```

---
### Task 8: verify - tokenizer, runner, transcript

**Files:**
- Create: `internal/verify/verify.go`
- Create: `internal/verify/verify_test.go`

Ports v1 `Split-CmdLine` + `Invoke-VerifyEntry` + `Invoke-VerifyBlock`. Direct process
spawn (argv, no shell), merged stdout+stderr, wall timeout, first-failure stop,
transcript format identical to v1 spec 3.2. v2 additions: HEAD is passed IN (the
package stays git-free), per-entry output is capped at 64 KB with an
`[output truncated]` marker (spec layout: verify.log size-capped). No SkipHeader
mode: v2 has no attempt-marker commit, so the block always writes its own header.

- [ ] **Step 1: Write the failing tests**

`internal/verify/verify_test.go`:

```go
package verify

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"muster/internal/card"
)

func TestSplitCmdLine(t *testing.T) {
	toks, err := SplitCmdLine(`dotnet test "My Tests/X.csproj" -v q`)
	if err != nil || len(toks) != 4 || toks[2] != "My Tests/X.csproj" {
		t.Fatalf("%v %v", toks, err)
	}
	if _, err := SplitCmdLine(`echo "oops`); err == nil {
		t.Fatal("unbalanced quote must error")
	}
}

func block(t *testing.T, entries []card.VerifyEntry) (Result, string) {
	t.Helper()
	if runtime.GOOS != "windows" {
		t.Skip("runner tests are Windows-first (spec)")
	}
	dir := t.TempDir()
	log := filepath.Join(dir, "t.verify.log")
	r, err := RunBlock(entries, BlockOpts{
		WorkDir: dir, LogPath: log, Label: "attempt 1", TaskID: "t",
		Head: "abc123", NowIso: func() string { return "2026-01-01T00:00:00Z" },
	})
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(log)
	return r, string(raw)
}

func TestPassingBlockTranscript(t *testing.T) {
	r, raw := block(t, []card.VerifyEntry{
		{Cmd: "cmd /c echo hello", ExpectExit: "0", ExpectContains: "hello"},
	})
	if !r.Pass {
		t.Fatalf("pass: %+v", r)
	}
	for _, want := range []string{
		"=== attempt 1 | 2026-01-01T00:00:00Z | task t | HEAD abc123",
		"$ cmd /c echo hello",
		"exit 0 | expect_exit 0 -> OK | expect_contains \"hello\" -> OK",
		"=== attempt 1 result: PASS",
	} {
		if !strings.Contains(raw, want) {
			t.Fatalf("transcript missing %q in:\n%s", want, raw)
		}
	}
}

func TestFailStopsAtFirstEntry(t *testing.T) {
	r, raw := block(t, []card.VerifyEntry{
		{Cmd: "cmd /c exit 7", ExpectExit: "0"},
		{Cmd: "cmd /c echo second", ExpectExit: "0"},
	})
	if r.Pass {
		t.Fatal("must fail")
	}
	if !strings.Contains(r.FirstFail, "cmd /c exit 7") || !strings.Contains(r.FirstFail, "exit 7, expected 0") {
		t.Fatalf("first fail: %q", r.FirstFail)
	}
	if strings.Contains(raw, "echo second") {
		t.Fatal("second entry must not run")
	}
}

func TestMissingExecutableFailsEntry(t *testing.T) {
	r, raw := block(t, []card.VerifyEntry{{Cmd: "muster-no-such-exe", ExpectExit: "0"}})
	if r.Pass {
		t.Fatal("must fail")
	}
	if !strings.Contains(raw, "spawn failed") {
		t.Fatalf("transcript: %s", raw)
	}
}

func TestTimeoutKillsProcess(t *testing.T) {
	r, raw := block(t, []card.VerifyEntry{
		{Cmd: "cmd /c ping -n 30 127.0.0.1", ExpectExit: "0", TimeoutSeconds: "2"},
	})
	if r.Pass {
		t.Fatal("must fail")
	}
	if !strings.Contains(raw, "timeout 2s -> FAIL") {
		t.Fatalf("transcript: %s", raw)
	}
}

func TestOutputCap(t *testing.T) {
	// 200 lines of 1KB each exceeds the 64KB cap
	r, raw := block(t, []card.VerifyEntry{
		{Cmd: "cmd /c for /l %i in (1,1,200) do @echo " + strings.Repeat("x", 1024), ExpectExit: "0"},
	})
	_ = r
	if !strings.Contains(raw, "[output truncated]") {
		t.Fatal("cap marker missing")
	}
	if len(raw) > 80*1024 {
		t.Fatalf("log not capped: %d bytes", len(raw))
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/verify`
Expected: FAIL (undefined: SplitCmdLine, RunBlock).

- [ ] **Step 3: Implement**

`internal/verify/verify.go`:

```go
// Package verify runs a card's verify block: direct process spawn (argv, no
// shell interpretation anywhere), merged stdout+stderr, wall timeout, stop at
// first failing entry, v1-format transcript appended to the task's verify.log.
// Windows caveat carried from v1: extension-less .cmd/.bat shims (npm, ng)
// do not spawn directly - cards front them with `cmd /c`.
package verify

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"muster/internal/card"
)

const outputCap = 64 * 1024

type Result struct {
	Pass      bool
	FirstFail string
}

type BlockOpts struct {
	WorkDir string
	LogPath string
	Label   string // "attempt <n>" | "done-check" | "claim-probe"
	TaskID  string
	Head    string
	NowIso  func() string
}

// SplitCmdLine tokenizes one command line: whitespace-separated, double quotes
// group (v1 spec 2.4). Tokens go straight to exec.Command.
func SplitCmdLine(cmd string) ([]string, error) {
	var tokens []string
	var sb strings.Builder
	inQuote := false
	for _, ch := range cmd {
		switch {
		case ch == '"':
			inQuote = !inQuote
		case !inQuote && (ch == ' ' || ch == '\t'):
			if sb.Len() > 0 {
				tokens = append(tokens, sb.String())
				sb.Reset()
			}
		default:
			sb.WriteRune(ch)
		}
	}
	if inQuote {
		return nil, fmt.Errorf("unbalanced double quote in cmd: %s", cmd)
	}
	if sb.Len() > 0 {
		tokens = append(tokens, sb.String())
	}
	return tokens, nil
}

type entryResult struct {
	Output   string
	ExitCode int
	TimedOut bool
	Timeout  int
	SpawnErr string
}

func runEntry(e card.VerifyEntry, workDir string) entryResult {
	timeout := 300
	if e.TimeoutSeconds != "" {
		timeout, _ = strconv.Atoi(e.TimeoutSeconds)
	}
	tokens, err := SplitCmdLine(e.Cmd)
	if err != nil || len(tokens) == 0 {
		return entryResult{SpawnErr: fmt.Sprintf("spawn failed: %v", err), ExitCode: -1, Timeout: timeout}
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, tokens[0], tokens[1:]...)
	cmd.Dir = workDir
	out, err := cmd.CombinedOutput()
	res := entryResult{Output: string(out), Timeout: timeout, ExitCode: -1}
	if ctx.Err() == context.DeadlineExceeded {
		res.TimedOut = true
		return res
	}
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			res.ExitCode = ee.ExitCode()
			return res
		}
		res.SpawnErr = "spawn failed: " + err.Error()
		return res
	}
	res.ExitCode = cmd.ProcessState.ExitCode()
	return res
}

func appendLog(path, text string) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(text)
	return err
}

// RunBlock runs all entries in order, appending a transcript block to
// o.LogPath. Stops at the first failing entry.
func RunBlock(entries []card.VerifyEntry, o BlockOpts) (Result, error) {
	if err := appendLog(o.LogPath, fmt.Sprintf("=== %s | %s | task %s | HEAD %s\n",
		o.Label, o.NowIso(), o.TaskID, o.Head)); err != nil {
		return Result{}, err
	}
	pass := true
	firstFail := ""
	for _, e := range entries {
		if err := appendLog(o.LogPath, "$ "+e.Cmd+"\n"); err != nil {
			return Result{}, err
		}
		r := runEntry(e, o.WorkDir)
		body := r.Output
		if r.SpawnErr != "" {
			body = r.SpawnErr
		}
		if len(body) > outputCap {
			body = body[:outputCap] + "\n[output truncated]"
		}
		if strings.TrimSpace(body) != "" {
			appendLog(o.LogPath, strings.TrimRight(body, "\r\n")+"\n")
		}
		var parts, why []string
		ok := true
		if r.TimedOut {
			parts = append(parts, fmt.Sprintf("timeout %ds -> FAIL", r.Timeout))
			why = append(why, fmt.Sprintf("timed out after %ds", r.Timeout))
			ok = false
		} else {
			parts = append(parts, fmt.Sprintf("exit %d", r.ExitCode))
			if e.ExpectExit != "" {
				want, _ := strconv.Atoi(e.ExpectExit)
				if want == r.ExitCode {
					parts = append(parts, fmt.Sprintf("expect_exit %s -> OK", e.ExpectExit))
				} else {
					parts = append(parts, fmt.Sprintf("expect_exit %s -> FAIL", e.ExpectExit))
					why = append(why, fmt.Sprintf("exit %d, expected %s", r.ExitCode, e.ExpectExit))
					ok = false
				}
			}
			if e.ExpectContains != "" {
				if strings.Contains(r.Output, e.ExpectContains) {
					parts = append(parts, fmt.Sprintf("expect_contains %q -> OK", e.ExpectContains))
				} else {
					parts = append(parts, fmt.Sprintf("expect_contains %q -> MISSING", e.ExpectContains))
					why = append(why, fmt.Sprintf("output missing %q", e.ExpectContains))
					ok = false
				}
			}
		}
		if err := appendLog(o.LogPath, strings.Join(parts, " | ")+"\n"); err != nil {
			return Result{}, err
		}
		if !ok {
			pass = false
			firstFail = e.Cmd + ": " + strings.Join(why, "; ")
			break
		}
	}
	verdict := "FAIL"
	if pass {
		verdict = "PASS"
	}
	if err := appendLog(o.LogPath, fmt.Sprintf("=== %s result: %s\n", o.Label, verdict)); err != nil {
		return Result{}, err
	}
	return Result{Pass: pass, FirstFail: firstFail}, nil
}
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/verify`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/verify/verify.go internal/verify/verify_test.go
git commit -m "feat(v2): verify runner - tokenizer, direct spawn, capped transcript"
```

---

### Task 9: gitx - the Git seam (interface, real impl, fake)

**Files:**
- Create: `internal/gitx/gitx.go`
- Create: `internal/gitx/fake.go`
- Create: `internal/gitx/gitx_test.go`

The interface is exactly the git surface the verbs need - nothing more. The real
implementation shells out to git (covered by the process tier, NOT unit-tested);
the fake backs every cli unit test. The porcelain parser is pure and unit-tested.

- [ ] **Step 1: Write the failing tests**

`internal/gitx/gitx_test.go`:

```go
package gitx

import (
	"reflect"
	"testing"
)

func TestFakeImplementsGit(t *testing.T) {
	var _ Git = (*Fake)(nil)
}

func TestParsePorcelain(t *testing.T) {
	lines := []string{
		" M src/app.go",
		"?? new dir/file.txt",
		`R  "old name.txt" -> "new name.txt"`,
		"",
	}
	got := ParsePorcelain(lines)
	want := []string{"src/app.go", "new dir/file.txt", "old name.txt", "new name.txt"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
}

func TestFakeShowAtHead(t *testing.T) {
	f := &Fake{HeadFiles: map[string]string{".muster/cards/x.md": "body"}}
	got, err := f.ShowAtHead(".muster/cards/x.md")
	if err != nil || got != "body" {
		t.Fatalf("%q %v", got, err)
	}
	if _, err := f.ShowAtHead("missing"); err == nil {
		t.Fatal("missing path must error")
	}
}

func TestFakeCommitRecordsAndMutates(t *testing.T) {
	f := &Fake{HeadSHA: "h1"}
	mutated := false
	f.MutateOnCommit = func(g *Fake) { mutated = true; g.Dirty = []string{"src/app.go"} }
	if err := f.Commit("muster(p): done x", []string{"a", "b"}); err != nil {
		t.Fatal(err)
	}
	if len(f.Commits) != 1 || f.Commits[0].Msg != "muster(p): done x" || !mutated {
		t.Fatalf("%+v", f.Commits)
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/gitx`
Expected: FAIL.

- [ ] **Step 3: Implement**

`internal/gitx/gitx.go`:

```go
// Package gitx is the one seam between MUSTER and git. Reads dominate; the
// only writes are Add/Commit/AmendNoEdit, used exclusively by done and init.
package gitx

import (
	"fmt"
	"os/exec"
	"strings"
)

type Git interface {
	Head() (string, error)
	Branch() (string, error)
	IsAncestor(ancestor, descendant string) (bool, error)
	ShowAtHead(relPath string) (string, error) // errors when absent at HEAD
	DirtyPaths() ([]string, error)             // worktree+index, untracked=all, rename both sides
	DiffNamesSince(commit string) ([]string, error)
	Untracked() ([]string, error)
	Add(paths []string) error
	Commit(msg string, paths []string) error // explicit pathspec, -c core.autocrlf=false
	AmendNoEdit() error
	LogGrep(grep, rangeSpec string) ([]string, error) // commit SHAs, newest first
	UserConfigured() (bool, error)
}

// FindRoot resolves the repo root from dir, or an error outside a repository.
func FindRoot(dir string) (string, error) {
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", fmt.Errorf("not inside a git repository")
	}
	return strings.TrimSpace(string(out)), nil
}

// Repo is the real implementation, rooted at Dir.
type Repo struct{ Dir string }

func (r *Repo) git(args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", r.Dir}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("git %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

func (r *Repo) lines(args ...string) ([]string, error) {
	out, err := r.git(args...)
	if err != nil {
		return nil, err
	}
	var res []string
	for _, l := range strings.Split(out, "\n") {
		if strings.TrimRight(l, "\r") != "" {
			res = append(res, strings.TrimRight(l, "\r"))
		}
	}
	return res, nil
}

func (r *Repo) Head() (string, error) {
	out, err := r.git("rev-parse", "HEAD")
	return strings.TrimSpace(out), err
}

func (r *Repo) Branch() (string, error) {
	out, err := r.git("rev-parse", "--abbrev-ref", "HEAD")
	return strings.TrimSpace(out), err
}

func (r *Repo) IsAncestor(ancestor, descendant string) (bool, error) {
	cmd := exec.Command("git", "-C", r.Dir, "merge-base", "--is-ancestor", ancestor, descendant)
	err := cmd.Run()
	if err == nil {
		return true, nil
	}
	if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 1 {
		return false, nil
	}
	return false, err
}

func (r *Repo) ShowAtHead(relPath string) (string, error) {
	return r.git("show", "HEAD:"+relPath)
}

func (r *Repo) DirtyPaths() ([]string, error) {
	ls, err := r.lines("status", "--porcelain", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	return ParsePorcelain(ls), nil
}

func (r *Repo) DiffNamesSince(commit string) ([]string, error) {
	return r.lines("-c", "core.autocrlf=false", "diff", "--name-only", commit)
}

func (r *Repo) Untracked() ([]string, error) {
	return r.lines("ls-files", "--others", "--exclude-standard")
}

func (r *Repo) Add(paths []string) error {
	_, err := r.git(append([]string{"-c", "core.autocrlf=false", "add", "--"}, paths...)...)
	return err
}

func (r *Repo) Commit(msg string, paths []string) error {
	_, err := r.git(append([]string{"-c", "core.autocrlf=false", "commit", "-q", "-m", msg, "--"}, paths...)...)
	return err
}

func (r *Repo) AmendNoEdit() error {
	_, err := r.git("-c", "core.autocrlf=false", "commit", "-q", "--amend", "--no-edit")
	return err
}

func (r *Repo) LogGrep(grep, rangeSpec string) ([]string, error) {
	return r.lines("log", "--format=%H", "--grep", grep, rangeSpec)
}

func (r *Repo) UserConfigured() (bool, error) {
	for _, key := range []string{"user.name", "user.email"} {
		out, err := exec.Command("git", "-C", r.Dir, "config", key).Output()
		if err != nil || strings.TrimSpace(string(out)) == "" {
			return false, nil
		}
	}
	return true, nil
}

// ParsePorcelain converts `status --porcelain` lines to repo-relative paths.
// Rename lines yield both sides; surrounding quotes are stripped.
func ParsePorcelain(lines []string) []string {
	var paths []string
	for _, line := range lines {
		if len(line) < 4 {
			continue
		}
		p := line[3:]
		if i := strings.Index(p, " -> "); i >= 0 {
			paths = append(paths, strings.Trim(p[:i], `"`), strings.Trim(p[i+4:], `"`))
			continue
		}
		paths = append(paths, strings.Trim(p, `"`))
	}
	return paths
}
```

`internal/gitx/fake.go`:

```go
package gitx

import "fmt"

type FakeCommit struct {
	Msg   string
	Paths []string
}

// Fake is the unit-tier Git double. Zero value is usable; tests set fields.
type Fake struct {
	HeadSHA, BranchName string
	AncestorOK          bool
	HeadFiles           map[string]string
	Dirty               []string
	DiffSince           []string
	UntrackedList       []string
	Added               [][]string
	Commits             []FakeCommit
	Amends              int
	CommitErr           error
	GrepSHAs            []string
	UserOK              bool
	// MutateOnCommit simulates a tree-mutating hook: runs after a successful Commit.
	MutateOnCommit func(*Fake)
}

func (f *Fake) Head() (string, error)   { return f.HeadSHA, nil }
func (f *Fake) Branch() (string, error) { return f.BranchName, nil }
func (f *Fake) IsAncestor(a, d string) (bool, error) {
	return f.AncestorOK, nil
}
func (f *Fake) ShowAtHead(rel string) (string, error) {
	if body, ok := f.HeadFiles[rel]; ok {
		return body, nil
	}
	return "", fmt.Errorf("path %s does not exist at HEAD", rel)
}
func (f *Fake) DirtyPaths() ([]string, error)   { return f.Dirty, nil }
func (f *Fake) DiffNamesSince(string) ([]string, error) { return f.DiffSince, nil }
func (f *Fake) Untracked() ([]string, error)    { return f.UntrackedList, nil }
func (f *Fake) Add(paths []string) error {
	f.Added = append(f.Added, paths)
	return nil
}
func (f *Fake) Commit(msg string, paths []string) error {
	if f.CommitErr != nil {
		return f.CommitErr
	}
	f.Commits = append(f.Commits, FakeCommit{Msg: msg, Paths: paths})
	if f.MutateOnCommit != nil {
		f.MutateOnCommit(f)
	}
	return nil
}
func (f *Fake) AmendNoEdit() error {
	// Real amend folds the staged re-add into the commit, leaving the tree
	// clean - mirror that so the hook re-stage cycle terminates in tests.
	f.Amends++
	f.Dirty = nil
	return nil
}
func (f *Fake) LogGrep(grep, rangeSpec string) ([]string, error) {
	return f.GrepSHAs, nil
}
func (f *Fake) UserConfigured() (bool, error) { return f.UserOK, nil }
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/gitx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/gitx/gitx.go internal/gitx/fake.go internal/gitx/gitx_test.go
git commit -m "feat(v2): gitx seam - interface, exec implementation, unit-tier fake"
```

---
### Task 10: card - lint (full / lite / single)

**Files:**
- Create: `internal/card/lint.go`
- Create: `internal/card/lint_test.go`

Ports v1 `Test-LintChecks` 1-14 with v2 re-homing: the collision scan and the
depends-on-exists scan query the DB through a resolver callback instead of walking
folders. Check numbering is kept in comments for traceability to v1/spec 2.6.
Modes: **Full** (shard batch: all checks incl. batch checks 11-12), **Lite**
(staged fix: per-file checks, fix filename pattern, no batch checks), **Single**
(reimport: per-file checks, normal filename pattern, no batch checks).

- [ ] **Step 1: Write the failing tests**

`internal/card/lint_test.go`:

```go
package card

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeCard writes text to dir/name and returns the path.
func writeCard(t *testing.T, dir, name, text string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func implCard(id, extra string) string {
	// commit_paths carries the bare `internal/w` entry so the verify token
	// passes lint check 5 - the exact convention the sharding notes mandate.
	return `---
id: ` + id + `
plan: demo
type: impl
tier: any
depends_on: []
protected:
  - internal/w/w_test.go
commit_paths:
  - internal/w/w.go
  - internal/w/w_test.go
  - internal/w
` + extra + `verify:
  - cmd: go test internal/w
    expect_exit: 0
---
# ` + id + `: title

## Context
ctx

## Steps
1. do the thing

## Acceptance
- it works
`
}

func integrationCard(id string, deps []string) string {
	depBlock := "depends_on:\n"
	for _, d := range deps {
		depBlock += "  - " + d + "\n"
	}
	return `---
id: ` + id + `
plan: demo
type: integration
tier: strong
` + depBlock + `verify:
  - cmd: go vet all
    expect_exit: 0
---
# ` + id + `: integrate

## Context
ctx

## Steps
1. run the suite

## Acceptance
- green
`
}

func noExisting(string) bool { return false }

func lintBatch(t *testing.T, dir string, texts map[string]string, exists func(string) bool, mode Mode) []string {
	t.Helper()
	var paths []string
	for name, text := range texts {
		paths = append(paths, writeCard(t, dir, name, text))
	}
	return Lint(paths, exists, mode)
}

func wantFinding(t *testing.T, findings []string, frag string) {
	t.Helper()
	for _, f := range findings {
		if strings.Contains(f, frag) {
			return
		}
	}
	t.Fatalf("findings %v lack %q", findings, frag)
}

func TestWellFormedBatchPasses(t *testing.T) {
	dir := t.TempDir()
	f := lintBatch(t, dir, map[string]string{
		"demo-01-w.md": implCard("demo-01-w", ""),
		"demo-99-int.md": integrationCard("demo-99-int", []string{"demo-01-w"}),
	}, noExisting, Full)
	if len(f) != 0 {
		t.Fatalf("findings: %v", f)
	}
}

func TestIDStemAndPattern(t *testing.T) {
	dir := t.TempDir()
	f := lintBatch(t, dir, map[string]string{"other-name.md": implCard("demo-01-w", "")}, noExisting, Single)
	wantFinding(t, f, "does not equal filename stem")
	f = lintBatch(t, dir, map[string]string{"demow.md": implCard("demow", "")}, noExisting, Single)
	wantFinding(t, f, "does not match the task pattern")
}

func TestCollisionAgainstBoard(t *testing.T) {
	dir := t.TempDir()
	f := lintBatch(t, dir, map[string]string{"demo-01-w.md": implCard("demo-01-w", "")},
		func(id string) bool { return id == "demo-01-w" }, Single)
	wantFinding(t, f, "already on the board")
}

func TestDepExistsNowhere(t *testing.T) {
	dir := t.TempDir()
	text := strings.Replace(implCard("demo-01-w", ""), "depends_on: []", "depends_on:\n  - ghost-01-x", 1)
	f := lintBatch(t, dir, map[string]string{"demo-01-w.md": text}, noExisting, Single)
	wantFinding(t, f, "depends_on 'ghost-01-x' exists nowhere")
}

func TestVerifyCmdChecks(t *testing.T) {
	dir := t.TempDir()
	meta := strings.Replace(implCard("demo-01-w", ""), "cmd: go test internal/w", "cmd: go test internal/w | sort", 1)
	f := lintBatch(t, dir, map[string]string{"demo-01-w.md": meta}, noExisting, Single)
	wantFinding(t, f, "shell metacharacters")

	net := strings.Replace(implCard("demo-01-w", ""), "cmd: go test internal/w", "cmd: curl example.com", 1)
	f = lintBatch(t, dir, map[string]string{"demo-01-w.md": net}, noExisting, Single)
	wantFinding(t, f, "needs network but harness is not claude")

	// harness: claude exempts the network check
	netOK := strings.Replace(net, "plan: demo\n", "plan: demo\nharness: claude\n", 1)
	f = lintBatch(t, dir, map[string]string{"demo-01-w.md": netOK}, noExisting, Single)
	for _, x := range f {
		if strings.Contains(x, "needs network") {
			t.Fatalf("claude harness must exempt: %v", f)
		}
	}

	unlisted := strings.Replace(implCard("demo-01-w", ""), "cmd: go test internal/w", "cmd: go test other/pkg", 1)
	f = lintBatch(t, dir, map[string]string{"demo-01-w.md": unlisted}, noExisting, Single)
	wantFinding(t, f, "verify path 'other/pkg' not in protected or commit_paths")
}

func TestTestPathOnlyInCommitPaths(t *testing.T) {
	dir := t.TempDir()
	// verify cmd names the test file itself; protected is empty so the test
	// file resolves only through commit_paths = executor-writable grader (M2)
	text := strings.NewReplacer(
		"protected:\n  - internal/w/w_test.go", "protected: []",
		"cmd: go test internal/w", "cmd: go test internal/w/w_test.go",
	).Replace(implCard("demo-01-w", ""))
	f := lintBatch(t, dir, map[string]string{"demo-01-w.md": text}, noExisting, Single)
	wantFinding(t, f, "only in commit_paths - executor-writable grader")
	// and check 14: runner with empty protected
	wantFinding(t, f, "verify runs a test runner but protected is empty")
}

func TestProseChecks(t *testing.T) {
	dir := t.TempDir()
	cases := []struct{ orig, repl, frag string }{
		{"## Context\nctx", "## Context\nTBD", "placeholder text"},
		{"## Steps\n1. do the thing", "## Steps\n1. do the thing as appropriate", "judgment language in Steps"},
		{"## Context\nctx\n", "## Context\nsee docs/plan.md\n", "un-inlined reference"},
	}
	for _, tc := range cases {
		text := strings.Replace(implCard("demo-01-w", ""), tc.orig, tc.repl, 1)
		f := lintBatch(t, dir, map[string]string{"demo-01-w.md": text}, noExisting, Single)
		wantFinding(t, f, tc.frag)
	}
}

func TestHeadingOrderAndSizeCap(t *testing.T) {
	dir := t.TempDir()
	noSteps := strings.Replace(implCard("demo-01-w", ""), "## Steps", "## Stuff", 1)
	f := lintBatch(t, dir, map[string]string{"demo-01-w.md": noSteps}, noExisting, Single)
	wantFinding(t, f, "body headings missing or out of order")

	big := implCard("demo-01-w", "") + strings.Repeat("filler line\n", 300)
	f = lintBatch(t, dir, map[string]string{"demo-01-w.md": big}, noExisting, Single)
	wantFinding(t, f, "over the size cap")
}

func TestBatchChecksFullMode(t *testing.T) {
	dir := t.TempDir()
	// no integration task
	f := lintBatch(t, dir, map[string]string{"demo-01-w.md": implCard("demo-01-w", "")}, noExisting, Full)
	wantFinding(t, f, "expected exactly 1 integration task, found 0")
	// integration missing a batch dep
	f = lintBatch(t, dir, map[string]string{
		"demo-01-w.md": implCard("demo-01-w", ""),
		"demo-02-x.md": strings.NewReplacer("demo-01-w", "demo-02-x").Replace(implCard("demo-01-w", "")),
		"demo-99-int.md": integrationCard("demo-99-int", []string{"demo-01-w"}),
	}, noExisting, Full)
	wantFinding(t, f, "integration depends_on missing 'demo-02-x'")
}

func TestReviewWiring(t *testing.T) {
	dir := t.TempDir()
	review := `---
id: demo-02-review-w
plan: demo
type: review
tier: strong
reviews: demo-01-w
depends_on:
  - demo-01-w
verify:
  - cmd: go vet all
    expect_exit: 0
---
# demo-02-review-w: review

## Context
ctx

## Steps
1. judge

## Acceptance
- verdict filed
`
	f := lintBatch(t, dir, map[string]string{
		"demo-01-w.md":         implCard("demo-01-w", ""),
		"demo-02-review-w.md":  review,
		"demo-99-int.md":       integrationCard("demo-99-int", []string{"demo-01-w", "demo-02-review-w"}),
	}, noExisting, Full)
	if len(f) != 0 {
		t.Fatalf("wired review must pass: %v", f)
	}
	broken := strings.Replace(review, "depends_on:\n  - demo-01-w", "depends_on: []", 1)
	f = lintBatch(t, dir, map[string]string{
		"demo-01-w.md":        implCard("demo-01-w", ""),
		"demo-02-review-w.md": broken,
		"demo-99-int.md":      integrationCard("demo-99-int", []string{"demo-01-w", "demo-02-review-w"}),
	}, noExisting, Full)
	wantFinding(t, f, "review depends_on must include its reviews id")
}

func TestLiteMode(t *testing.T) {
	dir := t.TempDir()
	fix := `---
id: demo-01-fix-w
plan: demo
type: fix
tier: any
fixes: demo-01-w
depends_on: []
protected:
  - internal/w/w_test.go
commit_paths:
  - internal/w/w.go
  - internal/w
verify:
  - cmd: go test internal/w
    expect_exit: 0
---
# demo-01-fix-w: fix

## Context
ctx

## Steps
1. fix it

## Acceptance
- green
`
	// lite skips batch checks and accepts the fix filename pattern; the fixes
	// target exists on the board
	f := lintBatch(t, dir, map[string]string{"demo-01-fix-w.md": fix},
		func(id string) bool { return id == "demo-01-w" }, Lite)
	if len(f) != 0 {
		t.Fatalf("staged fix must pass lite: %v", f)
	}
	// lite enforces the fix filename pattern
	notFix := strings.NewReplacer("demo-01-fix-w", "demo-01-w", "type: fix\n", "type: impl\n", "fixes: demo-01-w\n", "").Replace(fix)
	f = lintBatch(t, dir, map[string]string{"demo-01-w.md": notFix}, noExisting, Lite)
	wantFinding(t, f, "does not match the task pattern")
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/card`
Expected: FAIL (undefined: Lint, Mode).

- [ ] **Step 3: Implement**

`internal/card/lint.go`:

```go
package card

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type Mode int

const (
	Full   Mode = iota // shard batch: all checks including batch checks 11-12
	Lite               // staged fix: per-file checks, fix filename pattern
	Single             // reimport: per-file checks, normal filename pattern
)

var (
	namePat    = regexp.MustCompile(`^[a-z0-9-]+-\d{2}-[a-z0-9-]+$`)
	fixNamePat = regexp.MustCompile(`^[a-z0-9-]+-\d{2}-fix-[a-z0-9-]+$`)
	metaRx     = regexp.MustCompile("[|><;`]|\\$\\(|&&")
	netRx      = regexp.MustCompile(`(^|\s)(curl|wget|nuget|iwr|Invoke-WebRequest)(\s|$)|git (fetch|pull|push)|npm (install|ci)|dotnet restore|pip install`)
	runnerRx   = regexp.MustCompile(`(^|\s)(npm|pnpm|yarn) test(\s|$)|(^|\s)dotnet test(\s|$)|(^|\s)pytest(\s|$)|(^|\s)go test(\s|$)|(^|\s)cargo test(\s|$)|(^|\s)Invoke-Pester(\s|$)|(^|\s)ctest(\s|$)|(^|\s)(vitest|jest|mocha|rspec|phpunit)(\s|$)`)
	testPathRx = regexp.MustCompile(`(?i)(^|/)tests?/|\.tests?\.|_test\.|\.spec\.`)
	cmdSwitch  = regexp.MustCompile(`^/[a-zA-Z]$`)
	stepsRx    = regexp.MustCompile(`(?s)## Steps(.*?)(## Acceptance|$)`)
	headingsRx = regexp.MustCompile(`(?s)# .+?## Context.+?## Steps.+?## Acceptance`)
	numDotsRx  = regexp.MustCompile(`(?m)^\s*\d+\.\s*\.\.\.\s*$`)
	braceSlot  = regexp.MustCompile(`\{[a-z][a-z0-9 ,:.-]*\}`)
)

var placeholderLits = []string{"TBD", "TODO", "FIXME", "<fill", "{placeholder", "{...}"}
var uninlinedLits = []string{"see docs/", "refer to", "as described in", "per the plan"}
var judgmentLits = []string{"if needed", "as appropriate", "appropriately", "handle edge cases"}

// pathListed: path equals a list entry or sits under a listed directory.
func pathListed(path string, list []string) bool {
	for _, c := range list {
		if path == c || strings.HasPrefix(path, strings.TrimRight(c, "/")+"/") {
			return true
		}
	}
	return false
}

// Lint checks the batch of card files. exists reports whether an id is already
// on the board (DB resolver; replaces v1's folder scans). Findings are
// "<filename>: <message>" strings; empty means clean.
func Lint(paths []string, exists func(id string) bool, mode Mode) []string {
	var findings []string
	type parsed struct {
		c    *Card
		errs []string
		name string
		raw  string
	}
	var batch []parsed
	batchIDs := map[string]bool{}
	for _, p := range paths {
		name := filepath.Base(p)
		raw, err := os.ReadFile(p)
		if err != nil {
			findings = append(findings, name+": file not found")
			continue
		}
		c, errs := Parse(string(raw), mode == Lite)
		batch = append(batch, parsed{c: c, errs: errs, name: name, raw: string(raw)})
		if c.ID != "" {
			batchIDs[c.ID] = true
		}
	}

	for _, t := range batch {
		pfx := t.name
		stem := strings.TrimSuffix(t.name, ".md")

		// 1. frontmatter parses + schema per type
		if len(t.errs) > 0 {
			for _, e := range t.errs {
				findings = append(findings, pfx+": "+e)
			}
			if t.c.Type == "" {
				continue
			}
		}
		c := t.c

		// 2. id = stem; filename pattern; collision against board + batch dupes
		if c.ID != stem {
			findings = append(findings, fmt.Sprintf("%s: id '%s' does not equal filename stem", pfx, c.ID))
		}
		pat := namePat
		if mode == Lite {
			pat = fixNamePat
		}
		if !pat.MatchString(stem) {
			findings = append(findings, pfx+": filename does not match the task pattern (spec 2.1)")
		}
		if exists(c.ID) {
			findings = append(findings, fmt.Sprintf("%s: id '%s' already on the board", pfx, c.ID))
		}
		dupes := 0
		for _, o := range batch {
			if o.c.ID == c.ID {
				dupes++
			}
		}
		if dupes > 1 {
			findings = append(findings, fmt.Sprintf("%s: id '%s' duplicated in batch", pfx, c.ID))
		}

		// 3. every depends_on exists in batch or on the board (fail closed)
		for _, dep := range c.DependsOn {
			if !batchIDs[dep] && !exists(dep) {
				findings = append(findings, fmt.Sprintf("%s: depends_on '%s' exists nowhere", pfx, dep))
			}
		}

		// 4 + 5. verify cmd checks
		listed := append(append([]string{}, c.Protected...), c.CommitPaths...)
		runsTests := false
		for _, en := range c.Verify {
			if metaRx.MatchString(en.Cmd) {
				findings = append(findings, pfx+": verify cmd has shell metacharacters: "+en.Cmd)
			}
			if netRx.MatchString(en.Cmd) && c.Harness != "claude" {
				findings = append(findings, pfx+": verify cmd needs network but harness is not claude: "+en.Cmd)
			}
			if runnerRx.MatchString(en.Cmd) {
				runsTests = true
			}
			if c.Type == "impl" || c.Type == "fix" {
				toks, err := tokenizeForLint(en.Cmd)
				if err != nil {
					findings = append(findings, pfx+": verify cmd unparseable (unbalanced quote): "+en.Cmd)
				}
				for _, tok := range toks {
					if !strings.Contains(tok, "/") || strings.HasPrefix(tok, "-") || cmdSwitch.MatchString(tok) {
						continue
					}
					if !pathListed(tok, listed) {
						findings = append(findings, fmt.Sprintf("%s: verify path '%s' not in protected or commit_paths", pfx, tok))
						continue
					}
					// 5b (M2): a test-looking path satisfied only by commit_paths
					if testPathRx.MatchString(tok) && !pathListed(tok, c.Protected) {
						findings = append(findings, fmt.Sprintf("%s: verify test path '%s' only in commit_paths - executor-writable grader; move it to protected", pfx, tok))
					}
				}
			}
		}

		// 6. size cap
		if len(strings.Split(t.raw, "\n")) > 300 || len(t.raw) > 16*1024 {
			findings = append(findings, pfx+": over the size cap (300 lines / 16 KB) - reshard")
		}
		// 7. placeholders
		phFound := false
		for _, lit := range placeholderLits {
			if strings.Contains(t.raw, lit) {
				findings = append(findings, fmt.Sprintf("%s: placeholder text matches '%s'", pfx, lit))
				phFound = true
				break
			}
		}
		if !phFound && (braceSlot.MatchString(t.raw) || numDotsRx.MatchString(t.raw)) {
			findings = append(findings, pfx+": placeholder text matches a template-brace or dotted-step pattern")
		}
		// 8. un-inlined references
		for _, lit := range uninlinedLits {
			if strings.Contains(t.raw, lit) {
				findings = append(findings, fmt.Sprintf("%s: un-inlined reference ('%s')", pfx, lit))
				break
			}
		}
		// 9. judgment language in Steps
		if m := stepsRx.FindStringSubmatch(t.raw); m != nil {
			for _, lit := range judgmentLits {
				if strings.Contains(m[1], lit) {
					findings = append(findings, fmt.Sprintf("%s: judgment language in Steps ('%s')", pfx, lit))
					break
				}
			}
		}
		// 10. heading order
		if !headingsRx.MatchString(t.raw) {
			findings = append(findings, pfx+": body headings missing or out of order (Context, Steps, Acceptance)")
		}
		// 13. commit_paths non-empty on impl/fix
		if (c.Type == "impl" || c.Type == "fix") && len(c.CommitPaths) == 0 {
			findings = append(findings, pfx+": commit_paths empty")
		}
		// 14. runner without protected = delete-the-test pass linting clean (M2)
		if (c.Type == "impl" || c.Type == "fix") && runsTests && len(c.Protected) == 0 {
			findings = append(findings, pfx+": verify runs a test runner but protected is empty - tests are executor-writable")
		}
	}

	if mode == Full {
		// 11. exactly one integration task: seq 99, strong, depends on every other batch id
		var ints []parsed
		for _, t := range batch {
			if len(t.errs) == 0 && t.c.Type == "integration" {
				ints = append(ints, t)
			}
		}
		if len(ints) != 1 {
			findings = append(findings, fmt.Sprintf("batch: expected exactly 1 integration task, found %d", len(ints)))
		} else {
			in := ints[0].c
			if in.Seq != 99 {
				findings = append(findings, in.ID+".md: integration task must use seq 99")
			}
			if in.Tier != "strong" {
				findings = append(findings, in.ID+".md: integration task must be tier: strong")
			}
			depSet := map[string]bool{}
			for _, d := range in.DependsOn {
				depSet[d] = true
			}
			for id := range batchIDs {
				if id != in.ID && !depSet[id] {
					findings = append(findings, fmt.Sprintf("%s.md: integration depends_on missing '%s'", in.ID, id))
				}
			}
		}
		// 12. review wiring
		for _, t := range batch {
			if len(t.errs) > 0 || t.c.Type != "review" {
				continue
			}
			if !batchIDs[t.c.Reviews] {
				findings = append(findings, fmt.Sprintf("%s.md: reviews '%s' not in batch", t.c.ID, t.c.Reviews))
			}
			found := false
			for _, d := range t.c.DependsOn {
				if d == t.c.Reviews {
					found = true
				}
			}
			if !found {
				findings = append(findings, t.c.ID+".md: review depends_on must include its reviews id")
			}
		}
	}
	return findings
}

// tokenizeForLint mirrors the verify runner's tokenizer without importing it
// (card must not depend on verify). Same rules: whitespace splits, quotes group.
func tokenizeForLint(cmd string) ([]string, error) {
	var tokens []string
	var sb strings.Builder
	inQuote := false
	for _, ch := range cmd {
		switch {
		case ch == '"':
			inQuote = !inQuote
		case !inQuote && (ch == ' ' || ch == '\t'):
			if sb.Len() > 0 {
				tokens = append(tokens, sb.String())
				sb.Reset()
			}
		default:
			sb.WriteRune(ch)
		}
	}
	if inQuote {
		return nil, fmt.Errorf("unbalanced quote")
	}
	if sb.Len() > 0 {
		tokens = append(tokens, sb.String())
	}
	return tokens, nil
}
```

Tests pass file sets as maps, and Go map iteration order is random - every
assertion checks finding CONTENT, never finding order. Keep it that way in any
test you add.

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/card`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/card/lint.go internal/card/lint_test.go
git commit -m "feat(v2): card lint - v1 checks 1-14 re-homed onto DB resolver"
```

---
### Task 11: cli - App wiring, dispatch, board + show verbs

**Files:**
- Create: `internal/cli/app.go`
- Create: `internal/cli/board.go`
- Create: `internal/cli/app_test.go`
- Modify: `cmd/muster/main.go` (replace the Task 1 stub dispatch)

- [ ] **Step 1: Write the failing tests**

`internal/cli/app_test.go`:

```go
package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"muster/internal/gitx"
	"muster/internal/store"
)

// newApp builds a unit-tier App: temp repo dir with .muster/cards, temp store,
// fake git, captured output, frozen clock.
func newApp(t *testing.T) (*App, *gitx.Fake, *bytes.Buffer) {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, ".muster")
	for _, d := range []string{"cards", "staging", "plans"} {
		if err := os.MkdirAll(filepath.Join(dir, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	st, err := store.Open(filepath.Join(dir, "muster.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	fake := &gitx.Fake{HeadSHA: "head0", BranchName: "main", AncestorOK: true, UserOK: true,
		HeadFiles: map[string]string{}}
	out := &bytes.Buffer{}
	app := &App{
		Root: root, Dir: dir, St: st, G: fake, Out: out,
		Now:    func() time.Time { return time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC) },
		Getenv: func(string) string { return "" },
	}
	return app, fake, out
}

func seed(t *testing.T, a *App, id, typ, tier, status string, deps ...string) {
	t.Helper()
	err := a.St.Ingest([]store.IngestTask{{
		Task: store.Task{ID: id, Plan: "p", Seq: 1, Type: typ, Tier: tier,
			CardPath: ".muster/cards/" + id + ".md", FrontmatterSHA: "sha"},
		Deps: deps,
	}}, "shard", "2026-01-01T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if status != "backlog" {
		if _, err := a.St.DB().Exec(`UPDATE tasks SET status=? WHERE id=?`, status, id); err != nil {
			t.Fatal(err)
		}
	}
}

func TestBoardEmpty(t *testing.T) {
	a, _, out := newApp(t)
	if code := a.Dispatch("board", nil); code != 0 {
		t.Fatalf("code %d", code)
	}
	if !strings.Contains(out.String(), "MUSTER: board empty") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestStatusBlockContent(t *testing.T) {
	a, _, out := newApp(t)
	seed(t, a, "p-01-a", "impl", "any", "inbox")
	seed(t, a, "p-02-r", "review", "strong", "inbox")
	seed(t, a, "p-03-c", "impl", "any", "doing")
	if _, err := a.St.DB().Exec(`UPDATE tasks SET claimed_at='2026-01-02T01:04:05Z' WHERE id='p-03-c'`); err != nil {
		t.Fatal(err)
	}
	seed(t, a, "p-04-d", "impl", "any", "failed")
	seed(t, a, "p-05-e", "impl", "any", "backlog", "p-04-d")
	a.Dispatch("board", nil)
	s := out.String()
	for _, want := range []string{
		"MUSTER status @",
		"(main)",
		"inbox    2 ready",
		"(run 1, review 1)",
		"[p-01-a, p-02-r]",
		"p-03-c claimed 2h",
		"backlog  1 blocked",
		"(1 DEAD: p-05-e behind failed p-04-d)",
		"failed   1",
		"[p-04-d]",
		"done     0",
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("status block missing %q:\n%s", want, s)
		}
	}
}

func TestStatusBlockStaleMarker(t *testing.T) {
	a, _, out := newApp(t)
	seed(t, a, "p-01-a", "impl", "any", "doing")
	if _, err := a.St.DB().Exec(`UPDATE tasks SET claimed_at='2025-12-30T00:00:00Z' WHERE id='p-01-a'`); err != nil {
		t.Fatal(err)
	}
	a.Dispatch("board", nil)
	if !strings.Contains(out.String(), "STALE") {
		t.Fatalf("stale marker missing:\n%s", out.String())
	}
}

func TestShow(t *testing.T) {
	a, _, out := newApp(t)
	seed(t, a, "p-01-a", "impl", "any", "inbox")
	cardPath := filepath.Join(a.Dir, "cards", "p-01-a.md")
	if err := os.WriteFile(cardPath, []byte("---\nid: p-01-a\n---\nbody here"), 0o644); err != nil {
		t.Fatal(err)
	}
	if code := a.Dispatch("show", []string{"p-01-a"}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	s := out.String()
	for _, want := range []string{"body here", "status: inbox", "ingest"} {
		if !strings.Contains(s, want) {
			t.Fatalf("show missing %q:\n%s", want, s)
		}
	}
}

func TestShowUnknownID(t *testing.T) {
	a, _, out := newApp(t)
	if code := a.Dispatch("show", []string{"nope"}); code != 1 {
		t.Fatalf("code %d", code)
	}
	if !strings.Contains(out.String(), "MUSTER refuse:") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestAgeString(t *testing.T) {
	now := time.Date(2026, 1, 2, 12, 0, 0, 0, time.UTC)
	for iso, want := range map[string]string{
		"2026-01-02T11:18:00Z": "42m",
		"2026-01-02T09:00:00Z": "3h",
		"2025-12-31T12:00:00Z": "2d",
	} {
		if got := ageString(now, iso); got != want {
			t.Fatalf("%s: got %s want %s", iso, got, want)
		}
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/cli`
Expected: FAIL.

- [ ] **Step 3: Implement**

`internal/cli/app.go`:

```go
// Package cli implements every muster verb over four seams: the store (SQLite),
// gitx (git), the verify runner, and the card parser. Verbs return process exit
// codes; main only maps argv and os.Exit.
package cli

import (
	"fmt"
	"io"
	"time"

	"muster/internal/gitx"
	"muster/internal/store"
)

type App struct {
	Root string // repo root, absolute
	Dir  string // <Root>/.muster
	St   *store.Store
	G    gitx.Git
	Out  io.Writer
	Now  func() time.Time
	Getenv func(string) string
}

func (a *App) iso() string { return store.IsoNow(a.Now()) }

func (a *App) pf(format string, args ...any) {
	fmt.Fprintf(a.Out, format+"\n", args...)
}

// refuse prints the single-line refusal and returns exit code 1.
func (a *App) refuse(format string, args ...any) int {
	a.pf("MUSTER refuse: "+format, args...)
	return 1
}

// Dispatch routes one verb. Verbs are added task by task; unknown or
// not-yet-implemented verbs refuse.
func (a *App) Dispatch(verb string, args []string) int {
	switch verb {
	case "board":
		return a.Board()
	case "show":
		return a.Show(args)
	default:
		return a.refuse("verb %q is not implemented yet.", verb)
	}
}
```

Also add to `internal/store/store.go` (one method - unit tests and doctor need
raw read access):

```go
// DB exposes the handle for read-only diagnostics and tests. Verb logic never
// uses it directly.
func (s *Store) DB() *sql.DB { return s.db }
```

`internal/cli/board.go`:

```go
package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func ageString(now time.Time, iso string) string {
	then, err := time.Parse("2006-01-02T15:04:05Z", iso)
	if err != nil {
		return "unknown"
	}
	d := now.Sub(then)
	switch {
	case d.Hours() >= 24:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	case d.Hours() >= 1:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	}
}

// statusBlock renders the v1 spec 8.3 board print from DB state.
func (a *App) statusBlock() (string, error) {
	b, err := a.St.Board()
	if err != nil {
		return "", err
	}
	if b.Total() == 0 {
		return "MUSTER: board empty - nothing ingested.", nil
	}
	branch, err := a.G.Branch()
	if err != nil {
		branch = "?"
	}
	var lines []string
	lines = append(lines, fmt.Sprintf("MUSTER status @ %s (%s)", filepath.Base(a.Root), branch))
	split := fmt.Sprintf("run %d, review %d", b.InboxRun, b.InboxReview)
	lines = append(lines, fmt.Sprintf("  inbox    %d ready      (%s) [%s]",
		len(b.InboxIDs), split, strings.Join(b.InboxIDs, ", ")))
	doingCell := ""
	for _, d := range b.Doing {
		age := "unknown"
		stale := ""
		if d.ClaimedAt != "" {
			age = ageString(a.Now().UTC(), d.ClaimedAt)
			if then, err := time.Parse("2006-01-02T15:04:05Z", d.ClaimedAt); err == nil &&
				a.Now().UTC().Sub(then).Hours() > 24 {
				stale = "        <- STALE: see .muster/RUNNER.md RECOVERY"
			}
		}
		doingCell = fmt.Sprintf("[%s claimed %s]%s", d.ID, age, stale)
	}
	lines = append(lines, strings.TrimRight(fmt.Sprintf("  doing    %d            %s", len(b.Doing), doingCell), " "))
	deadCell := ""
	if len(b.Dead) > 0 {
		deadCell = fmt.Sprintf("    (%d DEAD: %s)", len(b.Dead), strings.Join(b.Dead, "; "))
	}
	lines = append(lines, strings.TrimRight(fmt.Sprintf("  backlog  %d blocked%s", b.Backlog, deadCell), " "))
	lines = append(lines, strings.TrimRight(fmt.Sprintf("  failed   %d            [%s]", b.Failed, strings.Join(b.FailedIDs, ", ")), " "))
	lines = append(lines, fmt.Sprintf("  done     %d", b.Done))
	return strings.Join(lines, "\n"), nil
}

// boardLine is the counts-only summary done prints (v1 spec 4.3). No task ids.
func (a *App) boardLine() (string, error) {
	b, err := a.St.Board()
	if err != nil {
		return "", err
	}
	parts := []string{
		fmt.Sprintf("run %d", b.InboxRun),
		fmt.Sprintf("review %d", b.InboxReview),
	}
	backlogCell := fmt.Sprintf("backlog %d", b.Backlog)
	if len(b.Dead) > 0 {
		backlogCell += fmt.Sprintf(" (%d DEAD)", len(b.Dead))
	}
	parts = append(parts, backlogCell,
		fmt.Sprintf("failed %d", b.Failed),
		fmt.Sprintf("done %d", b.Done))
	return "Board: " + strings.Join(parts, " | "), nil
}

// Board implements `muster board`.
func (a *App) Board() int {
	block, err := a.statusBlock()
	if err != nil {
		return a.refuse("board query failed: %v", err)
	}
	fmt.Fprintln(a.Out, block)
	return 0
}

// Show implements `muster show <id>`: card body from disk plus the DB view.
func (a *App) Show(args []string) int {
	if len(args) != 1 {
		return a.refuse("show needs exactly one task id.")
	}
	t, err := a.St.Task(args[0])
	if err != nil {
		return a.refuse("show query failed: %v", err)
	}
	if t == nil {
		return a.refuse("no task '%s' on the board.", args[0])
	}
	if body, err := os.ReadFile(filepath.Join(a.Root, filepath.FromSlash(t.CardPath))); err == nil {
		fmt.Fprintln(a.Out, strings.TrimRight(string(body), "\n"))
	} else {
		a.pf("(card file missing on disk: %s)", t.CardPath)
	}
	a.pf("")
	a.pf("- status: %s", t.Status)
	a.pf("- tier: %s | type: %s | plan: %s | generation: %d", t.Tier, t.Type, t.Plan, t.Generation)
	if t.ClaimedAt != "" {
		a.pf("- claimed: %s by %s (head %s)", t.ClaimedAt, t.ClaimedBy, t.HeadAtClaim)
	}
	deps, _ := a.St.Deps(t.ID)
	if len(deps) > 0 {
		a.pf("- depends_on: %s", strings.Join(deps, ", "))
	}
	evs, _ := a.St.Events(t.ID)
	a.pf("- events:")
	for _, e := range evs {
		line := fmt.Sprintf("  - %s %s %s", e.CreatedAt, e.Actor, e.Verb)
		if e.Detail != "" {
			line += " (" + e.Detail + ")"
		}
		a.pf("%s", line)
	}
	vs, _ := a.St.Verdicts(t.ID)
	for _, v := range vs {
		a.pf("- verdict: %s by %s: %s", v.Verdict, v.Reviewer, v.Reason)
	}
	return 0
}
```

Rewrite `cmd/muster/main.go`:

```go
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"muster/internal/cli"
	"muster/internal/gitx"
	"muster/internal/store"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: muster <verb> [args]")
		fmt.Println("verbs: init ingest claim verify done promote board show redo fail reimport doctor")
		os.Exit(1)
	}
	verb, args := os.Args[1], os.Args[2:]

	root, err := gitx.FindRoot(".")
	if err != nil {
		fmt.Println("MUSTER refuse: not inside a git repository.")
		os.Exit(1)
	}
	dir := filepath.Join(root, ".muster")
	app := &cli.App{
		Root: root, Dir: dir, G: &gitx.Repo{Dir: root},
		Out: os.Stdout, Now: time.Now, Getenv: os.Getenv,
	}
	if verb == "init" {
		os.Exit(app.Init(args)) // init creates .muster/ and the db itself (Task 23)
	}
	if _, err := os.Stat(dir); err != nil {
		fmt.Println("MUSTER refuse: .muster/ not found - run muster init first.")
		os.Exit(1)
	}
	st, err := store.Open(filepath.Join(dir, "muster.db"))
	if err != nil {
		fmt.Printf("MUSTER refuse: cannot open board db: %v\n", err)
		os.Exit(1)
	}
	defer st.Close()
	app.St = st
	os.Exit(app.Dispatch(verb, args))
}
```

Until Task 23 lands, give `App.Init` a stub in `internal/cli/app.go` so this
compiles:

```go
// Init is implemented in Task 23; stub keeps main wired meanwhile.
func (a *App) Init(args []string) int {
	return a.refuse("verb \"init\" is not implemented yet.")
}
```

(Place the real implementation in `internal/cli/initcmd.go` in Task 23 and
delete this stub then.)

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/cli` then `go build ./...`
Expected: PASS / clean build.

- [ ] **Step 5: Commit**

```bash
git add internal/cli/app.go internal/cli/board.go internal/cli/app_test.go internal/store/store.go cmd/muster/main.go
git commit -m "feat(v2): cli wiring, board/show verbs, real main dispatch"
```

---

### Task 12: cli - ingest verb

**Files:**
- Create: `internal/cli/ingest.go`
- Create: `internal/cli/ingest_test.go`
- Modify: `internal/cli/app.go` (add `case "ingest"` to Dispatch)

- [ ] **Step 1: Write the failing tests**

`internal/cli/ingest_test.go`:

```go
package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const ingestImpl = `---
id: demo-01-w
plan: demo
type: impl
tier: any
depends_on: []
protected:
  - internal/w/w_test.go
commit_paths:
  - internal/w/w.go
  - internal/w/w_test.go
  - internal/w
verify:
  - cmd: go test internal/w
    expect_exit: 0
---
# demo-01-w: build w

## Context
ctx

## Steps
1. build

## Acceptance
- green
`

const ingestIntegration = `---
id: demo-99-int
plan: demo
type: integration
tier: strong
depends_on:
  - demo-01-w
verify:
  - cmd: go vet all
    expect_exit: 0
---
# demo-99-int: integrate

## Context
ctx

## Steps
1. run

## Acceptance
- green
`

func writeInCards(t *testing.T, a *App, name, text string) string {
	t.Helper()
	p := filepath.Join(a.Dir, "cards", name)
	if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestIngestHappyPath(t *testing.T) {
	a, _, out := newApp(t)
	p1 := writeInCards(t, a, "demo-01-w.md", ingestImpl)
	p2 := writeInCards(t, a, "demo-99-int.md", ingestIntegration)
	if code := a.Dispatch("ingest", []string{p1, p2}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	if !strings.Contains(out.String(), "INGEST OK 2 task(s)") {
		t.Fatalf("out: %s", out.String())
	}
	got, _ := a.St.Task("demo-01-w")
	if got == nil || got.Status != "backlog" || got.CardPath != ".muster/cards/demo-01-w.md" {
		t.Fatalf("row: %+v", got)
	}
	if got.FrontmatterSHA == "" {
		t.Fatal("sha not stored")
	}
	deps, _ := a.St.Deps("demo-99-int")
	if len(deps) != 1 || deps[0] != "demo-01-w" {
		t.Fatalf("deps: %v", deps)
	}
}

func TestIngestLintFailure(t *testing.T) {
	a, _, out := newApp(t)
	bad := strings.Replace(ingestImpl, "## Context\nctx", "## Context\nTBD", 1)
	p := writeInCards(t, a, "demo-01-w.md", bad)
	if code := a.Dispatch("ingest", []string{p}); code != 1 {
		t.Fatalf("code %d", code)
	}
	if !strings.Contains(out.String(), "LINT FAIL") {
		t.Fatalf("out: %s", out.String())
	}
	if got, _ := a.St.Task("demo-01-w"); got != nil {
		t.Fatal("failed lint must not insert")
	}
}

func TestIngestRefusesOutsideCardsDir(t *testing.T) {
	a, _, out := newApp(t)
	p := filepath.Join(a.Root, "demo-01-w.md")
	os.WriteFile(p, []byte(ingestImpl), 0o644)
	if code := a.Dispatch("ingest", []string{p}); code != 1 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	if !strings.Contains(out.String(), "must live under .muster/cards/") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestIngestNoArgs(t *testing.T) {
	a, _, _ := newApp(t)
	if code := a.Dispatch("ingest", nil); code != 1 {
		t.Fatalf("code %d", code)
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/cli`
Expected: FAIL.

- [ ] **Step 3: Implement**

`internal/cli/ingest.go`:

```go
package cli

import (
	"os"
	"path/filepath"
	"strings"

	"muster/internal/card"
	"muster/internal/store"
)

// existsOnBoard is the lint resolver: an id resolves when it has a DB row.
func (a *App) existsOnBoard(id string) bool {
	t, err := a.St.Task(id)
	return err == nil && t != nil
}

// Ingest implements `muster ingest <files...>`: shard handoff. Lint gate first
// (full mode); on success one transaction inserts rows + deps, fail closed.
// Cards are inserted BEFORE the shard commit lands them - the printed reminder
// closes the loop (claim refuses uncommitted cards at the HEAD-read step).
func (a *App) Ingest(paths []string) int {
	if len(paths) == 0 {
		return a.refuse("ingest needs at least one card file path.")
	}
	cardsDir := filepath.ToSlash(filepath.Join(a.Dir, "cards"))
	for _, p := range paths {
		abs, err := filepath.Abs(p)
		if err != nil || !strings.HasPrefix(filepath.ToSlash(abs), cardsDir+"/") {
			return a.refuse("card files must live under .muster/cards/ (got %s).", p)
		}
	}
	findings := card.Lint(paths, a.existsOnBoard, card.Full)
	if len(findings) > 0 {
		for _, f := range findings {
			a.pf("LINT FAIL %s", f)
		}
		return 1
	}
	var batch []store.IngestTask
	for _, p := range paths {
		raw, err := os.ReadFile(p)
		if err != nil {
			return a.refuse("cannot read %s: %v", p, err)
		}
		c, errs := card.Parse(string(raw), false)
		if len(errs) > 0 { // unreachable after a clean lint; belt and braces
			return a.refuse("%s: %s", filepath.Base(p), errs[0])
		}
		abs, _ := filepath.Abs(p)
		rel, err := filepath.Rel(a.Root, abs)
		if err != nil {
			return a.refuse("cannot relativize %s: %v", p, err)
		}
		batch = append(batch, store.IngestTask{
			Task: store.Task{
				ID: c.ID, Plan: c.Plan, Seq: c.Seq, Type: c.Type, Tier: c.Tier,
				Harness: c.Harness, CardPath: filepath.ToSlash(rel),
				FrontmatterSHA: c.FrontmatterSHA, Reviews: c.Reviews, Fixes: c.Fixes,
			},
			Deps: c.DependsOn,
		})
	}
	if err := a.St.Ingest(batch, "shard", a.iso()); err != nil {
		return a.refuse("ingest failed: %v", err)
	}
	a.pf("INGEST OK %d task(s). Commit the card files now, then run: muster promote", len(batch))
	return 0
}
```

In `internal/cli/app.go` Dispatch, add:

```go
	case "ingest":
		return a.Ingest(args)
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/cli`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/cli/ingest.go internal/cli/ingest_test.go internal/cli/app.go
git commit -m "feat(v2): ingest verb - lint gate + fail-closed batch insert"
```

---
### Task 13: cli - claim core + reconciler

**Files:**
- Create: `internal/cli/claim.go`
- Create: `internal/cli/claim_test.go`
- Modify: `internal/card/lint.go` (rename `pathListed` to exported `PathListed`)
- Modify: `internal/cli/app.go` (add `case "claim"`)

The recovery probe is Task 17 (it needs the done pass path); this task ships
`probe` as a stub returning false. The reconciler ships HERE because a crash
between done's commit and DB flip must heal before the doing-occupied refusal
fires (spec D-v2-4: derived status).

- [ ] **Step 1: Write the failing tests**

`internal/cli/claim_test.go`:

```go
package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"muster/internal/card"
	"muster/internal/gitx"
	"muster/internal/store"
)

const claimCard = `---
id: demo-01-w
plan: demo
type: impl
tier: any
depends_on: []
protected:
  - internal/w/w_test.go
commit_paths:
  - internal/w/w.go
  - internal/w/w_test.go
  - internal/w
verify:
  - cmd: go version
    expect_contains: go version
---
# demo-01-w: build w

## Context
ctx

## Steps
1. build

## Acceptance
- green
`

// seedClaimable inserts a row whose stored sha matches the HEAD card text and
// registers the card at the fake's HEAD.
func seedClaimable(t *testing.T, a *App, fake *gitx.Fake, id, text, status string) {
	t.Helper()
	c, errs := card.Parse(text, false)
	if len(errs) > 0 {
		t.Fatalf("fixture card invalid: %v", errs)
	}
	rel := ".muster/cards/" + id + ".md"
	err := a.St.Ingest([]store.IngestTask{{Task: store.Task{
		ID: id, Plan: c.Plan, Seq: c.Seq, Type: c.Type, Tier: c.Tier, Harness: c.Harness,
		CardPath: rel, FrontmatterSHA: c.FrontmatterSHA, Reviews: c.Reviews, Fixes: c.Fixes,
	}, Deps: c.DependsOn}}, "shard", "2026-01-01T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if status != "backlog" {
		if _, err := a.St.DB().Exec(`UPDATE tasks SET status=? WHERE id=?`, status, id); err != nil {
			t.Fatal(err)
		}
	}
	fake.HeadFiles[rel] = text
}

func TestClaimRequiresIdentityFlags(t *testing.T) {
	a, _, out := newApp(t)
	if code := a.Dispatch("claim", nil); code != 1 {
		t.Fatalf("code %d", code)
	}
	if !strings.Contains(out.String(), "claim requires -harness") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestClaimHappyPath(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"})
	if code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	s := out.String()
	for _, want := range []string{"MUSTER status @", "# demo-01-w: build w", "Claimed demo-01-w. Follow .muster/RUNNER.md."} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %q:\n%s", want, s)
		}
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "doing" || row.HeadAtClaim != "head0" || row.ClaimedBy != "claude/any" {
		t.Fatalf("row: %+v", row)
	}
}

func TestClaimPromotesFirst(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "backlog") // dep-free backlog
	code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"})
	if code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "doing" {
		t.Fatalf("promote-then-claim failed: %s", row.Status)
	}
}

func TestClaimTierPinning(t *testing.T) {
	a, fake, out := newApp(t)
	strongCard := strings.Replace(claimCard, "tier: any", "tier: strong", 1)
	seedClaimable(t, a, fake, "demo-01-w", strongCard, "inbox")
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 1 {
		t.Fatalf("any session must not take strong task: %d %s", code, out.String())
	}
	if !strings.Contains(out.String(), "nothing to claim for claude/any") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestClaimStatusBeforeRefusal(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	if _, err := a.St.DB().Exec(`UPDATE tasks SET claimed_at='2026-01-02T02:04:05Z' WHERE id='demo-01-w'`); err != nil {
		t.Fatal(err)
	}
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 1 {
		t.Fatal("must refuse")
	}
	s := out.String()
	iStatus := strings.Index(s, "MUSTER status @")
	iRefuse := strings.Index(s, "MUSTER refuse:")
	if iStatus < 0 || iRefuse < 0 || iStatus > iRefuse {
		t.Fatalf("status block must print before the refusal (CM-ORDER):\n%s", s)
	}
	if !strings.Contains(s, "doing occupied by demo-01-w") {
		t.Fatalf("out: %s", s)
	}
}

func TestClaimDirtyTreeScope(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	fake.Dirty = []string{"stray.txt"}
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "working tree dirty outside demo-01-w's commit_paths: stray.txt") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestClaimToleratesInScopeDirt(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	fake.Dirty = []string{"internal/w/w.go", ".muster/cards/demo-01-w.notes.md"}
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 0 {
		t.Fatalf("in-scope dirt must not refuse: %s", out.String())
	}
}

func TestClaimCardNotAtHead(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	delete(fake.HeadFiles, ".muster/cards/demo-01-w.md")
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "not committed at HEAD") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestClaimShaMismatchWarns(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	if _, err := a.St.DB().Exec(`UPDATE tasks SET frontmatter_sha='stale' WHERE id='demo-01-w'`); err != nil {
		t.Fatal(err)
	}
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 0 {
		t.Fatalf("mismatch is a warning, not a refusal: %s", out.String())
	}
	if !strings.Contains(out.String(), "MUSTER warn: demo-01-w frontmatter differs") {
		t.Fatalf("out: %s", out.String())
	}
	evs, _ := a.St.Events("demo-01-w")
	found := false
	for _, e := range evs {
		if e.Verb == "warn" {
			found = true
		}
	}
	if !found {
		t.Fatal("warn event missing")
	}
}

func TestReconcilerHealsCommittedDone(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	if _, err := a.St.DB().Exec(`UPDATE tasks SET head_at_claim='head0', claimed_by='claude/any' WHERE id='demo-01-w'`); err != nil {
		t.Fatal(err)
	}
	fake.GrepSHAs = []string{"deadbeef"} // the done commit exists in git
	// nothing else claimable: claim reconciles, then refuses on empty inbox
	a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"})
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "done" {
		t.Fatalf("reconciler must heal: %s", row.Status)
	}
	if !strings.Contains(out.String(), "Reconciled demo-01-w") {
		t.Fatalf("out: %s", out.String())
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/cli`
Expected: FAIL.

- [ ] **Step 3: Rename the lint helper**

In `internal/card/lint.go` rename `pathListed` to `PathListed` (both uses),
comment: `// PathListed: path equals a list entry or sits under a listed directory.`

- [ ] **Step 4: Implement claim**

`internal/cli/claim.go`:

```go
package cli

import (
	"flag"
	"fmt"
	"io"
	"path"
	"strings"

	"muster/internal/card"
	"muster/internal/store"
)

// inScope: the claim/done scope rule (v1 spec 4.1.7/4.3.4, D27, re-homed).
// Under .muster/ only the executor-writable set is in scope: live notes,
// verify logs, and the staged fix. Everything else there is protocol surface.
// Outside .muster/, commit_paths is the whitelist. The db files are gitignored
// and never appear in porcelain output.
func inScope(p string, commitPaths []string) bool {
	for _, pat := range []string{".muster/cards/*.notes.md", ".muster/cards/*.verify.log", ".muster/staging/*.md"} {
		if ok, _ := path.Match(pat, p); ok {
			return true
		}
	}
	if p == ".muster" || strings.HasPrefix(p, ".muster/") {
		return false
	}
	return card.PathListed(p, commitPaths)
}

// headCard reads and parses the candidate's card from HEAD (hot-decision reads
// are HEAD reads - executor edits to the working-tree card stay inert), and
// files a warn event on a frontmatter sha mismatch (D-v2-2).
func (a *App) headCard(t *store.Task, actor string) (*card.Card, string, string) {
	body, err := a.G.ShowAtHead(t.CardPath)
	if err != nil {
		return nil, "", fmt.Sprintf("card %s is not committed at HEAD - commit the shard batch first.", t.CardPath)
	}
	c, errs := card.Parse(body, false)
	if len(errs) > 0 {
		return nil, "", fmt.Sprintf("%s card invalid at HEAD: %s. Human attention needed.", t.ID, errs[0])
	}
	if c.FrontmatterSHA != t.FrontmatterSHA {
		a.pf("MUSTER warn: %s frontmatter differs from the ingested copy - deliberate edits go through muster reimport.", t.ID)
		a.St.AppendEvent(t.ID, "system", "warn", "frontmatter sha mismatch", a.iso())
	}
	return c, body, ""
}

// reconcile heals rows stranded by a crash between done's commit and the DB
// flip: for each doing task, look for its done commit by message grammar in
// head_at_claim..HEAD (spec D-v2-4: status=done is derived).
func (a *App) reconcile() {
	doing, err := a.St.Doing()
	if err != nil {
		return
	}
	for _, t := range doing {
		if t.HeadAtClaim == "" {
			continue
		}
		shas, err := a.G.LogGrep("^muster("+t.Plan+"): done "+t.ID+"$", t.HeadAtClaim+"..HEAD")
		if err != nil || len(shas) == 0 {
			continue
		}
		if err := a.St.MarkDone(t.ID, "system", a.iso()); err == nil {
			a.pf("Reconciled %s: done commit found, row healed.", t.ID)
			a.St.Promote("system", a.iso())
		}
	}
}

// probe is the recovery probe (Task 17). Stub: never auto-files.
func (a *App) probe(t *store.Task, c *card.Card, identity string) bool {
	return false
}

// Claim implements `muster claim -harness X -tier Y`.
func (a *App) Claim(args []string) int {
	fs := flag.NewFlagSet("claim", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	harness := fs.String("harness", "", "")
	tier := fs.String("tier", "", "")
	_ = fs.Parse(args)
	if (*harness != "claude" && *harness != "codex") || (*tier != "any" && *tier != "strong") {
		return a.refuse("claim requires -harness <claude|codex> and -tier <any|strong> (the wrapper skill supplies them).")
	}
	identity := *harness + "/" + *tier

	// 1. heal crashed dones, then promotions dropped by a crashed predecessor
	a.reconcile()
	if _, err := a.St.Promote("system", a.iso()); err != nil {
		return a.refuse("promote failed: %v", err)
	}
	// 2. status print - fires before any refusal (CM-ORDER)
	if block, err := a.statusBlock(); err == nil {
		fmt.Fprintln(a.Out, block)
	}
	// 3. one executor per checkout
	doing, err := a.St.Doing()
	if err != nil {
		return a.refuse("board query failed: %v", err)
	}
	if len(doing) > 0 {
		age := "unknown"
		if doing[0].ClaimedAt != "" {
			age = ageString(a.Now().UTC(), doing[0].ClaimedAt)
		}
		return a.refuse("doing occupied by %s (claimed %s ago). One executor per checkout. RECOVERY in .muster/RUNNER.md.", doing[0].ID, age)
	}

	for {
		// 4. lowest eligible id; dependency order is the only order
		cand, err := a.St.NextEligible(*tier, *harness)
		if err != nil {
			return a.refuse("claim query failed: %v", err)
		}
		if cand == nil {
			return a.refuse("nothing to claim for %s.", identity)
		}
		c, body, refusal := a.headCard(cand, identity)
		if refusal != "" {
			return a.refuse("%s", refusal)
		}
		// 5. dirty-tree scope check, scoped to the candidate
		dirty, err := a.G.DirtyPaths()
		if err != nil {
			return a.refuse("git status failed: %v", err)
		}
		var outOfScope []string
		for _, p := range dirty {
			if !inScope(p, c.CommitPaths) {
				outOfScope = append(outOfScope, p)
			}
		}
		if len(outOfScope) > 0 {
			return a.refuse("working tree dirty outside %s's commit_paths: %s. Likely leftovers from a failed or crashed task - see RECOVERY (.muster/RUNNER.md), 'leftover dirt'.",
				cand.ID, strings.Join(outOfScope, ", "))
		}
		// 6. atomic claim: HEAD read outside the tx, nothing slow inside
		head, err := a.G.Head()
		if err != nil {
			return a.refuse("git rev-parse failed: %v", err)
		}
		ok, err := a.St.ClaimTask(cand.ID, identity, head, a.iso())
		if err == store.ErrDoingOccupied {
			return a.refuse("doing occupied - another session claimed first. One executor per checkout.")
		}
		if err != nil {
			return a.refuse("claim transaction failed: %v", err)
		}
		if !ok {
			continue // candidate raced away; take the next one
		}
		// 7. recovery probe (Task 17): auto-file finished work, then loop
		if a.probe(cand, c, identity) {
			a.pf("Auto-filed %s - a crashed predecessor already finished it (claim-probe green).", cand.ID)
			continue
		}
		// 8. print the card and hand over to RUNNER.md
		fmt.Fprintln(a.Out, strings.TrimRight(body, "\n"))
		a.pf("Claimed %s. Follow .muster/RUNNER.md.", cand.ID)
		return 0
	}
}
```

In `internal/cli/app.go` Dispatch, add:

```go
	case "claim":
		return a.Claim(args)
```

- [ ] **Step 5: Run, verify pass**

Run: `go test ./internal/cli`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/cli/claim.go internal/cli/claim_test.go internal/card/lint.go internal/cli/app.go
git commit -m "feat(v2): claim verb - status/refusals/scope/atomic claim + done reconciler"
```

---

### Task 14: cli - verify verb

**Files:**
- Create: `internal/cli/verify.go`
- Create: `internal/cli/verify_test.go`
- Modify: `internal/cli/app.go` (add `case "verify"`)

Attempt = event row, burned BEFORE any command runs (D28 kill-safety, Authority
note 8). Third failed attempt is terminal: status failed, nothing committed,
evidence stays on disk.

- [ ] **Step 1: Write the failing tests**

`internal/cli/verify_test.go`:

```go
package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// green verify: `go version` runs everywhere the build runs, no network.
const verifyGreenCard = claimCard

var verifyRedCard = strings.Replace(claimCard,
	"  - cmd: go version\n    expect_contains: go version",
	"  - cmd: go tool bogus-no-such-tool\n    expect_exit: 0", 1)

func claimFor(t *testing.T, a *App, out interface{ String() string }) {
	t.Helper()
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 0 {
		t.Fatalf("fixture claim failed: %s", out.String())
	}
}

func TestVerifyRefusesEmptyDoing(t *testing.T) {
	a, _, out := newApp(t)
	if code := a.Dispatch("verify", nil); code != 1 {
		t.Fatalf("code %d", code)
	}
	if !strings.Contains(out.String(), "doing is empty") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestVerifyPassLogsAttempt(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", verifyGreenCard, "inbox")
	claimFor(t, a, out)
	if code := a.Dispatch("verify", nil); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	if !strings.Contains(out.String(), "VERIFY PASS (attempt 1)") {
		t.Fatalf("out: %s", out.String())
	}
	n, _ := a.St.AttemptsSinceClaim("demo-01-w")
	if n != 1 {
		t.Fatalf("attempts: %d", n)
	}
	log, err := os.ReadFile(filepath.Join(a.Dir, "cards", "demo-01-w.verify.log"))
	if err != nil || !strings.Contains(string(log), "=== attempt 1 |") {
		t.Fatalf("log: %v %s", err, log)
	}
}

func TestVerifyFailRetryThenTerminal(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", verifyRedCard, "inbox")
	claimFor(t, a, out)
	if code := a.Dispatch("verify", nil); code != 2 {
		t.Fatalf("attempt 1 code %d: %s", code, out.String())
	}
	if !strings.Contains(out.String(), "VERIFY FAIL (attempt 1 of 3)") ||
		!strings.Contains(out.String(), "Fix and rerun.") {
		t.Fatalf("out: %s", out.String())
	}
	a.Dispatch("verify", nil) // attempt 2
	if code := a.Dispatch("verify", nil); code != 3 {
		t.Fatal("attempt 3 must be terminal")
	}
	if !strings.Contains(out.String(), "VERIFY FAIL terminal") ||
		!strings.Contains(out.String(), "Session over.") {
		t.Fatalf("out: %s", out.String())
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "failed" {
		t.Fatalf("terminal status: %s", row.Status)
	}
}

func TestVerifyBurnsAttemptBeforeRunning(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", verifyGreenCard, "inbox")
	claimFor(t, a, out)
	// three attempts already burned: verify must go terminal WITHOUT running
	for i := 1; i <= 3; i++ {
		a.St.AppendEvent("demo-01-w", "claude/any", "attempt", "", "2026-01-02T00:00:00Z")
	}
	if code := a.Dispatch("verify", nil); code != 3 {
		t.Fatal("must be terminal")
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "failed" {
		t.Fatalf("status: %s", row.Status)
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/cli`
Expected: FAIL.

- [ ] **Step 3: Implement**

`internal/cli/verify.go`:

```go
package cli

import (
	"fmt"
	"path/filepath"
	"strconv"

	"muster/internal/card"
	"muster/internal/store"
	"muster/internal/verify"
)

// occupant returns the sole doing task and its HEAD card, or a refusal exit
// code. Shared by verify and done.
func (a *App) occupant() (*store.Task, *card.Card, int) {
	doing, err := a.St.Doing()
	if err != nil {
		return nil, nil, a.refuse("board query failed: %v", err)
	}
	if len(doing) == 0 {
		return nil, nil, a.refuse("doing is empty - nothing in progress.")
	}
	if len(doing) > 1 {
		return nil, nil, a.refuse("doing holds %d tasks - one executor per checkout broke. RECOVERY in .muster/RUNNER.md.", len(doing))
	}
	t := doing[0]
	c, _, refusal := a.headCard(&t, t.ClaimedBy)
	if refusal != "" {
		return nil, nil, a.refuse("%s", refusal)
	}
	return &t, c, -1
}

// runBlock wraps the verify runner with app wiring (HEAD, clock, log path).
func (a *App) runBlock(t *store.Task, c *card.Card, label string) (verify.Result, error) {
	head, err := a.G.Head()
	if err != nil {
		return verify.Result{}, err
	}
	return verify.RunBlock(c.Verify, verify.BlockOpts{
		WorkDir: a.Root,
		LogPath: filepath.Join(a.Dir, "cards", t.ID+".verify.log"),
		Label:   label, TaskID: t.ID, Head: head,
		NowIso: a.iso,
	})
}

const terminalMsg = "VERIFY FAIL terminal. Task failed - card, sidecars, and working-tree dirt left as evidence. Session over."

// Verify implements `muster verify`.
func (a *App) Verify() int {
	t, c, code := a.occupant()
	if t == nil {
		return code
	}
	count, err := a.St.AttemptsSinceClaim(t.ID)
	if err != nil {
		return a.refuse("attempt query failed: %v", err)
	}
	if count >= 3 {
		a.St.MarkFailed(t.ID, t.ClaimedBy, "verify terminal", a.iso())
		fmt.Fprintln(a.Out, terminalMsg)
		return 3
	}
	n := count + 1
	// D28: the attempt burns BEFORE any command runs - killing the verify
	// mid-run still counts. The event row is the counter; the log is transcript.
	if err := a.St.AppendEvent(t.ID, t.ClaimedBy, "attempt", strconv.Itoa(n), a.iso()); err != nil {
		return a.refuse("cannot record the attempt - refusing to run unaccounted: %v", err)
	}
	res, err := a.runBlock(t, c, fmt.Sprintf("attempt %d", n))
	if err != nil {
		return a.refuse("verify runner failed: %v", err)
	}
	if res.Pass {
		a.pf("VERIFY PASS (attempt %d)", n)
		return 0
	}
	if n < 3 {
		a.pf("VERIFY FAIL (attempt %d of 3): %s. Fix and rerun.", n, res.FirstFail)
		return 2
	}
	a.St.MarkFailed(t.ID, t.ClaimedBy, "verify terminal", a.iso())
	fmt.Fprintln(a.Out, terminalMsg)
	return 3
}
```

In `internal/cli/app.go` Dispatch, add:

```go
	case "verify":
		return a.Verify()
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/cli`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/cli/verify.go internal/cli/verify_test.go internal/cli/app.go
git commit -m "feat(v2): verify verb - event-burned attempts, 3-attempt terminal"
```

---
### Task 15: cli - result sidecar assembly + db backup

**Files:**
- Create: `internal/cli/result.go`
- Create: `internal/cli/result_test.go`

The result sidecar is the v1 format plus two v2 fields: `head_at_claim` replaces
`claim_commit`, and `events_chain_head` anchors the audit chain into the done
commit (spec D-v2-4: the sidecar-anchored chain head restores the forensic trace).

- [ ] **Step 1: Write the failing tests**

`internal/cli/result_test.go`:

```go
package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteResultImpl(t *testing.T) {
	a, fake, _ := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	if _, err := a.St.DB().Exec(`UPDATE tasks SET head_at_claim='head0',
		claimed_at='2026-01-01T10:00:00Z', claimed_by='claude/any' WHERE id='demo-01-w'`); err != nil {
		t.Fatal(err)
	}
	a.St.AppendEvent("demo-01-w", "claude/any", "claim", "", "2026-01-01T10:00:00Z")
	a.St.AppendEvent("demo-01-w", "claude/any", "attempt", "1", "2026-01-01T10:05:00Z")
	fake.DiffSince = []string{"internal/w/w.go"}
	fake.UntrackedList = []string{"internal/w/w_test.go"}
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-01-w.notes.md"), []byte("one surprise"), 0o644)

	row, _ := a.St.Task("demo-01-w")
	c, _, _ := a.headCard(row, "claude/any")
	rel, err := a.writeResult(row, c, resultOpts{Status: "done", Attempts: -1, DoneCheckPass: true})
	if err != nil {
		t.Fatal(err)
	}
	if rel != ".muster/cards/demo-01-w.result.md" {
		t.Fatalf("rel: %s", rel)
	}
	raw, _ := os.ReadFile(filepath.Join(a.Root, filepath.FromSlash(rel)))
	s := string(raw)
	head, _ := a.St.ChainHead()
	for _, want := range []string{
		"# Result: demo-01-w",
		"- status: done",
		"- head_at_claim: head0",
		"- claimed_at: 2026-01-01T10:00:00Z",
		"- completed_at: 2026-01-02T03:04:05Z",
		"- verify: pass (attempt 1 of 3)",
		"- events_chain_head: " + head,
		"  - internal/w/w.go",
		"  - internal/w/w_test.go",
		"## Surprises",
		"one surprise",
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("result missing %q:\n%s", want, s)
		}
	}
}

func TestWriteResultVariants(t *testing.T) {
	a, fake, _ := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	row, _ := a.St.Task("demo-01-w")
	c, _, _ := a.headCard(row, "x")

	rel, _ := a.writeResult(row, c, resultOpts{Status: "done", Attempts: 0, Probe: true, DoneCheckPass: true,
		Surprises: "auto-filed at claim: verify green before execution"})
	raw, _ := os.ReadFile(filepath.Join(a.Root, filepath.FromSlash(rel)))
	if !strings.Contains(string(raw), "verify: pass (claim-probe)") ||
		!strings.Contains(string(raw), "auto-filed at claim") {
		t.Fatalf("probe variant:\n%s", raw)
	}

	rel, _ = a.writeResult(row, c, resultOpts{Status: "failed", Verdict: "fail", Attempts: 0, DoneCheckPass: false})
	raw, _ = os.ReadFile(filepath.Join(a.Root, filepath.FromSlash(rel)))
	if !strings.Contains(string(raw), "verify: FAIL (done-check red - see verify.log)") ||
		!strings.Contains(string(raw), "- verdict: fail") {
		t.Fatalf("red variant:\n%s", raw)
	}

	rel, _ = a.writeResult(row, c, resultOpts{Status: "cycled", Verdict: "fail", Attempts: 2, DoneCheckPass: true, GenSuffix: ".gen1"})
	if rel != ".muster/cards/demo-01-w.gen1.result.md" {
		t.Fatalf("gen path: %s", rel)
	}
}

func TestWriteResultReviewFindings(t *testing.T) {
	a, fake, _ := newApp(t)
	review := strings.NewReplacer(
		"id: demo-01-w", "id: demo-02-review-w",
		"type: impl", "type: review",
		"tier: any", "tier: strong",
		"# demo-01-w: build w", "# demo-02-review-w: review",
	).Replace(claimCard)
	review = strings.Replace(review, "plan: demo", "plan: demo\nreviews: demo-01-w", 1)
	review = strings.Replace(review, "protected:\n  - internal/w/w_test.go\ncommit_paths:\n  - internal/w/w.go\n  - internal/w/w_test.go\n  - internal/w\n", "", 1)
	seedClaimable(t, a, fake, "demo-02-review-w", review, "doing")
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-02-review-w.notes.md"), []byte("finding: gap"), 0o644)
	row, _ := a.St.Task("demo-02-review-w")
	c, _, _ := a.headCard(row, "x")
	rel, _ := a.writeResult(row, c, resultOpts{Status: "done", Verdict: "pass", Attempts: 0, DoneCheckPass: true})
	raw, _ := os.ReadFile(filepath.Join(a.Root, filepath.FromSlash(rel)))
	s := string(raw)
	if !strings.Contains(s, "## Findings") || !strings.Contains(s, "finding: gap") {
		t.Fatalf("review result:\n%s", s)
	}
}

func TestBackupDB(t *testing.T) {
	a, _, _ := newApp(t)
	if err := a.backupDB(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(a.Dir, "backup.db")); err != nil {
		t.Fatal("backup.db missing")
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/cli`
Expected: FAIL.

- [ ] **Step 3: Implement**

`internal/cli/result.go`:

```go
package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"muster/internal/card"
	"muster/internal/store"
)

type resultOpts struct {
	Status        string // done | failed | cycled
	Verdict       string // "" | pass | fail
	Attempts      int    // -1 = query AttemptsSinceClaim
	Probe         bool
	DoneCheckPass bool
	Surprises     string // override for the notes text (claim-probe auto-file)
	GenSuffix     string // ".gen<g>" for cycled review rounds, else ""
}

// changedSinceClaim = tracked diff against head_at_claim plus untracked new
// files (a bare diff misses exactly the normal impl output), sorted unique.
func (a *App) changedSinceClaim(t *store.Task) ([]string, error) {
	tracked, err := a.G.DiffNamesSince(t.HeadAtClaim)
	if err != nil {
		return nil, err
	}
	untracked, err := a.G.Untracked()
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var out []string
	for _, p := range append(tracked, untracked...) {
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out, nil
}

// writeResult assembles the result sidecar; everything above Surprises comes
// from git + the DB - the model only wrote notes. Returns the repo-relative
// sidecar path (forward slashes).
func (a *App) writeResult(t *store.Task, c *card.Card, o resultOpts) (string, error) {
	attempts := o.Attempts
	if attempts < 0 {
		n, err := a.St.AttemptsSinceClaim(t.ID)
		if err != nil {
			return "", err
		}
		attempts = n
	}
	verifyLine := fmt.Sprintf("verify: pass (attempt %d of 3)", attempts)
	if attempts == 0 {
		verifyLine = "verify: pass (done-check only)"
		if o.Probe {
			verifyLine = "verify: pass (claim-probe)"
		}
	}
	if !o.DoneCheckPass {
		verifyLine = "verify: FAIL (done-check red - see verify.log)"
	}
	chainHead, err := a.St.ChainHead()
	if err != nil {
		return "", err
	}
	lines := []string{"# Result: " + t.ID, "", "- status: " + o.Status}
	if o.Verdict != "" {
		lines = append(lines, "- verdict: "+o.Verdict)
	}
	lines = append(lines,
		"- head_at_claim: "+t.HeadAtClaim,
		"- claimed_at: "+t.ClaimedAt,
		"- completed_at: "+a.iso(),
		"- "+verifyLine,
		"- events_chain_head: "+chainHead,
		"- files_changed:")
	changed, err := a.changedSinceClaim(t)
	if err != nil {
		return "", err
	}
	for _, f := range changed {
		lines = append(lines, "  - "+f)
	}
	notes := "none reported"
	notesPath := filepath.Join(a.Dir, "cards", t.ID+".notes.md")
	if raw, err := os.ReadFile(notesPath); err == nil {
		notes = strings.TrimRight(string(raw), "\r\n")
	}
	if o.Surprises != "" {
		notes = o.Surprises
	}
	lines = append(lines, "", "## Surprises", "")
	if c.Type == "review" || c.Type == "integration" {
		lines = append(lines, "none reported", "", "## Findings", "", notes)
	} else {
		lines = append(lines, notes)
	}
	rel := ".muster/cards/" + t.ID + o.GenSuffix + ".result.md"
	abs := filepath.Join(a.Root, filepath.FromSlash(rel))
	if err := os.WriteFile(abs, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		return "", err
	}
	return rel, nil
}

// backupDB refreshes .muster/backup.db (survives `git clean -fd`; spec D-v2-4).
func (a *App) backupDB() error {
	return a.St.Backup(filepath.Join(a.Dir, "backup.db"))
}
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/cli`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/cli/result.go internal/cli/result_test.go
git commit -m "feat(v2): result sidecar assembly with chain anchor + db backup"
```

---

### Task 16: cli - done pass path (commit-first, hook re-stage, crash points)

**Files:**
- Create: `internal/cli/done.go`
- Create: `internal/cli/done_test.go`
- Modify: `internal/cli/app.go` (add `case "done"`)

Ordering is the spec's crash contract (D-v2-4): sidecars written, explicit-path
commit, THEN the DB flip, backup, promote. `MUSTER_CRASH_POINT` (before-commit /
after-commit) injects deterministic crashes for the process tier's reconciler
proofs.

- [ ] **Step 1: Write the failing tests**

`internal/cli/done_test.go`:

```go
package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"muster/internal/gitx"
)

// setupDoneFixture: claimed impl task, commit_paths exist on disk, clean fake.
func setupDoneFixture(t *testing.T, cardText string) (*App, *gitx.Fake, *bytes.Buffer) {
	t.Helper()
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", cardText, "inbox")
	claimFor(t, a, out)
	out.Reset()
	wdir := filepath.Join(a.Root, "internal", "w")
	if err := os.MkdirAll(wdir, 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(wdir, "w.go"), []byte("package w\n"), 0o644)
	os.WriteFile(filepath.Join(wdir, "w_test.go"), []byte("package w\n"), 0o644)
	fake.DiffSince = nil
	fake.UntrackedList = []string{"internal/w/w.go", "internal/w/w_test.go"}
	return a, fake, out
}

func TestDoneImplPass(t *testing.T) {
	a, fake, out := setupDoneFixture(t, claimCard)
	if code := a.Dispatch("done", nil); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	s := out.String()
	for _, want := range []string{"Board: run 0", "Done: demo-01-w. Promoted: none. Do not claim another task. Session over."} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %q:\n%s", want, s)
		}
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "done" {
		t.Fatalf("status: %s", row.Status)
	}
	if len(fake.Commits) != 1 {
		t.Fatalf("commits: %+v", fake.Commits)
	}
	cm := fake.Commits[0]
	if cm.Msg != "muster(demo): done demo-01-w" {
		t.Fatalf("msg: %s", cm.Msg)
	}
	joined := strings.Join(cm.Paths, " ")
	for _, want := range []string{".muster/cards/demo-01-w.result.md", "internal/w/w.go", "internal/w/w_test.go"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("commit paths missing %s: %v", want, cm.Paths)
		}
	}
	if _, err := os.Stat(filepath.Join(a.Dir, "backup.db")); err != nil {
		t.Fatal("backup.db missing after done")
	}
}

func TestDoneRefusesVerdictOnImpl(t *testing.T) {
	a, _, out := setupDoneFixture(t, claimCard)
	if code := a.Dispatch("done", []string{"pass"}); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "done takes no verdict on impl/fix tasks.") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestDoneChecksRedRefusal(t *testing.T) {
	a, _, out := setupDoneFixture(t, verifyRedCard)
	if code := a.Dispatch("done", nil); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "done-check verify failed") {
		t.Fatalf("out: %s", out.String())
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "doing" {
		t.Fatalf("DB must stay untouched: %s", row.Status)
	}
}

func TestDoneProtectedRefusal(t *testing.T) {
	a, fake, out := setupDoneFixture(t, claimCard)
	fake.DiffSince = []string{"internal/w/w_test.go"} // tracked-and-modified protected path
	if code := a.Dispatch("done", nil); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "protected file(s) modified: internal/w/w_test.go") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestDoneScopeRefusal(t *testing.T) {
	a, fake, out := setupDoneFixture(t, claimCard)
	fake.UntrackedList = append(fake.UntrackedList, "stray.txt")
	if code := a.Dispatch("done", nil); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "changed outside commit_paths: stray.txt") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestDoneNonDescendantHead(t *testing.T) {
	a, fake, out := setupDoneFixture(t, claimCard)
	fake.AncestorOK = false
	if code := a.Dispatch("done", nil); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "not a descendant of head_at_claim") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestDoneCommitFailureLeavesDBUntouched(t *testing.T) {
	a, fake, _ := setupDoneFixture(t, claimCard)
	fake.CommitErr = os.ErrPermission
	if code := a.Dispatch("done", nil); code != 1 {
		t.Fatal("must refuse")
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "doing" {
		t.Fatalf("commit-first violated: %s", row.Status)
	}
}

func TestDoneHookMutationRestages(t *testing.T) {
	a, fake, out := setupDoneFixture(t, claimCard)
	fired := false
	fake.MutateOnCommit = func(f *gitx.Fake) {
		if !fired {
			fired = true
			f.Dirty = []string{"internal/w/w.go"}
		}
	}
	if code := a.Dispatch("done", nil); code != 0 {
		t.Fatalf("hook mutation must be absorbed: %s", out.String())
	}
	if fake.Amends != 1 {
		t.Fatalf("amends: %d", fake.Amends)
	}
}

func TestDoneReviewPassNeedsNotes(t *testing.T) {
	a, fake, out := newApp(t)
	review := strings.NewReplacer(
		"id: demo-01-w", "id: demo-02-review-w",
		"type: impl", "type: review",
		"tier: any", "tier: strong",
		"# demo-01-w: build w", "# demo-02-review-w: review",
	).Replace(claimCard)
	review = strings.Replace(review, "plan: demo", "plan: demo\nreviews: demo-01-w", 1)
	review = strings.Replace(review, "protected:\n  - internal/w/w_test.go\ncommit_paths:\n  - internal/w/w.go\n  - internal/w/w_test.go\n  - internal/w\n", "", 1)
	seedClaimable(t, a, fake, "demo-02-review-w", review, "inbox")
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "strong"}); code != 0 {
		t.Fatalf("claim: %s", out.String())
	}
	out.Reset()
	if code := a.Dispatch("done", []string{"pass"}); code != 1 {
		t.Fatal("must refuse without notes")
	}
	if !strings.Contains(out.String(), "verdict needs .muster/cards/demo-02-review-w.notes.md") {
		t.Fatalf("out: %s", out.String())
	}
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-02-review-w.notes.md"), []byte("looks right"), 0o644)
	out.Reset()
	if code := a.Dispatch("done", []string{"pass"}); code != 0 {
		t.Fatalf("review pass: %s", out.String())
	}
	vs, _ := a.St.Verdicts("demo-02-review-w")
	if len(vs) != 1 || vs[0].Verdict != "pass" {
		t.Fatalf("verdict rows: %+v", vs)
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/cli`
Expected: FAIL.

- [ ] **Step 3: Implement**

`internal/cli/done.go`:

```go
package cli

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"muster/internal/card"
	"muster/internal/store"
)

// crashPoint honors MUSTER_CRASH_POINT for the process tier's crash proofs.
func (a *App) crashPoint(point string) {
	if a.Getenv("MUSTER_CRASH_POINT") == point {
		fmt.Fprintln(a.Out, "MUSTER crash injection: "+point)
		os.Exit(97)
	}
}

func fileExistsAt(root, rel string) bool {
	_, err := os.Stat(filepath.Join(root, filepath.FromSlash(rel)))
	return err == nil
}

// donePreconditions ports v1 Test-DonePreconditions onto head_at_claim:
// protected fires on the TRACKED diff arm only (D30 - a newly created
// protected path is the sanctioned self-authoring case), scope spans both arms.
func (a *App) donePreconditions(t *store.Task, c *card.Card) (string, error) {
	tracked, err := a.G.DiffNamesSince(t.HeadAtClaim)
	if err != nil {
		return "", err
	}
	var hits []string
	for _, p := range tracked {
		if card.PathListed(p, c.Protected) {
			hits = append(hits, p)
		}
	}
	if len(hits) > 0 {
		return fmt.Sprintf("protected file(s) modified: %s. Revert them; the verify definition is not yours to change.",
			strings.Join(hits, ", ")), nil
	}
	changed, err := a.changedSinceClaim(t)
	if err != nil {
		return "", err
	}
	var extras []string
	for _, p := range changed {
		if !inScope(p, c.CommitPaths) {
			extras = append(extras, p)
		}
	}
	if len(extras) > 0 {
		return fmt.Sprintf("changed outside commit_paths: %s. Revert strays or stop for a human.",
			strings.Join(extras, ", ")), nil
	}
	return "", nil
}

type passOpts struct {
	Verdict, Reason string
	DoneCheckPass   bool
	Probe           bool
	Surprises       string
}

// completePass is the pass-path machinery (also used by the claim probe's
// auto-file): result sidecar, explicit-path commit (commit-first), DB flip,
// verdict row on judgment pass, backup, promote, board line.
func (a *App) completePass(t *store.Task, c *card.Card, o passOpts) int {
	rel, err := a.writeResult(t, c, resultOpts{
		Status: "done", Verdict: o.Verdict, Attempts: -1,
		Probe: o.Probe, DoneCheckPass: o.DoneCheckPass, Surprises: o.Surprises,
	})
	if err != nil {
		return a.refuse("result sidecar failed: %v", err)
	}
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
	a.crashPoint("before-commit")
	msg := fmt.Sprintf("muster(%s): done %s", t.Plan, t.ID)
	if err := a.G.Commit(msg, paths); err != nil {
		return a.refuse("completion commit failed: %v. DB untouched (commit-first) - fix git state and rerun done.", err)
	}
	// Hooks are honored, never silently bypassed: one re-stage + amend cycle
	// absorbs a tree-mutating hook (Authority note 2).
	if dirty, err := a.G.DirtyPaths(); err == nil {
		var again []string
		for _, d := range dirty {
			if card.PathListed(d, paths) {
				again = append(again, d)
			}
		}
		if len(again) > 0 {
			a.G.Add(again)
			a.G.AmendNoEdit()
			if d2, err := a.G.DirtyPaths(); err == nil {
				for _, d := range d2 {
					if card.PathListed(d, paths) {
						return a.refuse("a git hook keeps mutating committed files (%s) - fix the hook, then rerun done.", d)
					}
				}
			}
		}
	}
	a.crashPoint("after-commit")
	if err := a.St.MarkDone(t.ID, t.ClaimedBy, a.iso()); err != nil {
		return a.refuse("commit landed but the DB flip failed (%v) - rerun any verb; the claim-time reconciler heals this.", err)
	}
	if (c.Type == "review" || c.Type == "integration") && o.Verdict == "pass" {
		a.St.InsertVerdict(t.ID, t.ClaimedBy, "pass", o.Reason, a.iso())
	}
	if err := a.backupDB(); err != nil {
		a.pf("MUSTER warn: backup.db refresh failed: %v", err)
	}
	promoted, _ := a.St.Promote("system", a.iso())
	if o.Probe {
		// the auto-file happens INSIDE a claim - the claim loop keeps going,
		// so no board line and no "Session over." here (it is the only stop
		// signal and this session is not over).
		return 0
	}
	plist := "none"
	if len(promoted) > 0 {
		plist = strings.Join(promoted, ", ")
	}
	if line, err := a.boardLine(); err == nil {
		fmt.Fprintln(a.Out, line)
	}
	a.pf("Done: %s. Promoted: %s. Do not claim another task. Session over.", t.ID, plist)
	return 0
}

// Done implements `muster done [pass|fail] [--reason <text>]`.
func (a *App) Done(args []string) int {
	verdict := ""
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		verdict = args[0]
		args = args[1:]
	}
	fs := flag.NewFlagSet("done", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	reason := fs.String("reason", "", "")
	_ = fs.Parse(args)

	t, c, code := a.occupant()
	if t == nil {
		return code
	}
	isJudgment := c.Type == "review" || c.Type == "integration"
	if !isJudgment && verdict != "" {
		return a.refuse("done takes no verdict on impl/fix tasks.")
	}
	if isJudgment && verdict != "pass" && verdict != "fail" {
		return a.refuse("done needs a pass or fail verdict on review/integration tasks.")
	}
	if verdict == "fail" && strings.TrimSpace(*reason) == "" {
		return a.refuse("done fail requires --reason \"<one line>\" (the reason lands in the verdicts table).")
	}
	// head_at_claim discipline: done refuses when history was rewritten under
	// the claim (spec D-v2-4).
	head, err := a.G.Head()
	if err != nil {
		return a.refuse("git rev-parse failed: %v", err)
	}
	ok, err := a.G.IsAncestor(t.HeadAtClaim, head)
	if err != nil || !ok {
		return a.refuse("HEAD is not a descendant of head_at_claim (%s) - history rewritten under a claim. Human recovery.", t.HeadAtClaim)
	}
	// confirmation verify - kills stale-pass; logged as done-check, never
	// counts. A fail verdict on a judgment task records a red done-check
	// instead of gating on it (D29): a broken build IS the finding.
	res, err := a.runBlock(t, c, "done-check")
	if err != nil {
		return a.refuse("verify runner failed: %v", err)
	}
	if !res.Pass && !(isJudgment && verdict == "fail") {
		return a.refuse("done-check verify failed: %s. Run muster verify, fix, and retry.", res.FirstFail)
	}
	if msg, err := a.donePreconditions(t, c); err != nil {
		return a.refuse("precondition check failed: %v", err)
	} else if msg != "" {
		return a.refuse("%s", msg)
	}
	if isJudgment && !fileExistsAt(a.Root, ".muster/cards/"+t.ID+".notes.md") {
		return a.refuse("verdict needs .muster/cards/%s.notes.md with findings.", t.ID)
	}
	if verdict == "fail" {
		if c.Type == "review" {
			return a.doneFailReview(t, c, *reason, res.Pass)
		}
		return a.doneFailIntegration(t, c, *reason, res.Pass)
	}
	return a.completePass(t, c, passOpts{Verdict: verdict, Reason: *reason, DoneCheckPass: res.Pass})
}

// doneFailReview / doneFailIntegration land in Tasks 18-19.
func (a *App) doneFailReview(t *store.Task, c *card.Card, reason string, doneCheckPass bool) int {
	return a.refuse("done fail (review) is not implemented yet.")
}

func (a *App) doneFailIntegration(t *store.Task, c *card.Card, reason string, doneCheckPass bool) int {
	return a.refuse("done fail (integration) is not implemented yet.")
}
```

In `internal/cli/app.go` Dispatch, add:

```go
	case "done":
		return a.Done(args)
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/cli`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/cli/done.go internal/cli/done_test.go internal/cli/app.go
git commit -m "feat(v2): done pass path - commit-first, hook re-stage, crash points"
```

---
### Task 17: cli - claim recovery probe + auto-file

**Files:**
- Modify: `internal/cli/claim.go` (replace the `probe` stub)
- Create: `internal/cli/probe_test.go`

Gates kept from v1 (spec CLI table): probe only impl|fix AND only with
prior-claim evidence (an ungated probe would auto-file every review task).
Evidence = a claim event older than the one this claim just inserted.

- [ ] **Step 1: Write the failing tests**

`internal/cli/probe_test.go`:

```go
package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProbeAutoFilesFinishedWork(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	// prior-claim evidence: a claim event from a crashed predecessor session
	a.St.AppendEvent("demo-01-w", "claude/any", "claim", "", "2026-01-01T09:00:00Z")
	// the finished work sits in the tree
	wdir := filepath.Join(a.Root, "internal", "w")
	os.MkdirAll(wdir, 0o755)
	os.WriteFile(filepath.Join(wdir, "w.go"), []byte("package w\n"), 0o644)
	os.WriteFile(filepath.Join(wdir, "w_test.go"), []byte("package w\n"), 0o644)
	fake.UntrackedList = []string{"internal/w/w.go", "internal/w/w_test.go"}

	code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"})
	if code != 1 { // auto-file, then loop finds nothing else: refusal ends the run
		t.Fatalf("code %d: %s", code, out.String())
	}
	s := out.String()
	if !strings.Contains(s, "Auto-filed demo-01-w - a crashed predecessor already finished it (claim-probe green).") {
		t.Fatalf("out: %s", s)
	}
	if !strings.Contains(s, "nothing to claim for claude/any") {
		t.Fatalf("loop must continue to the empty-inbox refusal:\n%s", s)
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "done" {
		t.Fatalf("status: %s", row.Status)
	}
	if len(fake.Commits) != 1 || fake.Commits[0].Msg != "muster(demo): done demo-01-w" {
		t.Fatalf("commits: %+v", fake.Commits)
	}
	raw, _ := os.ReadFile(filepath.Join(a.Dir, "cards", "demo-01-w.result.md"))
	if !strings.Contains(string(raw), "verify: pass (claim-probe)") ||
		!strings.Contains(string(raw), "auto-filed at claim") {
		t.Fatalf("result: %s", raw)
	}
}

func TestProbeSkipsFirstClaims(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 0 {
		t.Fatalf("first claim must hand over normally: %s", out.String())
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "doing" {
		t.Fatalf("no prior evidence must mean no auto-file: %s", row.Status)
	}
}

func TestProbeNeverTouchesReviewTasks(t *testing.T) {
	a, fake, out := newApp(t)
	review := strings.NewReplacer(
		"id: demo-01-w", "id: demo-02-review-w",
		"type: impl", "type: review",
		"tier: any", "tier: strong",
		"# demo-01-w: build w", "# demo-02-review-w: review",
	).Replace(claimCard)
	review = strings.Replace(review, "plan: demo", "plan: demo\nreviews: demo-01-w", 1)
	review = strings.Replace(review, "protected:\n  - internal/w/w_test.go\ncommit_paths:\n  - internal/w/w.go\n  - internal/w/w_test.go\n  - internal/w\n", "", 1)
	seedClaimable(t, a, fake, "demo-02-review-w", review, "inbox")
	a.St.AppendEvent("demo-02-review-w", "claude/strong", "claim", "", "2026-01-01T09:00:00Z")
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "strong"}); code != 0 {
		t.Fatalf("review with prior claim must still hand over: %s", out.String())
	}
	row, _ := a.St.Task("demo-02-review-w")
	if row.Status != "doing" {
		t.Fatalf("review must never auto-file: %s", row.Status)
	}
}

func TestProbeRedVerifyHandsOver(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", verifyRedCard, "inbox")
	a.St.AppendEvent("demo-01-w", "claude/any", "claim", "", "2026-01-01T09:00:00Z")
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "any"}); code != 0 {
		t.Fatalf("red probe must hand over for a redo: %s", out.String())
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "doing" {
		t.Fatalf("status: %s", row.Status)
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/cli`
Expected: FAIL (probe stub never auto-files).

- [ ] **Step 3: Implement - replace the stub in `internal/cli/claim.go`**

```go
// probe is the recovery probe (D12 re-homed): after claiming, when this task
// shows prior-claim evidence and is impl/fix, run its verify block; green
// means a crashed predecessor already finished the work - auto-file it via
// the normal pass machinery. Returns true when the task was auto-filed.
// Unlike v1 there is no precondition refusal branch here: head_at_claim was
// captured seconds ago at this claim, so the protected diff arm is empty by
// construction and the scope arm was already enforced by the dirty-tree check.
func (a *App) probe(t *store.Task, c *card.Card, identity string) bool {
	if c.Type != "impl" && c.Type != "fix" {
		return false
	}
	n, err := a.St.ClaimCount(t.ID)
	if err != nil || n < 2 {
		return false
	}
	res, err := a.runBlock(t, c, "claim-probe")
	if err != nil || !res.Pass {
		return false
	}
	row, err := a.St.Task(t.ID) // refetch: ClaimTask stamped the claim fields
	if err != nil || row == nil {
		return false
	}
	return a.completePass(row, c, passOpts{
		DoneCheckPass: true, Probe: true,
		Surprises: "auto-filed at claim: verify green before execution",
	}) == 0
}
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/cli`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/cli/claim.go internal/cli/probe_test.go
git commit -m "feat(v2): claim recovery probe - gated auto-file of finished work"
```

---

### Task 18: cli - done fail, review path (staged fix, generations, cycle)

**Files:**
- Modify: `internal/store/tasks.go` (add `FixGeneration`, `CycleReview`)
- Create: `internal/cli/donefail.go` (replace the Task 16 stubs; move both stub
  functions out of `done.go`)
- Create: `internal/cli/donefail_test.go`

Protocol unchanged from v1 (spec D-v2-5): exactly one staged fix, lint-lite,
`fixes` must match `reviews`, generation cap 2 (g >= 3 is human territory),
review re-blocks on the fix. Mechanics re-homed: generation is a DB column,
depends_on grows in the deps table (never in frontmatter), sidecar history is
gen-suffixed in place (plain renames - nothing here is tracked yet), reject is
commit-first with a crash-resume (Authority note 7).

- [ ] **Step 1: Write the failing tests**

`internal/cli/donefail_test.go`:

```go
package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var reviewCardText = func() string {
	s := strings.NewReplacer(
		"id: demo-01-w", "id: demo-02-review-w",
		"type: impl", "type: review",
		"tier: any", "tier: strong",
		"# demo-01-w: build w", "# demo-02-review-w: review w",
	).Replace(claimCard)
	s = strings.Replace(s, "plan: demo", "plan: demo\nreviews: demo-01-w", 1)
	return strings.Replace(s, "protected:\n  - internal/w/w_test.go\ncommit_paths:\n  - internal/w/w.go\n  - internal/w/w_test.go\n  - internal/w\n", "", 1)
}()

const stagedFixText = `---
id: demo-01-fix-w
plan: demo
type: fix
tier: any
fixes: demo-01-w
depends_on: []
protected:
  - internal/w/w_test.go
commit_paths:
  - internal/w/w.go
  - internal/w
verify:
  - cmd: go version
    expect_contains: go version
---
# demo-01-fix-w: fix w

## Context
ctx

## Steps
1. fix it

## Acceptance
- green
`

// reviewFixture: impl on the board (done), review claimed, notes written.
func reviewFixture(t *testing.T) (*App, *fakeAndOut) {
	t.Helper()
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "done")
	seedClaimable(t, a, fake, "demo-02-review-w", reviewCardText, "inbox")
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "strong"}); code != 0 {
		t.Fatalf("claim: %s", out.String())
	}
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-02-review-w.notes.md"), []byte("finding: broken"), 0o644)
	out.Reset()
	return a, &fakeAndOut{fake, out}
}

func stageFix(t *testing.T, a *App) string {
	t.Helper()
	p := filepath.Join(a.Dir, "staging", "demo-01-fix-w.md")
	if err := os.WriteFile(p, []byte(stagedFixText), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestDoneFailReviewCyclesTheBoard(t *testing.T) {
	a, fx := reviewFixture(t)
	stageFix(t, a)
	code := a.Dispatch("done", []string{"fail", "-reason", "verify asserts the wrong shape"})
	if code != 0 {
		t.Fatalf("code %d: %s", code, fx.out.String())
	}
	if !strings.Contains(fx.out.String(), "Review failed. Fix demo-01-fix1-w queued (generation 1 of 2). Session over.") {
		t.Fatalf("out: %s", fx.out.String())
	}
	// staged file consumed; stamped card landed in cards/
	if _, err := os.Stat(filepath.Join(a.Dir, "staging", "demo-01-fix-w.md")); err == nil {
		t.Fatal("staging file must be consumed")
	}
	raw, err := os.ReadFile(filepath.Join(a.Dir, "cards", "demo-01-fix1-w.md"))
	if err != nil {
		t.Fatal("stamped fix card missing")
	}
	if !strings.Contains(string(raw), "id: demo-01-fix1-w") ||
		!strings.Contains(string(raw), "# demo-01-fix1-w: fix w") ||
		strings.Contains(string(raw), "generation:") {
		t.Fatalf("stamping wrong:\n%s", raw)
	}
	// one reject commit, right grammar
	if len(fx.fake.Commits) != 1 || fx.fake.Commits[0].Msg != "muster(demo): reject demo-01-w gen1" {
		t.Fatalf("commits: %+v", fx.fake.Commits)
	}
	// DB half: fix row inbox gen 1; review backlogged behind it; verdict filed
	fix, _ := a.St.Task("demo-01-fix1-w")
	if fix == nil || fix.Status != "inbox" || fix.Generation != 1 || fix.Fixes != "demo-01-w" {
		t.Fatalf("fix row: %+v", fix)
	}
	rev, _ := a.St.Task("demo-02-review-w")
	if rev.Status != "backlog" {
		t.Fatalf("review status: %s", rev.Status)
	}
	deps, _ := a.St.Deps("demo-02-review-w")
	found := false
	for _, d := range deps {
		if d == "demo-01-fix1-w" {
			found = true
		}
	}
	if !found {
		t.Fatalf("review must re-block on the fix: %v", deps)
	}
	vs, _ := a.St.Verdicts("demo-02-review-w")
	if len(vs) != 1 || vs[0].Verdict != "fail" || vs[0].Reason != "verify asserts the wrong shape" {
		t.Fatalf("verdicts: %+v", vs)
	}
	// gen-suffixed round history exists
	if _, err := os.Stat(filepath.Join(a.Dir, "cards", "demo-02-review-w.gen1.result.md")); err != nil {
		t.Fatal("gen result missing")
	}
}

func TestDoneFailReviewNeedsExactlyOneStagedFix(t *testing.T) {
	a, fx := reviewFixture(t)
	if code := a.Dispatch("done", []string{"fail", "-reason", "r"}); code != 1 {
		t.Fatal("zero staged must refuse")
	}
	if !strings.Contains(fx.out.String(), "exactly one") {
		t.Fatalf("out: %s", fx.out.String())
	}
	stageFix(t, a)
	os.WriteFile(filepath.Join(a.Dir, "staging", "demo-01-fix-w2.md"), []byte(stagedFixText), 0o644)
	fx.out.Reset()
	if code := a.Dispatch("done", []string{"fail", "-reason", "r"}); code != 1 {
		t.Fatal("two staged must refuse")
	}
}

func TestDoneFailReviewFixTargetMismatch(t *testing.T) {
	a, fx := reviewFixture(t)
	bad := strings.ReplaceAll(stagedFixText, "fixes: demo-01-w", "fixes: other-01-x")
	os.WriteFile(filepath.Join(a.Dir, "staging", "demo-01-fix-w.md"), []byte(bad), 0o644)
	if code := a.Dispatch("done", []string{"fail", "-reason", "r"}); code != 1 {
		t.Fatal("mismatch must refuse")
	}
	if !strings.Contains(fx.out.String(), "does not match reviews") {
		t.Fatalf("out: %s", fx.out.String())
	}
	if _, err := os.Stat(filepath.Join(a.Dir, "staging", "demo-01-fix-w.md")); err != nil {
		t.Fatal("file must be left in place")
	}
}

func TestDoneFailReviewGenerationCap(t *testing.T) {
	a, fx := reviewFixture(t)
	// two landed generations already on the board
	for _, id := range []string{"demo-01-fix1-w", "demo-01-fix2-w"} {
		if _, err := a.St.DB().Exec(`INSERT INTO tasks(id, plan, seq, type, tier, status, card_path, frontmatter_sha, fixes, generation)
			VALUES (?, 'demo', 1, 'fix', 'any', 'done', ?, 'x', 'demo-01-w', 1)`, id, ".muster/cards/"+id+".md"); err != nil {
			t.Fatal(err)
		}
	}
	stageFix(t, a)
	if code := a.Dispatch("done", []string{"fail", "-reason", "r"}); code != 3 {
		t.Fatalf("cap must exit 3: %s", fx.out.String())
	}
	if !strings.Contains(fx.out.String(), "Review cap hit (2 fix generations). demo-01-w chain needs a human. Session over.") {
		t.Fatalf("out: %s", fx.out.String())
	}
	rev, _ := a.St.Task("demo-02-review-w")
	if rev.Status != "failed" {
		t.Fatalf("review status: %s", rev.Status)
	}
	if _, err := os.Stat(filepath.Join(a.Dir, "staging", "demo-01-fix-w.md")); err == nil {
		t.Fatal("staged fix must be removed at the cap")
	}
}

func TestDoneFailReviewCrashResume(t *testing.T) {
	a, fx := reviewFixture(t)
	// simulate: reject commit landed (stamped card on disk), DB flip lost
	stamped := strings.ReplaceAll(stagedFixText, "demo-01-fix-w", "demo-01-fix1-w")
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-01-fix1-w.md"), []byte(stamped), 0o644)
	code := a.Dispatch("done", []string{"fail", "-reason", "resume"})
	if code != 0 {
		t.Fatalf("resume must complete the DB half: %s", fx.out.String())
	}
	if !strings.Contains(fx.out.String(), "Resumed crashed done fail") {
		t.Fatalf("out: %s", fx.out.String())
	}
	fix, _ := a.St.Task("demo-01-fix1-w")
	if fix == nil || fix.Status != "inbox" || fix.Generation != 1 {
		t.Fatalf("fix row: %+v", fix)
	}
	rev, _ := a.St.Task("demo-02-review-w")
	if rev.Status != "backlog" {
		t.Fatalf("review status: %s", rev.Status)
	}
	if len(fx.fake.Commits) != 0 {
		t.Fatal("resume must not commit again")
	}
}
```

Add near the top of the file (shared fixture shape; import `bytes` and
`muster/internal/gitx`):

```go
type fakeAndOut struct {
	fake *gitx.Fake
	out  *bytes.Buffer
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/cli`
Expected: FAIL (stub refuses).

- [ ] **Step 3: Add the store composites to `internal/store/tasks.go`**

```go
// FixGeneration returns the next generation number for a fix of implID:
// 1 + count of fix tasks already targeting it (the DB is the only counter).
func (s *Store) FixGeneration(implID string) (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM tasks WHERE type = 'fix' AND fixes = ?`, implID).Scan(&n)
	return n + 1, err
}

// CycleReview is the reject flow's DB half, one transaction: insert the
// stamped fix (status inbox, generation g), flip the review doing -> backlog
// with claim fields cleared, re-block the review on the fix, file the fail
// verdict, and append events for both rows.
func (s *Store) CycleReview(reviewID, reviewer, reason string, fix IngestTask, g int, now string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	f := fix.Task
	if _, err := tx.Exec(`INSERT INTO tasks(id, plan, seq, type, tier, harness, status,
		card_path, frontmatter_sha, reviews, fixes, generation)
		VALUES (?, ?, ?, ?, ?, ?, 'inbox', ?, ?, ?, ?, ?)`,
		f.ID, f.Plan, f.Seq, f.Type, f.Tier, f.Harness,
		f.CardPath, f.FrontmatterSHA, f.Reviews, f.Fixes, g); err != nil {
		return err
	}
	for _, dep := range fix.Deps {
		if _, err := tx.Exec(`INSERT INTO deps(task_id, depends_on) VALUES (?, ?)`, f.ID, dep); err != nil {
			return err
		}
	}
	res, err := tx.Exec(`UPDATE tasks SET status = 'backlog', head_at_claim = '',
		claimed_at = '', claimed_by = '' WHERE id = ? AND status = 'doing'`, reviewID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return fmt.Errorf("%s: review is not doing - cannot cycle", reviewID)
	}
	if _, err := tx.Exec(`INSERT INTO deps(task_id, depends_on) VALUES (?, ?)`, reviewID, f.ID); err != nil {
		return err
	}
	if _, err := tx.Exec(`INSERT INTO verdicts(task_id, reviewer, verdict, reason, created_at)
		VALUES (?, ?, 'fail', ?, ?)`, reviewID, reviewer, reason, now); err != nil {
		return err
	}
	if err := appendEventOn(tx, f.ID, reviewer, "ingest", fmt.Sprintf("fix generation %d", g), now); err != nil {
		return err
	}
	if err := appendEventOn(tx, reviewID, reviewer, "reject", fmt.Sprintf("gen%d -> %s", g, f.ID), now); err != nil {
		return err
	}
	return tx.Commit()
}
```

- [ ] **Step 4: Implement `internal/cli/donefail.go`**

Move the two stub functions out of `done.go` into this file and implement:

```go
package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"muster/internal/card"
	"muster/internal/store"
)

var fixStemRx = regexp.MustCompile(`^(.+-\d{2})-fix-(.+)\.md$`)
var fixGenRx = regexp.MustCompile(`-fix(\d+)-`)
var idLineRx = regexp.MustCompile(`(?m)^id: .*$`)

func (a *App) stagedFiles() []string {
	matches, _ := filepath.Glob(filepath.Join(a.Dir, "staging", "*.md"))
	return matches
}

// failCommitAndFile: shared terminal filing for the review cap and the
// integration fail - result sidecar with the fail verdict, one commit of the
// sidecars (commit-first), then MarkFailed + verdict row + backup.
func (a *App) failCommitAndFile(t *store.Task, c *card.Card, reason string, doneCheckPass bool) int {
	rel, err := a.writeResult(t, c, resultOpts{Status: "failed", Verdict: "fail", Attempts: -1, DoneCheckPass: doneCheckPass})
	if err != nil {
		return a.refuse("result sidecar failed: %v", err)
	}
	paths := []string{rel}
	for _, side := range []string{t.ID + ".notes.md", t.ID + ".verify.log"} {
		if p := ".muster/cards/" + side; fileExistsAt(a.Root, p) {
			paths = append(paths, p)
		}
	}
	if err := a.G.Add(paths); err != nil {
		return a.refuse("git add failed: %v", err)
	}
	if err := a.G.Commit(fmt.Sprintf("muster(%s): fail %s", t.Plan, t.ID), paths); err != nil {
		return a.refuse("fail commit failed: %v. DB untouched - fix git state and rerun.", err)
	}
	if err := a.St.MarkFailed(t.ID, t.ClaimedBy, reason, a.iso()); err != nil {
		return a.refuse("commit landed but the DB flip failed: %v", err)
	}
	a.St.InsertVerdict(t.ID, t.ClaimedBy, "fail", reason, a.iso())
	a.backupDB()
	return -1 // caller prints its terminal line and exit code
}

// resumeReject: crash-resume for the reject path (Authority note 7). A
// committed, stamped fix card targeting the reviewed impl with no DB row
// means the reject commit landed and the DB half was lost - complete it.
func (a *App) resumeReject(t *store.Task, reason string) (bool, int) {
	matches, _ := filepath.Glob(filepath.Join(a.Dir, "cards", "*.md"))
	for _, m := range matches {
		raw, err := os.ReadFile(m)
		if err != nil {
			continue
		}
		fc, errs := card.Parse(string(raw), true)
		if len(errs) > 0 || fc.Type != "fix" || fc.Fixes != t.Reviews {
			continue
		}
		if row, _ := a.St.Task(fc.ID); row != nil {
			continue // already recorded
		}
		gm := fixGenRx.FindStringSubmatch(fc.ID)
		if gm == nil {
			continue // unstamped stray; doctor's territory
		}
		g := 0
		fmt.Sscanf(gm[1], "%d", &g)
		rel, _ := filepath.Rel(a.Root, m)
		fixRow := store.IngestTask{Task: store.Task{
			ID: fc.ID, Plan: fc.Plan, Seq: fc.Seq, Type: fc.Type, Tier: fc.Tier,
			Harness: fc.Harness, CardPath: filepath.ToSlash(rel),
			FrontmatterSHA: fc.FrontmatterSHA, Fixes: fc.Fixes,
		}, Deps: fc.DependsOn}
		if err := a.St.CycleReview(t.ID, t.ClaimedBy, reason, fixRow, g, a.iso()); err != nil {
			return true, a.refuse("crash-resume failed: %v", err)
		}
		a.backupDB()
		a.pf("Resumed crashed done fail: fix %s queued (generation %d of 2). Session over.", fc.ID, g)
		return true, 0
	}
	return false, 0
}

// doneFailReview: spec D-v2-5. Verdict + one staged fix -> lint-lite ->
// generation cap -> stamp -> reject commit -> DB cycle.
func (a *App) doneFailReview(t *store.Task, c *card.Card, reason string, doneCheckPass bool) int {
	implID := c.Reviews
	staged := a.stagedFiles()
	if len(staged) == 0 {
		if resumed, code := a.resumeReject(t, reason); resumed {
			return code
		}
	}
	if len(staged) != 1 {
		return a.refuse("done fail needs exactly one valid fix task in .muster/staging/ (found %d files). File left in place - fix it and rerun.", len(staged))
	}
	findings := card.Lint([]string{staged[0]}, a.existsOnBoard, card.Lite)
	raw, err := os.ReadFile(staged[0])
	if err != nil {
		return a.refuse("cannot read staged fix: %v", err)
	}
	fix, errs := card.Parse(string(raw), true)
	if len(errs) == 0 && fix.Fixes != implID {
		findings = append([]string{fmt.Sprintf("fixes '%s' does not match reviews '%s'", fix.Fixes, implID)}, findings...)
	}
	if len(findings) > 0 {
		return a.refuse("done fail needs exactly one valid fix task in .muster/staging/ (%s). File left in place - fix it and rerun.", findings[0])
	}
	// generation cap: two landed generations = human territory (D11)
	g, err := a.St.FixGeneration(implID)
	if err != nil {
		return a.refuse("generation query failed: %v", err)
	}
	if g >= 3 {
		os.Remove(staged[0])
		if code := a.failCommitAndFile(t, c, reason, doneCheckPass); code != -1 {
			return code
		}
		a.pf("Review cap hit (2 fix generations). %s chain needs a human. Session over.", implID)
		return 3
	}
	// stamp: filename, id line, title (generation stays OUT of frontmatter)
	base := filepath.Base(staged[0])
	m := fixStemRx.FindStringSubmatch(base)
	if m == nil {
		return a.refuse("staged fix filename malformed: %s.", base)
	}
	fixID := fmt.Sprintf("%s-fix%d-%s", m[1], g, m[2])
	text := string(raw)
	text = idLineRx.ReplaceAllString(text, "id: "+fixID)
	text = strings.Replace(text, "# "+fix.ID+":", "# "+fixID+":", 1)
	fixRel := ".muster/cards/" + fixID + ".md"
	if err := os.WriteFile(filepath.Join(a.Root, filepath.FromSlash(fixRel)), []byte(text), 0o644); err != nil {
		return a.refuse("cannot write stamped fix card: %v", err)
	}
	os.Remove(staged[0])
	// this round's sidecars become gen-suffixed history (plain renames: none
	// of these files are tracked yet)
	genSuffix := fmt.Sprintf(".gen%d", g)
	logOld := filepath.Join(a.Dir, "cards", t.ID+".verify.log")
	logNewRel := ".muster/cards/" + t.ID + genSuffix + ".verify.log"
	hadLog := false
	if _, err := os.Stat(logOld); err == nil {
		os.Rename(logOld, filepath.Join(a.Root, filepath.FromSlash(logNewRel)))
		hadLog = true
	}
	genResultRel, err := a.writeResult(t, c, resultOpts{Status: "cycled", Verdict: "fail",
		Attempts: -1, DoneCheckPass: doneCheckPass, GenSuffix: genSuffix})
	if err != nil {
		return a.refuse("gen result sidecar failed: %v", err)
	}
	notesOld := filepath.Join(a.Dir, "cards", t.ID+".notes.md")
	notesNewRel := ".muster/cards/" + t.ID + genSuffix + ".notes.md"
	hadNotes := false
	if _, err := os.Stat(notesOld); err == nil {
		os.Rename(notesOld, filepath.Join(a.Root, filepath.FromSlash(notesNewRel)))
		hadNotes = true
	}
	// ONE reject commit (commit-first)
	paths := []string{fixRel, genResultRel}
	if hadLog {
		paths = append(paths, logNewRel)
	}
	if hadNotes {
		paths = append(paths, notesNewRel)
	}
	if err := a.G.Add(paths); err != nil {
		return a.refuse("git add failed: %v", err)
	}
	if err := a.G.Commit(fmt.Sprintf("muster(%s): reject %s gen%d", t.Plan, implID, g), paths); err != nil {
		return a.refuse("reject commit failed: %v. DB untouched - fix git state and rerun done fail.", err)
	}
	// DB half (crash after the commit above resumes via resumeReject)
	stamped, _ := card.Parse(text, true)
	fixRow := store.IngestTask{Task: store.Task{
		ID: fixID, Plan: stamped.Plan, Seq: stamped.Seq, Type: stamped.Type, Tier: stamped.Tier,
		Harness: stamped.Harness, CardPath: fixRel,
		FrontmatterSHA: stamped.FrontmatterSHA, Fixes: stamped.Fixes,
	}, Deps: stamped.DependsOn}
	if err := a.St.CycleReview(t.ID, t.ClaimedBy, reason, fixRow, g, a.iso()); err != nil {
		return a.refuse("reject commit landed but the DB cycle failed (%v) - rerun done fail to resume.", err)
	}
	a.backupDB()
	a.pf("Review failed. Fix %s queued (generation %d of 2). Session over.", fixID, g)
	return 0
}
```

Delete the `doneFailReview` and `doneFailIntegration` stubs from `done.go`
(`doneFailIntegration` gets its real body in Task 19 - for THIS task keep a
one-line stub in `donefail.go`):

```go
func (a *App) doneFailIntegration(t *store.Task, c *card.Card, reason string, doneCheckPass bool) int {
	return a.refuse("done fail (integration) is not implemented yet.")
}
```

- [ ] **Step 5: Run, verify pass**

Run: `go test ./internal/cli` and `go test ./internal/store`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/store/tasks.go internal/cli/donefail.go internal/cli/donefail_test.go internal/cli/done.go
git commit -m "feat(v2): done fail review path - staged fix, generation cap, cycle, crash-resume"
```

---

### Task 19: cli - done fail, integration path

**Files:**
- Modify: `internal/cli/donefail.go` (replace the integration stub)
- Modify: `internal/cli/donefail_test.go` (append)

- [ ] **Step 1: Append the failing tests**

```go
var integrationCardText = func() string {
	s := strings.NewReplacer(
		"id: demo-01-w", "id: demo-99-int",
		"type: impl", "type: integration",
		"tier: any", "tier: strong",
		"# demo-01-w: build w", "# demo-99-int: integrate",
	).Replace(claimCard)
	return strings.Replace(s, "protected:\n  - internal/w/w_test.go\ncommit_paths:\n  - internal/w/w.go\n  - internal/w/w_test.go\n  - internal/w\n", "", 1)
}()

func integrationFixture(t *testing.T) (*App, *fakeAndOut) {
	t.Helper()
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-99-int", integrationCardText, "inbox")
	if code := a.Dispatch("claim", []string{"-harness", "claude", "-tier", "strong"}); code != 0 {
		t.Fatalf("claim: %s", out.String())
	}
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-99-int.notes.md"), []byte("red suite"), 0o644)
	out.Reset()
	return a, &fakeAndOut{fake, out}
}

func TestDoneFailIntegrationFilesTheTask(t *testing.T) {
	a, fx := integrationFixture(t)
	code := a.Dispatch("done", []string{"fail", "-reason", "suite is red"})
	if code != 3 {
		t.Fatalf("code %d: %s", code, fx.out.String())
	}
	if !strings.Contains(fx.out.String(), "Integration review failed. Bring .muster/cards/demo-99-int.result.md to the orchestrator to shard a fix-up plan. Session over.") {
		t.Fatalf("out: %s", fx.out.String())
	}
	row, _ := a.St.Task("demo-99-int")
	if row.Status != "failed" {
		t.Fatalf("status: %s", row.Status)
	}
	if len(fx.fake.Commits) != 1 || fx.fake.Commits[0].Msg != "muster(demo): fail demo-99-int" {
		t.Fatalf("commits: %+v", fx.fake.Commits)
	}
	vs, _ := a.St.Verdicts("demo-99-int")
	if len(vs) != 1 || vs[0].Verdict != "fail" || vs[0].Reason != "suite is red" {
		t.Fatalf("verdicts: %+v", vs)
	}
	raw, _ := os.ReadFile(filepath.Join(a.Dir, "cards", "demo-99-int.result.md"))
	if !strings.Contains(string(raw), "- status: failed") {
		t.Fatalf("result: %s", raw)
	}
}

func TestDoneFailIntegrationRefusesStagedFix(t *testing.T) {
	a, fx := integrationFixture(t)
	os.WriteFile(filepath.Join(a.Dir, "staging", "demo-01-fix-w.md"), []byte(stagedFixText), 0o644)
	if code := a.Dispatch("done", []string{"fail", "-reason", "r"}); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(fx.out.String(), "integration done fail accepts no fix task - clear .muster/staging/.") {
		t.Fatalf("out: %s", fx.out.String())
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/cli`
Expected: FAIL (stub refuses with the wrong message).

- [ ] **Step 3: Implement - replace the integration stub in `donefail.go`**

```go
// doneFailIntegration: plan-level drift belongs to the orchestrator, not a
// fix task (v1 spec 4.3). Terminal: result + one fail commit + status failed.
func (a *App) doneFailIntegration(t *store.Task, c *card.Card, reason string, doneCheckPass bool) int {
	if len(a.stagedFiles()) > 0 {
		return a.refuse("integration done fail accepts no fix task - clear .muster/staging/.")
	}
	if code := a.failCommitAndFile(t, c, reason, doneCheckPass); code != -1 {
		return code
	}
	a.pf("Integration review failed. Bring .muster/cards/%s.result.md to the orchestrator to shard a fix-up plan. Session over.", t.ID)
	return 3
}
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/cli`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/cli/donefail.go internal/cli/donefail_test.go
git commit -m "feat(v2): done fail integration path - terminal filing, no fix card"
```

---
### Task 20: cli - human recovery verbs (redo / fail / reimport)

**Files:**
- Create: `internal/cli/human.go`
- Create: `internal/cli/human_test.go`
- Modify: `internal/store/tasks.go` (add `UpdateCard`)
- Modify: `internal/cli/app.go` (add `case "redo"`, `"fail"`, `"reimport"`)

These replace v1's file-move ritual (spec CLI table). `redo` grants fresh
attempts implicitly: the next claim event starts a new attempt window.

- [ ] **Step 1: Write the failing tests**

`internal/cli/human_test.go`:

```go
package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRedoFromDoingAndFailed(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	if code := a.Dispatch("redo", []string{"demo-01-w"}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "inbox" || row.ClaimedAt != "" {
		t.Fatalf("row: %+v", row)
	}
	if !strings.Contains(out.String(), "Redo: demo-01-w") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestRedoRefusesWrongStatus(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "done")
	if code := a.Dispatch("redo", []string{"demo-01-w"}); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "MUSTER refuse:") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestFailVerb(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	if code := a.Dispatch("fail", []string{"demo-01-w"}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	row, _ := a.St.Task("demo-01-w")
	if row.Status != "failed" {
		t.Fatalf("status: %s", row.Status)
	}
}

func TestReimportRehashesAndRewiresDeps(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "done")
	seedClaimable(t, a, fake, "demo-02-x", strings.NewReplacer("demo-01-w", "demo-02-x").Replace(claimCard), "backlog")
	// deliberate edit: demo-02-x now depends on demo-01-w and goes strong
	edited := strings.NewReplacer("demo-01-w", "demo-02-x").Replace(claimCard)
	edited = strings.Replace(edited, "tier: any", "tier: strong", 1)
	edited = strings.Replace(edited, "depends_on: []", "depends_on:\n  - demo-01-w", 1)
	if err := os.WriteFile(filepath.Join(a.Dir, "cards", "demo-02-x.md"), []byte(edited), 0o644); err != nil {
		t.Fatal(err)
	}
	if code := a.Dispatch("reimport", []string{"demo-02-x"}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	row, _ := a.St.Task("demo-02-x")
	if row.Tier != "strong" {
		t.Fatalf("tier not refreshed: %+v", row)
	}
	deps, _ := a.St.Deps("demo-02-x")
	if len(deps) != 1 || deps[0] != "demo-01-w" {
		t.Fatalf("deps: %v", deps)
	}
	evs, _ := a.St.Events("demo-02-x")
	last := evs[len(evs)-1]
	if last.Verb != "reimport" {
		t.Fatalf("event: %+v", last)
	}
}

func TestReimportRefusesDoingAndLintFailures(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-01-w.md"), []byte(claimCard), 0o644)
	if code := a.Dispatch("reimport", []string{"demo-01-w"}); code != 1 {
		t.Fatal("doing must refuse")
	}
	if !strings.Contains(out.String(), "claimed task") {
		t.Fatalf("out: %s", out.String())
	}
	a2, fake2, out2 := newApp(t)
	_ = fake2
	seedClaimable(t, a2, fake2, "demo-01-w", claimCard, "backlog")
	bad := strings.Replace(claimCard, "## Context\nctx", "## Context\nTBD", 1)
	os.WriteFile(filepath.Join(a2.Dir, "cards", "demo-01-w.md"), []byte(bad), 0o644)
	if code := a2.Dispatch("reimport", []string{"demo-01-w"}); code != 1 {
		t.Fatal("lint failure must refuse")
	}
	if !strings.Contains(out2.String(), "LINT FAIL") {
		t.Fatalf("out: %s", out2.String())
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/cli`
Expected: FAIL.

- [ ] **Step 3: Add `UpdateCard` to `internal/store/tasks.go`**

```go
// UpdateCard refreshes the denormalized copy after a deliberate card edit
// (reimport): dispatch fields, sha, relations, and deps are replaced; id,
// plan, card_path, status, and claim fields are untouched. Deps fail closed.
func (s *Store) UpdateCard(id string, seq int, typ, tier, harness, sha, reviews, fixes string, deps []string, actor, now string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.Exec(`UPDATE tasks SET seq = ?, type = ?, tier = ?, harness = ?,
		frontmatter_sha = ?, reviews = ?, fixes = ? WHERE id = ?`,
		seq, typ, tier, harness, sha, reviews, fixes, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return fmt.Errorf("%s: not on the board", id)
	}
	if _, err := tx.Exec(`DELETE FROM deps WHERE task_id = ?`, id); err != nil {
		return err
	}
	for _, dep := range deps {
		var n int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM tasks WHERE id = ?`, dep).Scan(&n); err != nil {
			return err
		}
		if n == 0 {
			return fmt.Errorf("%s: depends_on '%s' exists nowhere - reimport fails closed", id, dep)
		}
		if _, err := tx.Exec(`INSERT INTO deps(task_id, depends_on) VALUES (?, ?)`, id, dep); err != nil {
			return err
		}
	}
	if err := appendEventOn(tx, id, actor, "reimport", "", now); err != nil {
		return err
	}
	return tx.Commit()
}
```

- [ ] **Step 4: Implement `internal/cli/human.go`**

```go
package cli

import (
	"os"
	"path/filepath"

	"muster/internal/card"
)

// Redo implements `muster redo <id>`: doing/failed -> inbox, fresh attempts.
func (a *App) Redo(args []string) int {
	if len(args) != 1 {
		return a.refuse("redo needs exactly one task id.")
	}
	id := args[0]
	if t, err := a.St.Task(id); err != nil || t == nil {
		return a.refuse("no task '%s' on the board.", id)
	}
	if err := a.St.MarkInbox(id, "human", a.iso()); err != nil {
		return a.refuse("cannot redo %s: %v (redo takes a doing or failed task).", id, err)
	}
	a.pf("Redo: %s back in inbox with a fresh attempt budget. Leave the working tree alone - the next claim's probe auto-files finished work.", id)
	return 0
}

// Fail implements `muster fail <id>`: give up, keep the evidence.
func (a *App) Fail(args []string) int {
	if len(args) != 1 {
		return a.refuse("fail needs exactly one task id.")
	}
	id := args[0]
	if t, err := a.St.Task(id); err != nil || t == nil {
		return a.refuse("no task '%s' on the board.", id)
	}
	if err := a.St.MarkFailed(id, "human", "human fail verb", a.iso()); err != nil {
		return a.refuse("cannot fail %s: %v.", id, err)
	}
	a.pf("Failed: %s. Card, sidecars, and any working-tree dirt left in place as evidence.", id)
	return 0
}

// Reimport implements `muster reimport <id>`: the sanctioned card-edit path -
// re-lint (single mode), re-hash, refresh the denormalized copy and deps.
func (a *App) Reimport(args []string) int {
	if len(args) != 1 {
		return a.refuse("reimport needs exactly one task id.")
	}
	id := args[0]
	t, err := a.St.Task(id)
	if err != nil || t == nil {
		return a.refuse("no task '%s' on the board.", id)
	}
	if t.Status == "doing" {
		return a.refuse("cannot reimport a claimed task - finish or redo it first.")
	}
	abs := filepath.Join(a.Root, filepath.FromSlash(t.CardPath))
	if _, err := os.Stat(abs); err != nil {
		return a.refuse("card file missing on disk: %s.", t.CardPath)
	}
	notSelf := func(x string) bool { return x != id && a.existsOnBoard(x) }
	if findings := card.Lint([]string{abs}, notSelf, card.Single); len(findings) > 0 {
		for _, f := range findings {
			a.pf("LINT FAIL %s", f)
		}
		return 1
	}
	raw, err := os.ReadFile(abs)
	if err != nil {
		return a.refuse("cannot read %s: %v", t.CardPath, err)
	}
	c, errs := card.Parse(string(raw), false)
	if len(errs) > 0 {
		return a.refuse("%s: %s", id, errs[0])
	}
	if err := a.St.UpdateCard(id, c.Seq, c.Type, c.Tier, c.Harness, c.FrontmatterSHA,
		c.Reviews, c.Fixes, c.DependsOn, "human", a.iso()); err != nil {
		return a.refuse("reimport failed: %v", err)
	}
	a.pf("Reimported %s: card re-linted and re-hashed. Commit the card edit if you have not already.", id)
	return 0
}
```

In `internal/cli/app.go` Dispatch, add:

```go
	case "redo":
		return a.Redo(args)
	case "fail":
		return a.Fail(args)
	case "reimport":
		return a.Reimport(args)
	case "promote":
		promoted, err := a.St.Promote("system", a.iso())
		if err != nil {
			return a.refuse("promote failed: %v", err)
		}
		a.pf("Promoted %d task(s).", len(promoted))
		return 0
```

(the `promote` case is two lines of glue - fold it into this task rather than
carrying a task of its own).

- [ ] **Step 5: Run, verify pass**

Run: `go test ./internal/cli` and `go test ./internal/store`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/cli/human.go internal/cli/human_test.go internal/store/tasks.go internal/cli/app.go
git commit -m "feat(v2): human verbs - redo/fail/reimport + promote glue"
```

---

### Task 21: cli - doctor

**Files:**
- Create: `internal/cli/doctor.go`
- Create: `internal/cli/doctor_test.go`
- Modify: `internal/cli/app.go` (add `case "doctor"`)

The 2am verb (spec failure matrix): every check prints `DOCTOR FAIL <area>:
<detail>`; a clean board prints `DOCTOR OK - board consistent.` Exit 1 on any
finding, else 0.

- [ ] **Step 1: Write the failing tests**

`internal/cli/doctor_test.go`:

```go
package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDoctorCleanBoard(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	// card exists on disk and at HEAD with the ingested sha
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-01-w.md"), []byte(claimCard), 0o644)
	if code := a.Dispatch("doctor", nil); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	if !strings.Contains(out.String(), "DOCTOR OK - board consistent.") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestDoctorFindsChainTamper(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox")
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-01-w.md"), []byte(claimCard), 0o644)
	a.St.DB().Exec(`INSERT INTO events(task_id, actor, verb, detail, created_at, prev_hash, hash)
		VALUES ('demo-01-w', 'gremlin', 'done', '', 'x', 'bad', 'forged')`)
	if code := a.Dispatch("doctor", nil); code != 1 {
		t.Fatal("must fail")
	}
	if !strings.Contains(out.String(), "DOCTOR FAIL events:") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestDoctorFindsMissingAndOrphanCards(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "inbox") // no disk file: missing
	orphan := strings.NewReplacer("demo-01-w", "demo-07-orphan").Replace(claimCard)
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-07-orphan.md"), []byte(orphan), 0o644)
	if code := a.Dispatch("doctor", nil); code != 1 {
		t.Fatal("must fail")
	}
	s := out.String()
	if !strings.Contains(s, "DOCTOR FAIL cards: demo-01-w has no file on disk") {
		t.Fatalf("missing-card finding absent:\n%s", s)
	}
	if !strings.Contains(s, "DOCTOR FAIL cards: demo-07-orphan.md has no board row") {
		t.Fatalf("orphan finding absent:\n%s", s)
	}
}

func TestDoctorFindsShaDriftStaleDoingAndStaging(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-01-w.md"), []byte(claimCard), 0o644)
	a.St.DB().Exec(`UPDATE tasks SET frontmatter_sha='stale', claimed_at='2025-12-01T00:00:00Z' WHERE id='demo-01-w'`)
	os.WriteFile(filepath.Join(a.Dir, "staging", "stray.md"), []byte("x"), 0o644)
	if code := a.Dispatch("doctor", nil); code != 1 {
		t.Fatal("must fail")
	}
	s := out.String()
	for _, want := range []string{
		"DOCTOR FAIL drift: demo-01-w frontmatter sha differs from HEAD",
		"DOCTOR FAIL claims: demo-01-w doing since 2025-12-01T00:00:00Z",
		"DOCTOR FAIL staging: stray.md",
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %q:\n%s", want, s)
		}
	}
}

func TestDoctorFindsUnreconciledDone(t *testing.T) {
	a, fake, out := newApp(t)
	seedClaimable(t, a, fake, "demo-01-w", claimCard, "doing")
	os.WriteFile(filepath.Join(a.Dir, "cards", "demo-01-w.md"), []byte(claimCard), 0o644)
	a.St.DB().Exec(`UPDATE tasks SET head_at_claim='head0', claimed_at='2026-01-02T00:00:00Z' WHERE id='demo-01-w'`)
	fake.GrepSHAs = []string{"deadbeef"}
	if code := a.Dispatch("doctor", nil); code != 1 {
		t.Fatal("must fail")
	}
	if !strings.Contains(out.String(), "DOCTOR FAIL drift: demo-01-w has a done commit but status doing") {
		t.Fatalf("out: %s", out.String())
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/cli`
Expected: FAIL.

- [ ] **Step 3: Implement**

`internal/cli/doctor.go`:

```go
package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"muster/internal/card"
)

var sidecarRx = regexp.MustCompile(`\.result\.md$|\.notes\.md$|\.verify\.log$|\.gen\d+\.`)

// Doctor implements `muster doctor`: chain verification, integrity check,
// stale claims, card/db drift, staging strays (spec CLI table).
func (a *App) Doctor() int {
	var findings []string
	fail := func(area, format string, args ...any) {
		findings = append(findings, "DOCTOR FAIL "+area+": "+fmt.Sprintf(format, args...))
	}

	// 1. sqlite integrity
	var integrity string
	if err := a.St.DB().QueryRow("PRAGMA integrity_check").Scan(&integrity); err != nil || integrity != "ok" {
		fail("sqlite", "integrity_check: %s %v", integrity, err)
	}
	// 2. event chain
	if err := a.St.VerifyChain(); err != nil {
		fail("events", "%v", err)
	}
	// 3-6. per-row checks
	for _, status := range []string{"backlog", "inbox", "doing", "done", "failed"} {
		rows, err := a.St.TasksByStatus(status)
		if err != nil {
			fail("query", "%v", err)
			continue
		}
		for _, t := range rows {
			abs := filepath.Join(a.Root, filepath.FromSlash(t.CardPath))
			if _, err := os.Stat(abs); err != nil {
				fail("cards", "%s has no file on disk (%s)", t.ID, t.CardPath)
			}
			if body, err := a.G.ShowAtHead(t.CardPath); err == nil {
				if c, errs := card.Parse(body, false); len(errs) == 0 && c.FrontmatterSHA != t.FrontmatterSHA {
					fail("drift", "%s frontmatter sha differs from HEAD - deliberate edits go through muster reimport", t.ID)
				}
			} else if status != "backlog" { // backlog cards may await the shard commit
				fail("cards", "%s not committed at HEAD", t.ID)
			}
			if status == "doing" {
				if t.ClaimedAt != "" {
					if then, err := time.Parse("2006-01-02T15:04:05Z", t.ClaimedAt); err == nil &&
						a.Now().UTC().Sub(then).Hours() > 24 {
						fail("claims", "%s doing since %s - stale claim, see RECOVERY", t.ID, t.ClaimedAt)
					}
				}
				if t.HeadAtClaim != "" {
					shas, err := a.G.LogGrep("^muster("+t.Plan+"): done "+t.ID+"$", t.HeadAtClaim+"..HEAD")
					if err == nil && len(shas) > 0 {
						fail("drift", "%s has a done commit but status doing - run muster claim to reconcile", t.ID)
					}
				}
			}
		}
	}
	// 7. orphan card files
	matches, _ := filepath.Glob(filepath.Join(a.Dir, "cards", "*.md"))
	for _, m := range matches {
		name := filepath.Base(m)
		if sidecarRx.MatchString(name) {
			continue
		}
		id := name[:len(name)-3]
		if t, _ := a.St.Task(id); t == nil {
			fail("cards", "%s has no board row - ingest it or delete it", name)
		}
	}
	// 8. staging strays
	for _, s := range a.stagedFiles() {
		fail("staging", "%s - stale staged fix from a crashed review session; safe to delete", filepath.Base(s))
	}

	if len(findings) == 0 {
		a.pf("DOCTOR OK - board consistent.")
		return 0
	}
	for _, f := range findings {
		a.pf("%s", f)
	}
	a.pf("DOCTOR: %d finding(s).", len(findings))
	return 1
}
```

In `internal/cli/app.go` Dispatch, add:

```go
	case "doctor":
		return a.Doctor()
```

NOTE: `TestDoctorCleanBoard` requires the fake's `GrepSHAs` to be nil (it is by
default) and the HEAD card registered by `seedClaimable` - the sha matches, no
drift. The staging glob in `stagedFiles` picks up `stray.md` in the fourth test.

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/cli`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/cli/doctor.go internal/cli/doctor_test.go internal/cli/app.go
git commit -m "feat(v2): doctor verb - chain/integrity/drift/staleness checks"
```

---
### Task 22: RUNNER.md v2 + embedded init templates

**Files:**
- Create: `internal/cli/templates/RUNNER.md`
- Create: `internal/cli/templates/muster.gitignore`
- Create: `internal/cli/templates/muster.gitattributes`
- Create: `internal/cli/templates.go`
- Create: `internal/cli/templates_test.go`

RUNNER.md v2 is the near-verbatim v1 contract (spec section 6): same five
verbs, same hard rules, `Session over.` still the only stop signal. Changes
ONLY: invocations become `muster <verb>`, the notes path moves to
`.muster/cards/`, RECOVERY shrinks to the new verbs.

- [ ] **Step 1: Write the failing test**

`internal/cli/templates_test.go`:

```go
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
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/cli`
Expected: FAIL (undefined: RunnerMD).

- [ ] **Step 3: Write the templates**

`internal/cli/templates.go`:

```go
package cli

import _ "embed"

//go:embed templates/RUNNER.md
var RunnerMD string

//go:embed templates/muster.gitignore
var GitignoreTemplate string

//go:embed templates/muster.gitattributes
var GitattributesTemplate string
```

`internal/cli/templates/muster.gitignore`:

```
muster.db
muster.db-wal
muster.db-shm
backup.db
```

`internal/cli/templates/muster.gitattributes`:

```
* text=auto eol=lf
*.db binary -text
```

`internal/cli/templates/RUNNER.md` (full content):

```markdown
# RUNNER - executor contract (MUSTER v2)

You are an executor. Your whole job is five verbs, in order. Do not improvise,
do not optimize, do not skip.

All verbs are subcommands of the `muster` binary (on PATH, or `./muster.exe`
at the repo root). Run them from the repository root.

1. **CLAIM** - run the claim command exactly as your dispatch line told you
   (it carries your identity flags). It prints your task. If it prints a line
   starting `MUSTER refuse:`, STOP - report that line verbatim and end the
   session.

2. **DO** - follow the task's Steps section exactly, in order. Touch only the
   files the task names. The task card is read-only - never edit it, and never
   touch `.muster/muster.db` or anything else under `.muster/` except the
   files this contract or your task names: your notes file (step 4), and on a
   review task the one staged fix its Steps tell you to author into
   `.muster/staging/`. Nothing else under `.muster/`, ever.

3. **VERIFY** - run `muster verify`. `VERIFY PASS` = go to step 4.
   `VERIFY FAIL ... Fix and rerun` = fix your work, run it again. It stops you
   after 3 attempts - if it says terminal, STOP and end the session. Never
   edit test files or anything the task lists as protected.
   On a review task a verify failure is NOT yours to fix - you changed no
   code, so the environment is broken: write what you saw to the notes file
   and STOP.
   On an integration task a failing verify IS a finding: write it to the
   notes file and run `muster done fail --reason "<one line>"` - the command
   records the red check and files the task.

4. **REPORT** - write `.muster/cards/<task-id>.notes.md`: one short paragraph
   of anything a reviewer should know (surprises, workarounds, doubts).
   Nothing to report on an impl task = skip the file. On a review or
   integration task the notes file is your findings and is required.

5. **DONE** - run `muster done` (review and integration tasks:
   `muster done pass` or `muster done fail --reason "<one line>"`). It
   commits everything itself.

Any command output ending `Session over.` means exactly that: end the
session. It is the only stop signal; there are no others to interpret.

## Hard rules

- Never run `git add`, `git commit`, `git push`, or any git write - the
  muster binary owns all commits.
- One task per session. When done says session over, you are done - do not
  claim again.
- Blocked, confused, or the task contradicts the repo? Write what you know to
  the notes file and STOP. A stale claim is detected automatically; guessing
  is not recoverable.
- Commands refusing is normal operation, not an error to work around. Report
  the message and stop.

## RECOVERY (humans only)

Executors: this section is not for you. Your job ended at the refusal
message - report it and stop.

- `muster board` prints the whole board; a stale claim (doing older than 24h)
  is flagged in every claim's status print.
- `muster doctor` checks the event chain, db-vs-git drift, orphaned files,
  and stale claims.
- `muster redo <id>` sends a doing or failed task back to inbox and grants a
  fresh 3 verify attempts. Leave the working tree alone - the next claim's
  recovery probe detects finished work and auto-files it.
- `muster fail <id>` gives up on a task: status failed, evidence left in
  place (card, sidecars, and any working-tree dirt).
- A stale file in `.muster/staging/` (crashed review session) is safe to
  delete; `muster doctor` lists it.
- Never edit `.muster/muster.db` by hand, and never edit a card file in
  place - a deliberate card edit is committed and then registered with
  `muster reimport <id>`.
- A crash between done's commit and the board update heals itself: the next
  `muster claim` finds the done commit and files the task.
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/cli` (and `go build ./...` to prove the embeds resolve)
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/cli/templates/RUNNER.md internal/cli/templates/muster.gitignore internal/cli/templates/muster.gitattributes internal/cli/templates.go internal/cli/templates_test.go
git commit -m "feat(v2): RUNNER.md v2 + embedded init templates"
```

---

### Task 23: cli - init verb (preflight, install, v1 decommission)

**Files:**
- Create: `internal/cli/initcmd.go`
- Create: `internal/cli/init_test.go`
- Modify: `internal/cli/app.go` (delete the Task 11 `Init` stub)

Spec D-v2-3 exactly: refuse on a live v1 tree using v1's own task-file
semantics; decommission a dead one (stub `tasks/bin/*`, rewrite the CLAUDE.md
pointer); `.gitkeep`s and orphaned verify.log/notes.md never false-positive.

- [ ] **Step 1: Write the failing tests**

`internal/cli/init_test.go`:

```go
package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"muster/internal/gitx"
)

// newInitApp: an App over a bare temp root with NO .muster/ yet.
func newInitApp(t *testing.T) (*App, *gitx.Fake, *bytes.Buffer) {
	t.Helper()
	root := t.TempDir()
	fake := &gitx.Fake{HeadSHA: "head0", BranchName: "main", UserOK: true, HeadFiles: map[string]string{}}
	out := &bytes.Buffer{}
	return &App{
		Root: root, Dir: filepath.Join(root, ".muster"), G: fake, Out: out,
		Now:    func() time.Time { return time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC) },
		Getenv: func(string) string { return "" },
	}, fake, out
}

func TestInitFreshInstall(t *testing.T) {
	a, fake, out := newInitApp(t)
	if code := a.Init(nil); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	for _, rel := range []string{
		".muster/cards", ".muster/staging", ".muster/plans",
		".muster/.gitignore", ".muster/.gitattributes", ".muster/RUNNER.md",
		".muster/muster.db",
	} {
		if _, err := os.Stat(filepath.Join(a.Root, filepath.FromSlash(rel))); err != nil {
			t.Fatalf("missing %s", rel)
		}
	}
	if len(fake.Commits) != 1 || fake.Commits[0].Msg != "muster: init" {
		t.Fatalf("commits: %+v", fake.Commits)
	}
	claude, _ := os.ReadFile(filepath.Join(a.Root, "CLAUDE.md"))
	if !strings.Contains(string(claude), ".muster/ is managed by MUSTER v2") {
		t.Fatalf("pointer missing:\n%s", claude)
	}
	if !strings.Contains(out.String(), "muster claim -harness claude -tier any") {
		t.Fatalf("dispatch lines missing:\n%s", out.String())
	}
}

func TestInitRefusesTwice(t *testing.T) {
	a, _, out := newInitApp(t)
	if code := a.Init(nil); code != 0 {
		t.Fatalf("first: %s", out.String())
	}
	if code := a.Init(nil); code != 1 {
		t.Fatal("second must refuse")
	}
	if !strings.Contains(out.String(), "already exists") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestInitRefusesMissingIdentity(t *testing.T) {
	a, fake, out := newInitApp(t)
	fake.UserOK = false
	if code := a.Init(nil); code != 1 {
		t.Fatal("must refuse")
	}
	if !strings.Contains(out.String(), "git identity missing") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestInitSyncRootGuard(t *testing.T) {
	a, fake, out := newInitApp(t)
	_ = fake
	sub := filepath.Join(a.Root, "OneDrive", "repo")
	os.MkdirAll(sub, 0o755)
	a.Root = sub
	a.Dir = filepath.Join(sub, ".muster")
	if code := a.Init(nil); code != 1 {
		t.Fatal("sync root must refuse without -sync-ok")
	}
	if !strings.Contains(out.String(), "sync engine") {
		t.Fatalf("out: %s", out.String())
	}
	out.Reset()
	if code := a.Init([]string{"-sync-ok"}); code != 0 {
		t.Fatalf("-sync-ok must proceed: %s", out.String())
	}
}

func makeV1Tree(t *testing.T, root string, live bool) {
	t.Helper()
	for _, d := range []string{"inbox", "backlog", "doing", "done", "failed", "archive", "staging", "bin"} {
		os.MkdirAll(filepath.Join(root, "tasks", d), 0o755)
		os.WriteFile(filepath.Join(root, "tasks", d, ".gitkeep"), nil, 0o644)
	}
	os.WriteFile(filepath.Join(root, "tasks", "bin", "claim.ps1"), []byte("# v1 claim"), 0o644)
	os.WriteFile(filepath.Join(root, "tasks", "bin", "claim.sh"), []byte("# v1 claim"), 0o644)
	os.WriteFile(filepath.Join(root, "tasks", "RUNNER.md"), []byte("# v1 runner"), 0o644)
	// orphaned sidecars must never count as live
	os.WriteFile(filepath.Join(root, "tasks", "doing", "old.verify.log"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(root, "tasks", "doing", "old.notes.md"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(root, "tasks", "done", "p-01-a.md"), []byte("done card"), 0o644)
	os.WriteFile(filepath.Join(root, "CLAUDE.md"), []byte(
		"Task board: `tasks/` is managed by MUSTER. Executors follow `tasks/RUNNER.md` exactly. Never edit files under `tasks/` by hand; the `tasks/bin/` scripts own all state transitions.\n"), 0o644)
	if live {
		os.WriteFile(filepath.Join(root, "tasks", "inbox", "p-02-b.md"), []byte("live card"), 0o644)
	}
}

func TestInitRefusesLiveV1(t *testing.T) {
	a, _, out := newInitApp(t)
	makeV1Tree(t, a.Root, true)
	if code := a.Init(nil); code != 1 {
		t.Fatal("live v1 must refuse")
	}
	s := out.String()
	if !strings.Contains(s, "tasks/inbox/p-02-b.md") {
		t.Fatalf("refusal must name the live files:\n%s", s)
	}
	if !strings.Contains(s, "v1 board is live") {
		t.Fatalf("out: %s", s)
	}
	if _, err := os.Stat(a.Dir); err == nil {
		t.Fatal("refusal must not half-install")
	}
}

func TestInitDecommissionsDeadV1(t *testing.T) {
	a, fake, out := newInitApp(t)
	makeV1Tree(t, a.Root, false)
	if code := a.Init(nil); code != 0 {
		t.Fatalf("dead v1 must install: %s", out.String())
	}
	stub, _ := os.ReadFile(filepath.Join(a.Root, "tasks", "bin", "claim.ps1"))
	if !strings.Contains(string(stub), "MUSTER refuse: v1 board decommissioned") {
		t.Fatalf("ps1 stub wrong:\n%s", stub)
	}
	stubSh, _ := os.ReadFile(filepath.Join(a.Root, "tasks", "bin", "claim.sh"))
	if !strings.Contains(string(stubSh), "MUSTER refuse: v1 board decommissioned") {
		t.Fatalf("sh stub wrong:\n%s", stubSh)
	}
	claude, _ := os.ReadFile(filepath.Join(a.Root, "CLAUDE.md"))
	s := string(claude)
	if strings.Contains(s, "tasks/ is managed by MUSTER.") {
		t.Fatalf("v1 pointer must be gone:\n%s", s)
	}
	if !strings.Contains(s, ".muster/ is managed by MUSTER v2") {
		t.Fatalf("v2 pointer missing:\n%s", s)
	}
	joined := strings.Join(fake.Commits[0].Paths, " ")
	if !strings.Contains(joined, "tasks/bin/claim.ps1") || !strings.Contains(joined, "CLAUDE.md") {
		t.Fatalf("stubs and pointer must be committed: %v", fake.Commits[0].Paths)
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test ./internal/cli`
Expected: FAIL (Init stub refuses everything).

- [ ] **Step 3: Implement**

Delete the `Init` stub from `internal/cli/app.go`. `internal/cli/initcmd.go`:

```go
package cli

import (
	"flag"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"muster/internal/store"
)

const v2Pointer = "Task board: `.muster/` is managed by MUSTER v2. Executors follow `.muster/RUNNER.md` exactly. All board state lives in `.muster/muster.db`; the `muster` CLI owns every state transition and every board commit. Never edit `.muster/` contents or the database by hand."

const v1Pointer = "Task board: `tasks/` is managed by MUSTER. Executors follow `tasks/RUNNER.md` exactly. Never edit files under `tasks/` by hand; the `tasks/bin/` scripts own all state transitions."

const stubPs1 = "Write-Output 'MUSTER refuse: v1 board decommissioned - this repo is managed by MUSTER v2 (.muster/ + muster CLI). See .muster/RUNNER.md.'\nexit 1\n"
const stubSh = "echo 'MUSTER refuse: v1 board decommissioned - this repo is managed by MUSTER v2 (.muster/ + muster CLI). See .muster/RUNNER.md.'\nexit 1\n"

// v1LiveFiles applies v1's own task-file semantics (spec D-v2-3): *.md minus
// *.result.md/*.notes.md in the five live folders, plus plan snapshots at the
// tasks root. Returns repo-relative paths, sorted.
func v1LiveFiles(root string) []string {
	var live []string
	for _, folder := range []string{"inbox", "backlog", "doing", "staging", "failed"} {
		matches, _ := filepath.Glob(filepath.Join(root, "tasks", folder, "*.md"))
		for _, m := range matches {
			name := filepath.Base(m)
			if strings.HasSuffix(name, ".result.md") || strings.HasSuffix(name, ".notes.md") {
				continue
			}
			live = append(live, "tasks/"+folder+"/"+name)
		}
	}
	matches, _ := filepath.Glob(filepath.Join(root, "tasks", "plan-*.md"))
	for _, m := range matches {
		live = append(live, "tasks/"+filepath.Base(m))
	}
	sort.Strings(live)
	return live
}

// Init implements `muster init` (spec CLI table).
func (a *App) Init(args []string) int {
	fs := flag.NewFlagSet("init", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	syncOK := fs.Bool("sync-ok", false, "")
	_ = fs.Parse(args)

	// preflight
	if ok, err := a.G.UserConfigured(); err != nil || !ok {
		return a.refuse("git identity missing - set user.name and user.email (the muster binary commits).")
	}
	if _, err := os.Stat(a.Dir); err == nil {
		return a.refuse(".muster/ already exists - MUSTER v2 appears installed. Nothing changed.")
	}
	if !*syncOK {
		for _, s := range []string{"OneDrive", "Dropbox", "Google Drive"} {
			if strings.Contains(a.Root, s) {
				return a.refuse("repo sits under a sync engine (%s) - sync duplication corrupts boards. Rerun with -sync-ok to accept the risk.", s)
			}
		}
	}
	hasV1 := false
	if _, err := os.Stat(filepath.Join(a.Root, "tasks", "bin")); err == nil {
		hasV1 = true
	}
	if hasV1 {
		if live := v1LiveFiles(a.Root); len(live) > 0 {
			for _, f := range live {
				a.pf("  live: %s", f)
			}
			return a.refuse("v1 board is live (%d task files above). Finish or /muster:close the v1 plans, then rerun muster init.", len(live))
		}
	}

	// install
	for _, d := range []string{"cards", "staging", "plans"} {
		if err := os.MkdirAll(filepath.Join(a.Dir, d), 0o755); err != nil {
			return a.refuse("cannot create .muster/%s: %v", d, err)
		}
	}
	writes := map[string]string{
		".gitignore":     GitignoreTemplate,
		".gitattributes": GitattributesTemplate,
		"RUNNER.md":      RunnerMD,
	}
	for name, content := range writes {
		if err := os.WriteFile(filepath.Join(a.Dir, name), []byte(content), 0o644); err != nil {
			return a.refuse("cannot write .muster/%s: %v", name, err)
		}
	}
	st, err := store.Open(filepath.Join(a.Dir, "muster.db"))
	if err != nil {
		return a.refuse("cannot create board db: %v", err)
	}
	if a.St == nil {
		a.St = st
	} else {
		st.Close()
	}

	commitPaths := []string{".muster/.gitignore", ".muster/.gitattributes", ".muster/RUNNER.md"}

	// decommission a dead v1 tree (spec D-v2-3: close the stale-dispatch window)
	decommissioned := []string{}
	if hasV1 {
		matches, _ := filepath.Glob(filepath.Join(a.Root, "tasks", "bin", "*.ps1"))
		for _, m := range matches {
			os.WriteFile(m, []byte(stubPs1), 0o644)
			rel := "tasks/bin/" + filepath.Base(m)
			decommissioned = append(decommissioned, rel)
		}
		matches, _ = filepath.Glob(filepath.Join(a.Root, "tasks", "bin", "*.sh"))
		for _, m := range matches {
			os.WriteFile(m, []byte(stubSh), 0o644)
			rel := "tasks/bin/" + filepath.Base(m)
			decommissioned = append(decommissioned, rel)
		}
		commitPaths = append(commitPaths, decommissioned...)
	}

	// CLAUDE.md pointer: replace the v1 paragraph when present, else append
	claudePath := filepath.Join(a.Root, "CLAUDE.md")
	existing := ""
	if raw, err := os.ReadFile(claudePath); err == nil {
		existing = string(raw)
	}
	if strings.Contains(existing, v1Pointer) {
		existing = strings.Replace(existing, v1Pointer, v2Pointer, 1)
	} else {
		if existing != "" && !strings.HasSuffix(existing, "\n") {
			existing += "\n"
		}
		if existing != "" {
			existing += "\n"
		}
		existing += v2Pointer + "\n"
	}
	if err := os.WriteFile(claudePath, []byte(existing), 0o644); err != nil {
		return a.refuse("cannot write CLAUDE.md: %v", err)
	}
	commitPaths = append(commitPaths, "CLAUDE.md")

	if err := a.G.Add(commitPaths); err != nil {
		return a.refuse("git add failed: %v", err)
	}
	if err := a.G.Commit("muster: init", commitPaths); err != nil {
		return a.refuse("init commit failed: %v", err)
	}

	// report
	a.pf("MUSTER v2 installed: .muster/ (cards, staging, plans, RUNNER.md, muster.db).")
	if len(decommissioned) > 0 {
		a.pf("v1 decommissioned: %d scripts stubbed under tasks/bin/, CLAUDE.md pointer rewritten.", len(decommissioned))
	}
	hooks, _ := filepath.Glob(filepath.Join(a.Root, ".git", "hooks", "*"))
	var active []string
	for _, h := range hooks {
		if !strings.HasSuffix(h, ".sample") {
			active = append(active, filepath.Base(h))
		}
	}
	if len(active) > 0 {
		a.pf("Active git hooks detected: %s. Hooks are honored - a tree-mutating hook costs done one re-stage cycle.", strings.Join(active, ", "))
	}
	a.pf("Recommended: add a Windows Defender exclusion for this repo (commit latency is Defender-dominated).")
	a.pf("Dispatch lines:")
	a.pf("  executor: muster claim -harness claude -tier any")
	a.pf("  reviewer: muster claim -harness claude -tier strong")
	return 0
}
```

- [ ] **Step 4: Run, verify pass**

Run: `go test ./internal/cli` and `go build ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/cli/initcmd.go internal/cli/init_test.go internal/cli/app.go
git commit -m "feat(v2): init verb - preflight, install, v1 liveness refusal + decommission"
```

---
### Task 24: wrapper skills - root-sensing repoint

**Files:**
- Modify: `skills/run/SKILL.md` (replace whole file)
- Modify: `skills/review/SKILL.md` (replace whole file)
- Modify: `skills/init/SKILL.md` (replace whole file)
- Modify: `skills/close/SKILL.md` (append v2 arm)
- Modify: `skills/shard/SKILL.md` (prepend v2 arm)
- Modify: `skills/auto/SKILL.md` (prepend board-detection note)

Root-sensing (Authority note 10): every wrapper picks v2 when `.muster/`
exists at the repo root, else runs its v1 text unchanged. This repo has no
`.muster/` until post-close cutover, so in-flight dogfood dispatch is
untouched by this task.

- [ ] **Step 1: Replace `skills/run/SKILL.md`**

```markdown
---
name: run
description: MUSTER executor session entry. Slash-only (/muster:run); do not auto-trigger.
---

Board detection: if `.muster/` exists at the repo root this is a v2 board -
run `muster claim -harness claude -tier any`, then follow `.muster/RUNNER.md`
to the letter.

Otherwise (v1 board): run
`powershell -ExecutionPolicy Bypass -File tasks/bin/claim.ps1 -Harness claude -Tier any`
(POSIX: sh tasks/bin/claim.sh --harness claude --tier any), then follow
tasks/RUNNER.md to the letter.
```

- [ ] **Step 2: Replace `skills/review/SKILL.md`**

Same text as run with `-tier strong` / `-Tier strong` / `--tier strong` and
description "MUSTER reviewer session entry. Slash-only (/muster:review); do
not auto-trigger.".

- [ ] **Step 3: Replace `skills/init/SKILL.md`**

```markdown
---
name: init
description: Bootstrap the MUSTER task board in this repo. Slash-only (/muster:init); do not auto-trigger.
---

# muster:init - install the task board (v2)

v2 is the only installable board (clean cut). The binary owns every check.

1. Confirm `muster` is on PATH (`muster board` prints a refusal or a board -
   either proves the binary resolves). Not found = stop: tell the user to
   install muster.exe first.
2. Run `muster init` from the repo root. The binary preflights (git repo,
   identity, sync-root guard, v1-liveness refusal), installs `.muster/`,
   decommissions a dead v1 tree (stubs `tasks/bin/*`, rewrites the CLAUDE.md
   pointer), and commits what it created.
3. Report the binary's output verbatim, including the two dispatch lines and
   the Defender-exclusion note. A `MUSTER refuse:` line = report it and stop;
   never work around a refusal (a live v1 board must be finished or closed
   first).
```

- [ ] **Step 4: Append to `skills/close/SKILL.md`**

Append this section (v1 text above it stays):

```markdown
## v2 boards (`.muster/` exists at the repo root)

Nothing moves at close on v2: dependencies resolve in the database and no verb
scans folders, so done cards stay in `.muster/cards/` as permanent history.

1. Run `muster board`. Eligibility: every task with this plan id is in
   `done` - the board shows backlog 0, inbox 0, doing 0, failed 0 for the
   plan (failed cards mean the plan is NOT finished; the human decides).
2. Report: done count for the plan and a reminder that done tasks keep
   satisfying dependencies forever.
```

- [ ] **Step 5: Prepend to `skills/shard/SKILL.md`**

Insert directly under the `# muster:shard` heading:

```markdown
## Board detection

If `.muster/` exists at the repo root, this is a v2 board - follow this
section and IGNORE the v1 steps below. Authoring rules (templates, inlining,
verify caveats, depends_on block lists, protected/commit_paths discipline,
review opt-in, terminal integration task) are UNCHANGED - only paths and
commands differ:

1. Refuse if `.muster/plans/<plan-id>.md` already exists. Copy the plan file
   verbatim to `.muster/plans/<plan-id>.md`.
2. Author all task cards into `.muster/cards/` (same templates, same rules;
   filename `<plan-id>-<seq>-<slug>.md`).
3. Gate: `muster ingest .muster/cards/<plan-id>-*.md` - the lint lives in the
   binary. Any `LINT FAIL` = fix the card files and rerun. Refusal to land an
   unlinted batch is unchanged; if a finding cannot be fixed, delete the batch
   (files are untracked and not yet ingested) and report why.
4. On `INGEST OK`: commit snapshot + cards, explicit paths, message
   `muster(<plan-id>): shard <n> tasks`. The commit MUST land before any
   claim: executors read cards from HEAD.
5. Run `muster promote` - dep-free tasks go claimable.
6. Report: task count by type, the DAG (id -> depends_on), and the dispatch
   reminder (Sonnet 5 + /muster:run per impl task; Opus 4.8 + /muster:review
   when a review task is ready).
```

- [ ] **Step 6: Prepend to `skills/auto/SKILL.md`**

Insert directly under the `# muster:auto` heading:

```markdown
## Board detection

If `.muster/` exists at the repo root, this is a v2 board. The loop, hard
rules, halt conditions, and model policy below apply unchanged, with these
substitutions:

- `bin/status` -> `muster board` (same counts; staging check is
  `.muster/staging/` and `muster doctor`).
- Run-mode subagent prompt -> "Run `muster claim -harness claude -tier any`,
  then follow `.muster/RUNNER.md` to the letter."
- Review-mode subagent prompt -> same with `-tier strong`.
- Close step -> the v2 arm of skills/close (report-only; nothing moves).
- Recovery framing: attempt markers are DB events, not commits; a dirty tree
  limited to the task's commit_paths plus `.muster/cards/` sidecars is still
  the NORMAL mid-task state and must never be discarded; a crash between
  done's commit and the board update heals at the next claim (reconciler).
```

- [ ] **Step 7: Verify**

Run: `findstr /C:"muster claim -harness claude -tier any" skills/run/SKILL.md`
Expected: exit 0, prints the matching line.
Run: `findstr /C:"tasks/bin/claim.ps1" skills/run/SKILL.md`
Expected: exit 0 (v1 arm preserved).
Repeat for review/shard/auto/close/init markers
(`-tier strong`, `muster ingest`, `muster board`, `.muster/cards/`, `muster init`).

- [ ] **Step 8: Commit**

```bash
git add skills/run/SKILL.md skills/review/SKILL.md skills/init/SKILL.md skills/close/SKILL.md skills/shard/SKILL.md skills/auto/SKILL.md
git commit -m "feat(v2): wrapper skills root-sense .muster/ and repoint to muster verbs"
```

---

### Task 25: frozen synthetic v1 board fixture

**Files:**
- Create: `test/process/v1fixture.go`
- Create: `test/process/v1fixture_test.go`

Spec D-v2-3: before v1 code is deleted, one synthetic v1 board tree (cards in
every folder + the claim/attempt commit sequence) is frozen as a fixture - the
only thing that rots if `muster adopt` is ever revived. It also drives the
init liveness/decommission process tests (Task 26).

- [ ] **Step 1: Write the failing test**

`test/process/v1fixture_test.go`:

```go
//go:build process

package process

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildV1BoardShape(t *testing.T) {
	dir := t.TempDir()
	BuildV1Board(t, dir, true)
	for _, rel := range []string{
		"tasks/RUNNER.md",
		"tasks/bin/claim.ps1",
		"tasks/backlog/v1demo-03-c.md",
		"tasks/inbox/v1demo-02-b.md",
		"tasks/doing/v1demo-01-a.md",
		"tasks/doing/v1demo-01-a.verify.log",
		"tasks/done/v1demo-00-z.md",
		"tasks/done/v1demo-00-z.result.md",
		"tasks/failed/v1demo-04-d.md",
		"tasks/staging/v1demo-05-fix-e.md",
		"tasks/plan-v1demo.md",
	} {
		if _, err := os.Stat(filepath.Join(dir, filepath.FromSlash(rel))); err != nil {
			t.Fatalf("missing %s", rel)
		}
	}
	out, err := exec.Command("git", "-C", dir, "log", "--format=%s").Output()
	if err != nil {
		t.Fatal(err)
	}
	log := string(out)
	for _, want := range []string{
		"muster: init task board",
		"muster(v1demo): shard",
		"muster(v1demo): claim v1demo-01-a",
		"muster(v1demo): attempt 1 v1demo-01-a",
		"muster(v1demo): done v1demo-00-z",
	} {
		if !strings.Contains(log, want) {
			t.Fatalf("commit sequence missing %q:\n%s", want, log)
		}
	}
}

func TestBuildV1BoardDeadVariant(t *testing.T) {
	dir := t.TempDir()
	BuildV1Board(t, dir, false)
	for _, rel := range []string{"tasks/inbox", "tasks/backlog", "tasks/doing", "tasks/staging", "tasks/failed"} {
		matches, _ := filepath.Glob(filepath.Join(dir, filepath.FromSlash(rel), "*.md"))
		live := 0
		for _, m := range matches {
			n := filepath.Base(m)
			if !strings.HasSuffix(n, ".result.md") && !strings.HasSuffix(n, ".notes.md") {
				live++
			}
		}
		if live != 0 {
			t.Fatalf("dead variant has live files in %s: %v", rel, matches)
		}
	}
}
```

- [ ] **Step 2: Run, verify fail**

Run: `go test -tags process ./test/process`
Expected: FAIL (undefined: BuildV1Board).

- [ ] **Step 3: Implement**

`test/process/v1fixture.go`:

```go
//go:build process

// Package process is the process tier: real muster.exe, real git, temp repos.
package process

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func run(t *testing.T, dir string, name string, args ...string) string {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%s %v: %v\n%s", name, args, err, out)
	}
	return string(out)
}

func gitCommit(t *testing.T, dir, msg string, paths ...string) {
	t.Helper()
	run(t, dir, "git", append([]string{"add", "--"}, paths...)...)
	run(t, dir, "git", append([]string{"-c", "core.autocrlf=false", "commit", "-q", "-m", msg, "--"}, paths...)...)
}

func write(t *testing.T, dir, rel, content string) {
	t.Helper()
	abs := filepath.Join(dir, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(abs, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func v1Card(id, status string) string {
	return `---
id: ` + id + `
plan: v1demo
type: impl
tier: any
depends_on: []
protected: []
commit_paths:
  - src/out.txt
verify:
  - cmd: git --version
    expect_exit: 0
` + status + `---
# ` + id + `: synthetic v1 card

## Context
Frozen v1 fixture (spec D-v2-3).

## Steps
1. none - fixture only

## Acceptance
- fixture exists
`
}

// BuildV1Board freezes the synthetic v1 board (spec D-v2-3): cards in every
// folder plus the claim/attempt commit sequence. live=false leaves only
// dead-tree remnants (done/, archive/, orphaned sidecars) - the decommission
// fixture.
func BuildV1Board(t *testing.T, dir string, live bool) {
	t.Helper()
	run(t, dir, "git", "init", "-q", "-b", "main")
	run(t, dir, "git", "config", "user.name", "fixture")
	run(t, dir, "git", "config", "user.email", "fixture@test.local")

	// init commit: board skeleton
	for _, d := range []string{"backlog", "inbox", "doing", "done", "failed", "archive", "staging", "bin"} {
		write(t, dir, "tasks/"+d+"/.gitkeep", "")
	}
	write(t, dir, "tasks/RUNNER.md", "# RUNNER - v1 executor contract (frozen fixture)\n")
	write(t, dir, "tasks/bin/claim.ps1", "# v1 claim script (frozen fixture)\n")
	write(t, dir, "tasks/bin/claim.sh", "# v1 claim script (frozen fixture)\n")
	write(t, dir, "CLAUDE.md", "Task board: `tasks/` is managed by MUSTER. Executors follow `tasks/RUNNER.md` exactly. Never edit files under `tasks/` by hand; the `tasks/bin/` scripts own all state transitions.\n")
	gitCommit(t, dir, "muster: init task board", "tasks", "CLAUDE.md")

	// shard commit: plan snapshot + cards
	write(t, dir, "tasks/plan-v1demo.md", "# plan v1demo (frozen fixture)\n")
	write(t, dir, "tasks/backlog/v1demo-03-c.md", v1Card("v1demo-03-c", ""))
	write(t, dir, "tasks/inbox/v1demo-02-b.md", v1Card("v1demo-02-b", ""))
	write(t, dir, "tasks/inbox/v1demo-01-a.md", v1Card("v1demo-01-a", ""))
	write(t, dir, "tasks/done/v1demo-00-z.md", v1Card("v1demo-00-z", ""))
	write(t, dir, "tasks/done/v1demo-00-z.result.md", "# Result: v1demo-00-z\n\n- status: done\n")
	write(t, dir, "tasks/failed/v1demo-04-d.md", v1Card("v1demo-04-d", ""))
	gitCommit(t, dir, "muster(v1demo): shard 5 tasks", "tasks")
	gitCommit(t, dir, "muster(v1demo): done v1demo-00-z", "tasks/done")

	// claim commit: inbox -> doing with claimed_at stamped (v1 semantics)
	run(t, dir, "git", "mv", "tasks/inbox/v1demo-01-a.md", "tasks/doing/v1demo-01-a.md")
	write(t, dir, "tasks/doing/v1demo-01-a.md", v1Card("v1demo-01-a", "claimed_at: 2026-08-14T00:00:00Z\n"))
	gitCommit(t, dir, "muster(v1demo): claim v1demo-01-a", "tasks/inbox/v1demo-01-a.md", "tasks/doing/v1demo-01-a.md")

	// attempt commit: verify.log header marker (D28)
	write(t, dir, "tasks/doing/v1demo-01-a.verify.log", "=== attempt 1 | 2026-08-14T00:01:00Z | task v1demo-01-a | HEAD x\n")
	gitCommit(t, dir, "muster(v1demo): attempt 1 v1demo-01-a", "tasks/doing/v1demo-01-a.verify.log")

	// staged fix from a crashed review session
	write(t, dir, "tasks/staging/v1demo-05-fix-e.md", v1Card("v1demo-05-fix-e", ""))

	if !live {
		// dead variant: clear every live folder, keep history + done/archive
		for _, rel := range []string{
			"tasks/backlog/v1demo-03-c.md", "tasks/inbox/v1demo-02-b.md",
			"tasks/doing/v1demo-01-a.md", "tasks/failed/v1demo-04-d.md",
			"tasks/staging/v1demo-05-fix-e.md", "tasks/plan-v1demo.md",
		} {
			os.Remove(filepath.Join(dir, filepath.FromSlash(rel)))
		}
		run(t, dir, "git", "add", "-A", "tasks")
		run(t, dir, "git", "-c", "core.autocrlf=false", "commit", "-q", "-m", "muster(v1demo): close")
	}
}
```

- [ ] **Step 4: Run, verify pass**

Run: `go test -tags process ./test/process`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/process/v1fixture.go test/process/v1fixture_test.go
git commit -m "test(v2): frozen synthetic v1 board fixture (live + dead variants)"
```

---
### Task 26: process tier - real binary, real git, crash proofs

**Files:**
- Create: `test/process/main_test.go` (TestMain: build the binary once + helpers)
- Create: `test/process/loop_test.go`
- Create: `test/process/crash_test.go`
- Create: `test/process/init_test.go`
- Create: `test/process/review_test.go`

Spec section 8: ~10-20 tests against the real `muster.exe` and real temp git
repos. This tier is Windows-first; guard each file's build with the `process`
tag (already on the package) and skip on non-Windows only where a fixture
needs cmd.exe (none below - verify blocks use `git --version` and `findstr`,
and findstr tests skip off-Windows).

- [ ] **Step 1: Write `test/process/main_test.go`**

```go
//go:build process

package process

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var musterExe string

func TestMain(m *testing.M) {
	tmp, err := os.MkdirTemp("", "muster-build")
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	musterExe = filepath.Join(tmp, "muster.exe")
	root, _ := filepath.Abs(filepath.Join("..", ".."))
	cmd := exec.Command("go", "build", "-o", musterExe, "./cmd/muster")
	cmd.Dir = root
	if out, err := cmd.CombinedOutput(); err != nil {
		fmt.Printf("build failed: %v\n%s\n", err, out)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(tmp)
	os.Exit(code)
}

// newRepo: temp git repo with identity and one initial commit.
func newRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	run(t, dir, "git", "init", "-q", "-b", "main")
	run(t, dir, "git", "config", "user.name", "proc")
	run(t, dir, "git", "config", "user.email", "proc@test.local")
	write(t, dir, "README.md", "process fixture\n")
	gitCommit(t, dir, "init", "README.md")
	return dir
}

// muster runs the built binary in repo; returns merged output + exit code.
func muster(t *testing.T, repo string, env []string, args ...string) (string, int) {
	t.Helper()
	cmd := exec.Command(musterExe, args...)
	cmd.Dir = repo
	cmd.Env = append(os.Environ(), env...)
	out, err := cmd.CombinedOutput()
	code := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			t.Fatalf("muster %v: %v\n%s", args, err, out)
		}
	}
	return string(out), code
}

func mustMuster(t *testing.T, repo string, args ...string) string {
	t.Helper()
	out, code := muster(t, repo, nil, args...)
	if code != 0 {
		t.Fatalf("muster %v exited %d:\n%s", args, code, out)
	}
	return out
}

const implCardP2 = `---
id: p2-01-hello
plan: p2
type: impl
tier: any
depends_on: []
protected: []
commit_paths:
  - src/hello.txt
verify:
  - cmd: findstr hello src/hello.txt
    expect_exit: 0
    expect_contains: hello
---
# p2-01-hello: write hello

## Context
Process-tier fixture.

## Steps
1. Create src/hello.txt containing the word hello.

## Acceptance
- findstr finds hello
`

const integrationCardP2 = `---
id: p2-99-int
plan: p2
type: integration
tier: strong
depends_on:
  - p2-01-hello
verify:
  - cmd: git --version
    expect_exit: 0
---
# p2-99-int: integrate

## Context
Process-tier fixture.

## Steps
1. Confirm the suite is green.

## Acceptance
- verify green
`

// boardWithCards: init + ingest + commit + promote; returns the repo.
func boardWithCards(t *testing.T, cards map[string]string) string {
	t.Helper()
	repo := newRepo(t)
	mustMuster(t, repo, "init")
	var paths []string
	for name, text := range cards {
		rel := ".muster/cards/" + name
		write(t, repo, rel, text)
		paths = append(paths, rel)
	}
	mustMuster(t, repo, append([]string{"ingest"}, paths...)...)
	gitCommit(t, repo, "muster(p2): shard", append([]string{}, paths...)...)
	mustMuster(t, repo, "promote")
	return repo
}

func defaultBoard(t *testing.T) string {
	return boardWithCards(t, map[string]string{
		"p2-01-hello.md": implCardP2,
		"p2-99-int.md":   integrationCardP2,
	})
}

func assertContains(t *testing.T, out string, wants ...string) {
	t.Helper()
	for _, w := range wants {
		if !strings.Contains(out, w) {
			t.Fatalf("output missing %q:\n%s", w, out)
		}
	}
}
```

- [ ] **Step 2: Write `test/process/loop_test.go`**

```go
//go:build process

package process

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
)

func skipOffWindows(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("findstr fixtures are Windows-first")
	}
}

func TestFullHappyLoop(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	out := mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	assertContains(t, out, "Claimed p2-01-hello. Follow .muster/RUNNER.md.")
	write(t, repo, "src/hello.txt", "hello world\n")
	out = mustMuster(t, repo, "verify")
	assertContains(t, out, "VERIFY PASS (attempt 1)")
	out = mustMuster(t, repo, "done")
	assertContains(t, out, "Board:", "Done: p2-01-hello. Promoted: p2-99-int. Do not claim another task. Session over.")
	subject := strings.TrimSpace(run(t, repo, "git", "log", "-1", "--format=%s"))
	if subject != "muster(p2): done p2-01-hello" {
		t.Fatalf("subject: %s", subject)
	}
	if porcelain := strings.TrimSpace(run(t, repo, "git", "status", "--porcelain")); porcelain != "" {
		t.Fatalf("tree not clean after done:\n%s", porcelain)
	}
	// integration leg: notes required, verdict recorded
	out = mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "strong")
	assertContains(t, out, "Claimed p2-99-int")
	write(t, repo, ".muster/cards/p2-99-int.notes.md", "suite green\n")
	out = mustMuster(t, repo, "done", "pass")
	assertContains(t, out, "Done: p2-99-int")
	out = mustMuster(t, repo, "show", "p2-99-int")
	assertContains(t, out, "status: done", "verdict: pass")
	// backup survived
	if _, err := os.Stat(filepath.Join(repo, ".muster", "backup.db")); err != nil {
		t.Fatal("backup.db missing")
	}
}

func TestClaimRaceTwoProcesses(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	var wg sync.WaitGroup
	outs := make([]string, 2)
	codes := make([]int, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			outs[i], codes[i] = muster(t, repo, nil, "claim", "-harness", "claude", "-tier", "any")
		}(i)
	}
	wg.Wait()
	winners := 0
	for i := 0; i < 2; i++ {
		if strings.Contains(outs[i], "Claimed p2-01-hello") {
			winners++
		} else if !strings.Contains(outs[i], "MUSTER refuse:") {
			t.Fatalf("racer %d neither claimed nor refused:\n%s", i, outs[i])
		}
	}
	if winners != 1 {
		t.Fatalf("winners = %d\nA:\n%s\nB:\n%s", winners, outs[0], outs[1])
	}
}

func TestStatusBlockBeforeRefusal(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	out, code := muster(t, repo, nil, "claim", "-harness", "claude", "-tier", "any")
	if code != 1 {
		t.Fatalf("code %d", code)
	}
	iStatus := strings.Index(out, "MUSTER status @")
	iRefuse := strings.Index(out, "MUSTER refuse:")
	if iStatus < 0 || iRefuse < 0 || iStatus > iRefuse {
		t.Fatalf("CM-ORDER violated:\n%s", out)
	}
}

func TestVerifyTerminalEvidence(t *testing.T) {
	skipOffWindows(t)
	red := strings.Replace(implCardP2, "cmd: findstr hello src/hello.txt", "cmd: findstr absent src/hello.txt", 1)
	red = strings.Replace(red, "    expect_contains: hello\n", "", 1)
	repo := boardWithCards(t, map[string]string{
		"p2-01-hello.md": red,
		"p2-99-int.md":   integrationCardP2,
	})
	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	for want, i := 2, 1; i <= 3; i++ {
		out, code := muster(t, repo, nil, "verify")
		if i == 3 {
			want = 3
		}
		if code != want {
			t.Fatalf("attempt %d: code %d\n%s", i, code, out)
		}
	}
	out := mustMuster(t, repo, "board")
	assertContains(t, out, "failed   1")
	if _, err := os.Stat(filepath.Join(repo, "src", "hello.txt")); err != nil {
		t.Fatal("evidence must stay in the tree")
	}
}

func TestDoneRefusesNonDescendantHead(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	write(t, repo, "note.txt", "post-shard commit\n")
	gitCommit(t, repo, "unrelated", "note.txt")
	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	// HEAD moves behind head_at_claim; src/hello.txt is untracked and survives
	run(t, repo, "git", "reset", "--hard", "HEAD~1")
	out, code := muster(t, repo, nil, "done")
	if code != 1 || !strings.Contains(out, "not a descendant of head_at_claim") {
		t.Fatalf("code %d:\n%s", code, out)
	}
}

func TestHookMutationAbsorbed(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	// idempotent tree-mutating pre-commit hook (appends a marker once)
	write(t, repo, ".git/hooks/pre-commit",
		"#!/bin/sh\ngrep -q HOOKED src/hello.txt 2>/dev/null || echo HOOKED >> src/hello.txt\nexit 0\n")
	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	mustMuster(t, repo, "verify")
	out := mustMuster(t, repo, "done")
	assertContains(t, out, "Session over.")
	if porcelain := strings.TrimSpace(run(t, repo, "git", "status", "--porcelain")); porcelain != "" {
		t.Fatalf("hook dirt left behind:\n%s", porcelain)
	}
	blob := run(t, repo, "git", "show", "HEAD:src/hello.txt")
	if !strings.Contains(blob, "HOOKED") {
		t.Fatalf("hook mutation must be committed, not bypassed:\n%s", blob)
	}
}
```

- [ ] **Step 3: Write `test/process/crash_test.go`**

```go
//go:build process

package process

import (
	"strings"
	"testing"
)

func TestCrashBeforeCommitIsCleanRetry(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	out, code := muster(t, repo, []string{"MUSTER_CRASH_POINT=before-commit"}, "done")
	if code != 97 {
		t.Fatalf("crash injection missed: %d\n%s", code, out)
	}
	subject := strings.TrimSpace(run(t, repo, "git", "log", "-1", "--format=%s"))
	if strings.HasPrefix(subject, "muster(p2): done") {
		t.Fatal("no commit may exist before the crash point")
	}
	show := mustMuster(t, repo, "show", "p2-01-hello")
	assertContains(t, show, "status: doing")
	// clean retry
	out = mustMuster(t, repo, "done")
	assertContains(t, out, "Done: p2-01-hello")
}

func TestCrashAfterCommitHealsViaReconciler(t *testing.T) {
	skipOffWindows(t)
	repo := defaultBoard(t)
	mustMuster(t, repo, "claim", "-harness", "claude", "-tier", "any")
	write(t, repo, "src/hello.txt", "hello world\n")
	out, code := muster(t, repo, []string{"MUSTER_CRASH_POINT=after-commit"}, "done")
	if code != 97 {
		t.Fatalf("crash injection missed: %d\n%s", code, out)
	}
	subject := strings.TrimSpace(run(t, repo, "git", "log", "-1", "--format=%s"))
	if subject != "muster(p2): done p2-01-hello" {
		t.Fatalf("done commit must exist: %s", subject)
	}
	show := mustMuster(t, repo, "show", "p2-01-hello")
	assertContains(t, show, "status: doing") // the torn state
	// next claim reconciles, then hands out the promoted integration task or
	// refuses - either way the row must heal
	out, _ = muster(t, repo, nil, "claim", "-harness", "claude", "-tier", "any")
	assertContains(t, out, "Reconciled p2-01-hello: done commit found, row healed.")
	show = mustMuster(t, repo, "show", "p2-01-hello")
	assertContains(t, show, "status: done")
}
```

- [ ] **Step 4: Write `test/process/init_test.go`**

```go
//go:build process

package process

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInitFreshRepoProcess(t *testing.T) {
	repo := newRepo(t)
	out := mustMuster(t, repo, "init")
	assertContains(t, out, "MUSTER v2 installed", "muster claim -harness claude -tier any")
	subject := strings.TrimSpace(run(t, repo, "git", "log", "-1", "--format=%s"))
	if subject != "muster: init" {
		t.Fatalf("subject: %s", subject)
	}
	for _, rel := range []string{".muster/RUNNER.md", ".muster/.gitignore", ".muster/muster.db"} {
		if _, err := os.Stat(filepath.Join(repo, filepath.FromSlash(rel))); err != nil {
			t.Fatalf("missing %s", rel)
		}
	}
	// db must be ignored
	porcelain := run(t, repo, "git", "status", "--porcelain", "--untracked-files=all")
	if strings.Contains(porcelain, "muster.db") {
		t.Fatalf("db leaked into git status:\n%s", porcelain)
	}
	if out, code := muster(t, repo, nil, "init"); code != 1 || !strings.Contains(out, "already exists") {
		t.Fatalf("second init must refuse: %d\n%s", code, out)
	}
}

func TestInitRefusesLiveV1Process(t *testing.T) {
	dir := t.TempDir()
	BuildV1Board(t, dir, true)
	out, code := muster(t, dir, nil, "init")
	if code != 1 {
		t.Fatalf("code %d:\n%s", code, out)
	}
	assertContains(t, out, "v1 board is live", "tasks/inbox/v1demo-02-b.md", "tasks/staging/v1demo-05-fix-e.md")
	if _, err := os.Stat(filepath.Join(dir, ".muster")); err == nil {
		t.Fatal("half-install")
	}
}

func TestInitDecommissionsDeadV1Process(t *testing.T) {
	dir := t.TempDir()
	BuildV1Board(t, dir, false)
	out := mustMuster(t, dir, "init")
	assertContains(t, out, "v1 decommissioned")
	stub, _ := os.ReadFile(filepath.Join(dir, "tasks", "bin", "claim.ps1"))
	if !strings.Contains(string(stub), "v1 board decommissioned") {
		t.Fatalf("stub: %s", stub)
	}
	claude, _ := os.ReadFile(filepath.Join(dir, "CLAUDE.md"))
	if !strings.Contains(string(claude), ".muster/ is managed by MUSTER v2") {
		t.Fatalf("pointer: %s", claude)
	}
}
```

- [ ] **Step 5: Write `test/process/review_test.go`** - the dogfood gate
(Authority note 11): v2 runs a full sharded plan including a review cycle.

```go
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
  - cmd: findstr better src/hello.txt
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
```

- [ ] **Step 6: Run the tier**

Run: `go test -tags process ./test/process -v`
Expected: all PASS (with the Task 25 fixture tests, ~14 tests).
Also run: `go test ./...`
Expected: unit tier still green; the process package is excluded without the tag.

- [ ] **Step 7: Commit**

```bash
git add test/process/main_test.go test/process/loop_test.go test/process/crash_test.go test/process/init_test.go test/process/review_test.go
git commit -m "test(v2): process tier - race, crash reconciler proofs, hooks, init, review cycle"
```

---

### Task 27: final sweep + cutover checklist

**Files:**
- Create: `docs/v2-cutover.md`
- Modify: `README.md` (add a short v2 section pointing at `.muster/`, the Go
  module, and `docs/v2-cutover.md`; keep the v1 text until cutover completes)

- [ ] **Step 1: Full verification sweep**

Run, in order, all from repo root:

```bash
gofmt -l .
```
Expected: no output (every file formatted).

```bash
go vet ./...
```
Expected: exit 0, no output.

```bash
go test ./...
```
Expected: all unit packages PASS in seconds.

```bash
go test -tags process ./test/process
```
Expected: PASS.

- [ ] **Step 2: Write `docs/v2-cutover.md`**

Copy Appendix B of this plan verbatim into `docs/v2-cutover.md` (title line:
`# MUSTER v2 cutover checklist (human, after /muster:close of the v2build plan)`).

- [ ] **Step 3: Update `README.md`**

Append:

```markdown
## MUSTER v2 (Go + SQLite)

v2 is a single static binary (`go build ./cmd/muster`) owning the board in
`.muster/` (cards in git, state in SQLite, one commit per task at done).
Design: docs/superpowers/specs/2026-08-15-muster-v2-design.md. Cutover from
the v1 script board: docs/v2-cutover.md. The v1 tree under tasks/ stays
authoritative until that checklist completes.
```

- [ ] **Step 4: Commit**

```bash
git add docs/v2-cutover.md README.md
git commit -m "docs(v2): cutover checklist + README v2 section"
```

---

## Appendix A: v1 contract matrix - keep / drop / re-home

Disposition of every `tests/ContractMatrix.psd1` row (the checklist the spec
section 8 mandates). BlackBoxInventory counts retire with the v1 tier
machinery; the behaviors live on in the per-task Go tests named here.

| CM row | v1 behavior | v2 disposition |
|---|---|---|
| CM-STATUS-OK | status block + dispatch split | KEEP - `muster board` + claim print (Tasks 11, 13) |
| CM-STATUS-FAIL | refuses outside a git repo, exit 1 | KEEP - main's FindRoot refusal (Task 11) |
| CM-LINT-OK / CM-LINT-FAIL | shard lint gate | KEEP - ingest lint, checks 1-14 (Tasks 10, 12) |
| CM-CLAIM-OK | lowest eligible, stamps claimed_at, commits | RE-HOME - claimed_at/head_at_claim are DB columns; the claim commit is DELETED (zero hot-path git writes) (Tasks 6, 13) |
| CM-CLAIM-FAIL | refuses without identity flags | KEEP (Task 13) |
| CM-DONE-OK | sidecars, single completion commit, session-over line | KEEP - sidecars in .muster/cards/, one commit (Task 16) |
| CM-DONE-FAIL | refuses when doing empty | KEEP - DB doing check (Tasks 14, 16) |
| CM-VERIFY-OK / CM-VERIFY-FAIL | attempts logged, empty-doing refusal | KEEP - attempts are event rows (Task 14) |
| CM-PROMOTE-OK | deps-in-done move + commit | RE-HOME - DB status flip, NO commit (Task 7) |
| CM-PROMOTE-FAIL | refuses outside git repo | KEEP (Task 11 main wiring) |
| CM-ARG-CLAIM | tier pinning both directions | KEEP - collapses to tier equality (Task 6) |
| CM-ARG-DONE | verdict argument rules | KEEP + `--reason` required on fail (Task 16) |
| CM-ARG-LINT | lite mode rules | KEEP - Lite mode; `generation` now rejected everywhere (Tasks 2, 10) |
| CM-ARG-PROMOTE | -NoCommit stages only | DROP - promote no longer commits anything |
| CM-ORDER | status block before any refusal | KEEP (Tasks 13, 26) |
| CM-TERMINAL | counts-only board line before terminal line | KEEP - boardLine before the Done line (Task 16) |
| CM-LAYOUT | v1 fixture contract | DROP - v1 tier machinery retires (spec 8) |
| CM-GITFAIL | claim refuses outside git repo | KEEP (Task 11) |
| CM-CO-UNCOMMITTED | done refuses an uncommitted doing task | RE-HOME - claim/verify/done refuse a card missing at HEAD (Task 13) |
| CM-CO-CRLF | executor CRLF commits as LF blob | RE-HOME - `.muster/.gitattributes` (`* text=auto eol=lf`) ships with init; no test (Task 22) |
| CM-CO-PROMOTE-WARN / CM-PROMOTE-WARN-CLAIM | malformed backlog skipped with warning | DROP - malformed cards cannot enter the DB (ingest lint gate); drift is a doctor finding (Tasks 12, 21) |

## Appendix B: cutover checklist (human, after the v2build plan closes)

Authority note 11: cutover cannot be a board task - `muster init` refuses on a
live v1 tree, and v1 is live while this plan runs. After `/muster:close
v2build` archives the build plan:

1. Confirm the dogfood gate held: `go test -tags process ./test/process` green
   (the process tier IS v2 sharding and running a full plan with a review
   cycle on itself - Task 26).
2. Build and install the binary: `go build -o muster.exe ./cmd/muster`, put
   `muster.exe` on PATH (or leave it at the repo root).
3. Run `muster init` at this repo's root. Expected: preflight passes (the v1
   tree is dead - archive only), `.muster/` installs, `tasks/bin/*` stubbed
   with refusal scripts, CLAUDE.md pointer rewritten to v2, one `muster: init`
   commit.
4. Sanity: `/muster:run` in a throwaway session must now dispatch v2 (the
   root-sensing wrapper sees `.muster/`); `tasks/bin/claim.ps1` must print
   `MUSTER refuse: v1 board decommissioned`.
5. Add the Windows Defender exclusion for this repo if not already present.
6. Retirement sweep (separate commit, after a week of green v2 use):
   - delete `runtime/` (v1 scripts + sh mirror) and `tests/*.Tests.ps1` +
     `tests/MusterFixture.ps1` + `tests/ContractMatrix.psd1` +
     `tests/BlackBoxInventory.psd1` (behaviors mapped in Appendix A);
   - the frozen v1 fixture (`test/process/v1fixture.go`) stays - it is the
     only surviving v1 record (spec D-v2-3);
   - archive `docs/superpowers/plans/2026-08-15-muster-v2-implementation.md`
     status by adding a "SHIPPED" note at the top.

## Execution note (dogfood wiring)

- Shard this plan with `/muster:shard`, plan id `v2build`, onto the v1 board
  (`tasks/`). v1 stays untouched until Appendix B.
- Suggested review cards (tier strong): after Tasks 6, 16, 18, 26 - the claim
  transaction, the done pass path, the reject cycle, and the process tier are
  the risk concentrations.
- Dispatch: Sonnet 5 + `/muster:run` per impl card; Opus 4.8 + `/muster:review`
  per review card; strictly sequential (`/muster:auto` allowed).













