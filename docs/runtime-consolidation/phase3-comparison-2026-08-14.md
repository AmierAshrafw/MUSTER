# Phase 3 stateful-verb comparison

In-process (`Invoke-XCommand` in a hosted runspace) vs child-process (`powershell.exe -File`)
execution of the stateful `done` verb, measured after the Phase 3 extraction. Companion to
`phase1-comparison-2026-08-13.md` (which measured the read-only verbs). This delta feeds the
Phase 5 C# decision (`test-speed-consolidation-plan.md` -> "Relationship to the C# proposal").

Machine: RPS-MV-L-1007, PowerShell 5.1.26100.9168.

## Measured

```
done  in-proc 1.700s  child 5.523s  (3.2x)
```

(Average of 10 in-process vs 5 child completions of a done-ready fixture, one warm-up run to
prime JIT; each iteration builds a fresh fixture via the real child `claim` so the timed `done`
starts from a genuinely claimed task. Script per plan Task 4 Step 2.)

Full-suite parity gate, both engines, after all three extractions: `Tests Passed: 161, Failed: 0`
on the ps1 arm (825.68s) and `Tests Passed: 161, Failed: 0` on the sh arm (993.44s) - no diff.

## Reading

The 3.2x in-process win is smaller than status/lint's ~4.6x, as expected: `claim` / `done` are
git-subprocess-bound (a done completion runs a mv/add/renormalize/commit chain plus the done-check
verify child), so the fixed per-invocation `powershell.exe` startup that the in-process tier
removes is a smaller fraction of the total than it was for the 1-2-git-call read-only verbs.

Phase 3 is net-slower in isolation: it adds the three `*.Fast.Tests.ps1` files while keeping the
full black-box suite running on both engines as the parity backstop. The payoff is Phase 4's
migration (retiring redundant child-process behavior tests once the contract matrix is built), not
this phase. The 3.2x figure is the per-call ceiling Phase 4 can capture as it moves eligible tests
in-process.
