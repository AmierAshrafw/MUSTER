# YAGNI audit sidecar: 2026-08-08-board-visibility.md

Auditor: yagni-guardian subagent (opus, fresh context), 2026-08-08.
Tier: NONE. Findings: 0. Y4 (scope vs spec): scored — spec resolved.

No findings, so no verdicts. Signals the auditor considered and dropped, kept for
the record:

- Y1/Y2 (single-caller abstraction): `Get-InboxSplit`/`inbox_split` and
  `Get-DeadEntries`/`dead_scan` each have two callers in-plan; `Get-BoardLine`
  has one production caller plus a direct unit test. ps1/sh pairing is
  pre-existing two-engine architecture.
- Y7 (impossible-state guard): the non-string `tier` guard is reachable —
  `Read-Frontmatter` yields an array for block-list `tier:` with no error, so
  the guard protects the plan's own count invariant. The `status.sh` repo-root
  guard is required (`repo_root` has no refusal) and spec-mandated.
- Y4 (scope): spec-file fold-ins (lint in section 1 listing, 4.0 note, 8.3
  heading fix) are doc-coherence collateral inside sections the spec already
  amends; no new runtime surface.
- Plan's "Out of scope" section explicitly rejects the five expansions the
  audit would otherwise hunt: skill wrapper, folder dump, next-hint line,
  harness dimension, parser alignment.
