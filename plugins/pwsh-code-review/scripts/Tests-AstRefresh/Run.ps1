#requires -Version 7.4
<#
.SYNOPSIS
    Self-test for the AST auto-refresh wired into Get-DiffContext.ps1.

.DESCRIPTION
    Builds a temporary git repo, runs Get-DiffContext.ps1 against it, and
    asserts that:

      1. ast-index.json is created on the first call where the staged diff
         contains a PowerShell file (no manual Get-AstIndex run needed).
      2. Adding a new file to the staged diff and re-running picks the file
         up in the warm cache.
      3. Renaming a function (the file's hash changes) re-parses on the
         next call and reflects the new function name.
      4. Removing a file (`git rm`) prunes it from the index.
      5. A diff that contains no PowerShell files does NOT trigger the AST
         walk when the cache already exists (the refresh is opt-in via a
         pwsh-file change or a missing cache).

    Exits 0 on success, non-zero on any mismatch.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here       = Split-Path -Parent $PSCommandPath
$diffScript = Join-Path (Split-Path $here -Parent) 'Get-DiffContext.ps1'
if (-not (Test-Path $diffScript)) {
    Write-Error "Get-DiffContext.ps1 not found at $diffScript"
}

$failures = @()
function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if (-not $Condition) {
        $msg = "FAIL: $Name"
        if ($Detail) { $msg += " - $Detail" }
        $script:failures += $msg
        return
    }
    Write-Output "PASS: $Name"
}

# `-c commit.gpgsign=false` keeps these test commits deterministic on machines
# with a global commit-signing requirement.
function Invoke-GitCommit {
    param([string]$Message)
    git -c commit.gpgsign=false commit -m $Message --quiet 2>&1 | Out-Null
}

# Build a throwaway repo. The cleanup happens in finally so a failed assertion
# still releases the temp directory.
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("pwsh-review-astrefresh-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    Push-Location $tempRoot
    try {
        # Minimal git repo so Get-DiffContext's `git diff --cached` calls work.
        git init --quiet 2>&1 | Out-Null
        git config user.email 'astrefresh-test@example.invalid' 2>&1 | Out-Null
        git config user.name  'AST Refresh Test' 2>&1 | Out-Null

        # Empty initial commit so HEAD exists. Without it, the script's
        # `git rev-parse HEAD` for diff_base prints noisy stderr on the
        # first call (the script tolerates it, but it pollutes the test
        # output).
        git -c commit.gpgsign=false commit --allow-empty -m 'init' --quiet 2>&1 | Out-Null

        # Initial file with one function. Staged so the first Get-DiffContext
        # call sees a non-empty diff.
        $fileA = Join-Path $tempRoot 'src/ModuleA.ps1'
        New-Item -ItemType Directory -Path (Split-Path $fileA -Parent) -Force | Out-Null
        @'
function Get-Alpha {
    [CmdletBinding()]
    param([string]$Name)
    "alpha: $Name"
}
'@ | Set-Content -Path $fileA -Encoding utf8NoBOM
        git add . 2>&1 | Out-Null

        $indexPath = Join-Path $tempRoot '.pwsh-review/cache/ast-index.json'

        # 1. Cold start: index must not exist before first run.
        Assert-True 'No index before first Get-DiffContext call' (-not (Test-Path $indexPath))

        # First call with a staged pwsh file should build the index.
        & $diffScript -RepoRoot $tempRoot -Mode Staged | Out-Null

        Assert-True 'Index created after first call (cold start)' (Test-Path $indexPath) `
            "Expected $indexPath to exist"

        $idx = Get-Content $indexPath -Raw | ConvertFrom-Json -AsHashtable
        $hasAlpha = $idx.files.Contains('src/ModuleA.ps1') -and
                    ($idx.files['src/ModuleA.ps1'].functions | Where-Object { $_.name -eq 'Get-Alpha' })
        Assert-True 'Cold-start index includes Get-Alpha' $hasAlpha

        Invoke-GitCommit 'add ModuleA'

        # 2. Add a new pwsh file. Staging it triggers a refresh that picks it up.
        $fileB = Join-Path $tempRoot 'src/ModuleB.ps1'
        @'
function Get-Beta {
    param([int]$N)
    $N * 2
}
'@ | Set-Content -Path $fileB -Encoding utf8NoBOM
        git add . 2>&1 | Out-Null

        & $diffScript -RepoRoot $tempRoot -Mode Staged | Out-Null

        $idx = Get-Content $indexPath -Raw | ConvertFrom-Json -AsHashtable
        $hasBeta = $idx.files.Contains('src/ModuleB.ps1') -and
                   ($idx.files['src/ModuleB.ps1'].functions | Where-Object { $_.name -eq 'Get-Beta' })
        Assert-True 'New file Get-Beta indexed by warm refresh' $hasBeta

        Invoke-GitCommit 'add ModuleB'

        # 3. Rename Get-Alpha -> Get-AlphaPrime in ModuleA. The hash changes,
        # so the warm refresh must re-parse and reflect the new function name.
        @'
function Get-AlphaPrime {
    [CmdletBinding()]
    param([string]$Name)
    "alpha-prime: $Name"
}
'@ | Set-Content -Path $fileA -Encoding utf8NoBOM
        git add . 2>&1 | Out-Null

        & $diffScript -RepoRoot $tempRoot -Mode Staged | Out-Null

        $idx = Get-Content $indexPath -Raw | ConvertFrom-Json -AsHashtable
        $aFuncs = @($idx.files['src/ModuleA.ps1'].functions | ForEach-Object { $_.name })
        Assert-True 'ModuleA reparsed: Get-AlphaPrime present' ('Get-AlphaPrime' -in $aFuncs)
        Assert-True 'ModuleA reparsed: Get-Alpha gone'         ('Get-Alpha' -notin $aFuncs)

        Invoke-GitCommit 'rename Get-Alpha to Get-AlphaPrime'

        # 4. Stage a deletion of ModuleB. Refresh prunes it.
        git rm -- 'src/ModuleB.ps1' 2>&1 | Out-Null

        & $diffScript -RepoRoot $tempRoot -Mode Staged | Out-Null

        $idx = Get-Content $indexPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True 'Deleted ModuleB pruned from index' (-not $idx.files.Contains('src/ModuleB.ps1'))

        Invoke-GitCommit 'remove ModuleB'

        # 5. md-only diff: the index must remain valid but should NOT be
        # rewritten. Capture the file's mtime, run, compare. (The optimization
        # skips the walk; the file must not be touched.)
        $readme = Join-Path $tempRoot 'README.md'
        '# repo' | Set-Content -Path $readme -Encoding utf8NoBOM
        git add . 2>&1 | Out-Null

        $beforeWrite = (Get-Item -LiteralPath $indexPath).LastWriteTimeUtc
        Start-Sleep -Milliseconds 50  # ensure mtime granularity won't tie

        & $diffScript -RepoRoot $tempRoot -Mode Staged | Out-Null

        $afterWrite = (Get-Item -LiteralPath $indexPath).LastWriteTimeUtc
        Assert-True 'md-only diff did not rewrite the AST index (optimization)' `
            ($beforeWrite -eq $afterWrite) `
            "before=$beforeWrite after=$afterWrite"

    } finally {
        Pop-Location
    }
} finally {
    if (Test-Path $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output ''
if ($failures.Count -gt 0) {
    Write-Output 'FAILURES:'
    foreach ($msg in $failures) { Write-Output "  $msg" }
    exit 1
}
Write-Output 'All AST-refresh self-tests passed.'
exit 0
