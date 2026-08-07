---
id: {plan}-{impl-seq}-fix-{slug}
plan: {plan}
type: fix
tier: any
fixes: {impl-id}
depends_on: []
protected:
  - {same-as-impl-plus-any-new}
commit_paths:
  - {paths}
verify:
  - cmd: "{impl-verify-cmds-carried-over}"
    expect_exit: 0
---
# {plan}-{impl-seq}-fix-{slug}: fix {impl-id}

## Context

Review of {impl-id} failed (generation stamped by the done script). Findings,
verbatim:

{findings}

Original task intent:

{impl context excerpt}

## Steps

1. Ensure {target state per finding - written by the reviewer, exact paths}.

## Acceptance

- Every finding above addressed; verify green.
