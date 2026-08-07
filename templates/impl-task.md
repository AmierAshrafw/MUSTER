---
id: {plan}-{seq}-{slug}
plan: {plan}
type: impl
tier: any
depends_on:
  - {dep-id-one-per-line}
protected:
  - {verify-touched-paths}
commit_paths:
  - {paths}
verify:
  - cmd: "{cmd}"
    expect_exit: 0
---
# {plan}-{seq}-{slug}: {title}

## Context

{inlined excerpts: what this task builds, why, every interface it touches,
relevant code pasted in}

## Steps

1. Ensure {exact target state, exact path, exact content}.
2. {...}

## Acceptance

- {human-readable criteria}
