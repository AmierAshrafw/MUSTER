# MUSTER v2 cutover checklist (human, after /muster:close of the v2build plan)

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
