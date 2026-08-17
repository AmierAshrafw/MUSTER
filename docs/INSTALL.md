# MUSTER v2 - install and first board

From zero (fresh machine, fresh target repo) to a running task board. The
binary is the product; the `/muster:*` skills are thin wrappers around it, so
cloning this repo and building once is the real install.

## 1. Prerequisites

- git >= 2.40 on PATH.
- Go >= 1.25 (build-time only; the produced binary is static, no cgo).
  Windows: `winget install GoLang.Go`, then reopen the terminal.
- Recommended on Windows: a Defender exclusion for the target repo clone
  (done-commit latency is Defender-dominated without it).

## 2. Build the binary (once per machine)

```bash
git clone <this-repo-url> MUSTER
cd MUSTER
go build -o muster.exe ./cmd/muster
```

Put `muster.exe` on PATH (or copy it next to wherever you work). Verify:
`muster board` outside a git repo must print a one-line
`MUSTER refuse: not inside a git repository.`

Optional sanity: `go test ./internal/...` (unit tier, seconds) and
`go test -tags process ./test/process` (real-binary tier, ~1 min).

## 3. Install the board in a target repo

At the target repo root:

```bash
muster init
```

The binary does everything itself:

- preflight: inside a git repo, git identity set, refuses on a live v1 board,
  detects and prints active git hooks
- creates `.muster/` (`cards/`, `staging/`, `plans/`) and `muster.db`
- writes `.muster/RUNNER.md`, `.muster/.gitignore`, `.muster/.gitattributes`
  from templates embedded in the binary
- appends the board pointer to `CLAUDE.md` (rewrites a dead v1 pointer and
  stubs `tasks/bin/*` when decommissioning an old v1 tree)
- one `muster: init` commit

If the repo also keeps an `AGENTS.md`, mirror the `CLAUDE.md` pointer there by
hand - init only writes `CLAUDE.md`.

## 4. Agent wiring (Claude Code)

The slash commands live in this repo under `skills/` (`/muster:init`,
`/muster:shard`, `/muster:run`, `/muster:review`, `/muster:auto`,
`/muster:close`). Make them available in the agent environment that will work
the target repo (plugin/skills setup is environment-specific; the skills are
tiny and root-sense v1 vs v2 boards automatically). Without them, the raw
verbs still work - the skills only wrap the commands listed below.

Executors need no special briefing: a fresh agent finds the `CLAUDE.md`
pointer, and `.muster/RUNNER.md` is the complete executor contract.

## 5. First plan, end to end

1. Write and approve an implementation plan (any format your team uses).
2. Shard it: `/muster:shard` authors card files into `.muster/cards/`
   (`<plan-id>-<seq>-<slug>.md`), then gates them:
   `muster ingest .muster/cards/<plan-id>-*.md` - any `LINT FAIL` means fix
   the card files and rerun. Commit the cards, then `muster promote`.
3. Dispatch, one task per fresh session:
   - implementation: `/muster:run` (runs
     `muster claim -harness claude -tier any`)
   - review tasks: `/muster:review` (same with `-tier strong`)
   - or let `/muster:auto` loop the dispatch inside one session
4. Each executor follows `.muster/RUNNER.md`: work the card, `muster verify`,
   `muster done` (or `muster done fail --reason "..."`). One git commit per
   task, made by the binary.
5. Watch state: `muster board`, `muster show <id>`, `muster doctor`.
6. Human recovery when needed: `muster redo | fail | reimport <id>`.

## 6. Exit codes (scripting)

0 success/pass, 1 refusal (one line starting `MUSTER refuse: `),
2 verify attempt failed (retry allowed), 3 terminal.
