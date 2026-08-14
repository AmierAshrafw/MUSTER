# Phase 4 test classification

**Machine:** damai-new (Windows Server 2025, Windows PowerShell 5.1, Pester 6.0.1)
**Date:** 2026-08-14

## Information-stream probe (spec D3)

Question: `Invoke-Promote`'s malformed-backlog warning goes through `Write-Host`
(the Information stream), which the in-process runspace harness dropped. Does the
warning land in `$ps.Streams.Information`, and can the harness fold it into the
returned result's `Output` without breaking any existing assertion's line order?

Probe: `tests/bench/Probe-InfoStream.ps1`.

**Fixture-content correction (found during the probe):** the malformed-backlog
warning fires only for a backlog file with *no frontmatter block at all*
(content `"no frontmatter here\n"`, per the black-box source of truth
`tests/Promote.Tests.ps1:44`). A valid-but-incomplete frontmatter such as
`---\nid: p-03-bad\n---\nbody` parses clean — `Read-TaskFile.Errors` covers
frontmatter *parse* errors, not schema completeness — so promote treats it as a
normal task and promotes it silently, emitting no warning. The first probe run
used the incomplete-frontmatter content and (correctly) saw 0 information records;
the probe fixture was corrected to the no-frontmatter content.

Probe output (corrected run):

```
result output lines: 0
information records: 1
  info: MUSTER warn: backlog/p-03-bad.md frontmatter invalid - skipped by promote.
child stdout: MUSTER warn: backlog/p-03-bad.md frontmatter invalid - skipped by promote.
```

**Decision: FOLD.** Both conditions of the pre-set rule hold:

- **(a)** The warning appears in `$ps.Streams.Information` (1 record).
- **(b)** No existing fast-tier test emits an Information record while asserting
  Output-line position. The only `Write-Host` reachable in-process is
  `Invoke-Promote`'s malformed-backlog warning (`runtime/bin/_lib.ps1:428`; the
  other two `Write-Host` hits at 418/769 are comments). No current fast test
  creates a malformed *backlog* file — `Status.Fast.Tests.ps1:25` writes a
  no-frontmatter file to `tasks/inbox/`, not `tasks/backlog/`, and status never
  promotes — so the fold appends to no existing test's Output. Verified
  empirically: the full fast tier stayed green (42 passed) after the fold.

Implementation: `tests/fast/InProcHarness.ps1` appends
`$ps.Streams.Information` message lines after `Output` in the returned result
(order vs Output is not preserved — valid only while no assertion depends on it).
The promote-warning rows (`CM-CO-PROMOTE-WARN`, `CM-PROMOTE-WARN-CLAIM`) become
**eligible** for fast twins; the `skips malformed backlog files with a warning`
twin now lives in `tests/fast/Promote.Fast.Tests.ps1` and asserts on the folded
`Output` via a substring match (not a position).
