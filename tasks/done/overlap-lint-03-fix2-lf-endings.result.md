# Result: overlap-lint-03-fix2-lf-endings

- status: done
- claim_commit: 9f12bf1aa5cf3649453a1b671193765449a41d0c
- claimed_at: 2026-08-13T01:04:45Z
- completed_at: 2026-08-13T01:13:06Z
- verify: pass (attempt 1 of 3)
- files_changed:
  - runtime/bin/_lib.ps1
  - tasks/doing/overlap-lint-03-fix2-lf-endings.notes.md
  - tasks/doing/overlap-lint-03-fix2-lf-endings.verify.log

## Surprises

Rewrote runtime/bin/_lib.ps1 in place with the exact command the reviewer gave (CRLF -> LF replace on the raw text). Verified before commit: no line's text changed (git diff --ignore-space-at-eol against runtime/bin/_lib.ps1 was empty), line count stayed 1050, the final trailing newline was preserved, and the self-check `(Get-Content -Raw ...).Contains([char]13)` printed False. Local git config has core.autocrlf=true (global), which makes `git diff`/`git status` print a "LF will be replaced by CRLF" warning on this file since it isn't pinned by .gitattributes (only *.sh is pinned to eol=lf there) - noting this in case the done script's commit doesn't force LF for .ps1 and the blob ends up CRLF again; the working tree itself is confirmed LF-only right now. Did not touch runtime/bin/_lib.sh or tests/.
