# MUSTER

Multi-harness Unified System for Task Execution & Review.

An orchestrator session (strong model) shards an approved plan into small, self-contained task files.
Executor sessions in any harness (Claude Code, Codex, cheap-model CLIs) each pick up one task in a fresh context, execute it, verify it, and report back - all through files.

**Status: design phase.** Nothing is built. These docs are a checkpoint of the converged design discussion.

## Docs

- [Problem](docs/problem.md) - the pains MUSTER exists to solve
- [Architecture](docs/architecture.md) - high-level solution
- [Decisions](docs/decisions.md) - decision ledger with rationale and rejected alternatives
