# Phase 3 divergence spike

Throwaway measurement gate run before any Phase 3 extraction (plan
`docs/superpowers/plans/2026-08-14-test-speed-phase3.md` Task 0, design
`docs/superpowers/specs/2026-08-14-test-speed-phase3-design.md`). Maps which stateful
git paths round-trip inside a hosted Windows PowerShell 5.1 runspace under
`$ErrorActionPreference = 'Stop'` versus which throw a terminating `NativeCommandError`
on a native stderr write. Probe: `tests/bench/Probe-Phase3Divergence.ps1`.

Machine: RPS-MV-L-1007, PowerShell 5.1.26100.9168.

## Probe result

```
=== Phase 3 divergence probe ===
PASS  (expected PASS)  Complete-Task (default fixture)
PASS  (expected PASS)  Invoke-DoneFailReview cycle (default fixture)
THROW (expected THROW)  Complete-Task (eol=lf + CRLF commit_path)  ::  Exception calling "Invoke" with "0" argument(s): "The running command stopped because the preference variable "ErrorActionPreference" or common parameter is set to Stop: warning: in the working copy of 'src/out.txt', CRLF will be replaced by LF the next time Git touches it"
THROW (expected THROW)  Read-CommittedTask (uncommitted doing task)  ::  Exception calling "Invoke" with "0" argument(s): "The running command stopped because the preference variable "ErrorActionPreference" or common parameter is set to Stop: fatal: path 'tasks/doing/p-01-a.md' exists on disk, but not in 'HEAD'"
```

## Reading

All four cases matched their expectation, so the runspace boundary is exactly as the
design maps it. On the default test fixture the two risky-region paths round-trip
cleanly in-process: `Complete-Task` (the `done`-pass git mv/add/renormalize/commit chain)
and `Invoke-DoneFailReview` (the review-cycling fail chain) both return with no native
stderr and no throw. The two confirmed process-tier carve-outs both throw for the mapped
reason: carve-out (b) `Complete-Task` under an `eol=lf` pin with a CRLF `commit_path`
terminates on `git add --renormalize`'s "CRLF will be replaced by LF" stderr notice (a
success-exit warning), and carve-out (a) `Read-CommittedTask` on an uncommitted `doing/`
task terminates on `git show`'s "exists on disk, but not in 'HEAD'" fatal stderr.

Gate verdict: **proceed**. No success or non-native-stderr target-edge path tripped the
divergence, so the spec's halt-and-report condition (which would feed the deferred C#
decision) did not fire. Extraction proceeds to Task 1 (`done`).
