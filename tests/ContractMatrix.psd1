@{
    Rows = @(
        @{ Id = 'CM-STATUS-OK';    File = 'tests/Status.Tests.ps1';  It = 'prints the status block with the dispatch split and exits 0'; Eligible = $true }
        @{ Id = 'CM-STATUS-FAIL';  File = 'tests/ProcessContract.Tests.ps1'; It = 'status refuses outside a git repository with exit 1';        Eligible = $false }
        @{ Id = 'CM-LINT-OK';      File = 'tests/Lint.Tests.ps1';    It = 'passes a well-formed batch';                                  Eligible = $true }
        @{ Id = 'CM-LINT-FAIL';    File = 'tests/Lint.Tests.ps1';    It = 'check 2: flags id not matching filename and filename collisions'; Eligible = $true }
        @{ Id = 'CM-CLAIM-OK';     File = 'tests/Claim.Tests.ps1';   It = 'claims the lowest eligible filename, stamps claimed_at, commits'; Eligible = $true }
        @{ Id = 'CM-CLAIM-FAIL';   File = 'tests/Claim.Tests.ps1';   It = 'refuses without identity flags';                              Eligible = $false }
        @{ Id = 'CM-DONE-OK';      File = 'tests/Done.Tests.ps1';    It = 'completes an impl task: sidecars in done/, single completion commit, session-over line'; Eligible = $true }
        @{ Id = 'CM-DONE-FAIL';    File = 'tests/Done.Tests.ps1';    It = 'refuses when doing/ is empty';                                Eligible = $true }
        @{ Id = 'CM-VERIFY-OK';    File = 'tests/Verify.Tests.ps1';  It = 'passes a green task and logs attempt 1';                      Eligible = $true }
        @{ Id = 'CM-VERIFY-FAIL';  File = 'tests/Verify.Tests.ps1';  It = 'refuses when doing/ is empty';                                Eligible = $true }
        @{ Id = 'CM-PROMOTE-OK';   File = 'tests/Promote.Tests.ps1'; It = 'moves a backlog task whose deps are all in done/ and commits'; Eligible = $true }
        @{ Id = 'CM-PROMOTE-FAIL'; File = 'tests/ProcessContract.Tests.ps1'; It = 'promote refuses outside a git repository with exit 1';       Eligible = $false }
        @{ Id = 'CM-ARG-CLAIM';    File = 'tests/Claim.Tests.ps1';   It = 'enforces tier pinning both directions';                       Eligible = $true }
        @{ Id = 'CM-ARG-DONE';     File = 'tests/Done.Tests.ps1';    It = 'refuses a verdict on impl tasks and requires one on review tasks'; Eligible = $true }
        @{ Id = 'CM-ARG-LINT';     File = 'tests/Lint.Tests.ps1';    It = 'lite mode: skips 11/12, exempts self-collision, rejects generation'; Eligible = $true }
        @{ Id = 'CM-ARG-PROMOTE';  File = 'tests/Promote.Tests.ps1'; It = 'with -NoCommit stages the rename without committing';         Eligible = $true }
        @{ Id = 'CM-ORDER';        File = 'tests/Claim.Tests.ps1';   It = 'prints the status block before any refusal';                  Eligible = $true }
        @{ Id = 'CM-TERMINAL';     File = 'tests/Done.Tests.ps1';    It = 'prints the counts-only board line directly before the terminal line'; Eligible = $true }
        @{ Id = 'CM-LAYOUT';       File = 'tests/Harness.Tests.ps1'; It = 'New-MusterFixture satisfies the fixture contract';            Eligible = $false }
        @{ Id = 'CM-GITFAIL';      File = 'tests/ProcessContract.Tests.ps1'; It = 'claim refuses outside a git repository with exit 1';         Eligible = $false }
        @{ Id = 'CM-CO-UNCOMMITTED'; File = 'tests/ProcessContract.Tests.ps1'; It = 'done refuses an uncommitted doing task';                   Eligible = $false }
        @{ Id = 'CM-CO-CRLF';        File = 'tests/Done.Tests.ps1';  It = 'commits an executor CRLF commit_path as an LF blob when the repo pins eol=lf'; Eligible = $false }
        @{ Id = 'CM-CO-PROMOTE-WARN'; File = 'tests/Promote.Tests.ps1'; It = 'skips malformed backlog files with a warning';             Eligible = $true }
        @{ Id = 'CM-PROMOTE-WARN-CLAIM'; File = 'tests/ProcessContract.Tests.ps1'; It = 'claim surfaces the promote skip warning for malformed backlog files'; Eligible = $true }
    )
}
