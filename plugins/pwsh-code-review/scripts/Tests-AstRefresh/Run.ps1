#requires -Version 7.4
<#
.SYNOPSIS
    Self-test for the AST auto-refresh wired into Get-DiffContext.ps1.

.DESCRIPTION
    Builds a temporary git repo, runs Get-DiffContext.ps1 against it, and
    asserts that:

      1. ast-index.json is created on a cold start (no manual Get-AstIndex run).
      2. Adding a new file and re-running Get-DiffContext picks the file up.
      3. Modifying an existing file and re-running picks the new function shape
         up (re-parses based on SHA256, not just file presence).
      4. Deleting a file and re-running prunes it from the index.

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

# Build a throwaway repo. The cleanup happens in finally so a failed assertion
# still releases the temp directory.
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("pwsh-review-astrefresh-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    Push-Location $tempRoot
    try {
        # Minimal git repo so Get-DiffContext's `git diff` calls succeed
        # (the refresh runs before the diff is parsed, but we still want the
        # script to complete without throwing).
        git init --quiet 2>&1 | Out-Null
        git config user.email 'astrefresh-test@example.invalid' 2>&1 | Out-Null
        git config user.name  'AST Refresh Test' 2>&1 | Out-Null

        # Initial file with one function.
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
        git commit -m 'initial' --quiet 2>&1 | Out-Null

        $indexPath = Join-Path $tempRoot '.pwsh-review/cache/ast-index.json'

        # 1. Cold start: ast-index.json must not exist before the run.
        Assert-True 'No index before first Get-DiffContext call' (-not (Test-Path $indexPath))

        & $diffScript -RepoRoot $tempRoot -Mode Working | Out-Null

        Assert-True 'Index created after first Get-DiffContext call' (Test-Path $indexPath) `
            "Expected $indexPath to exist"

        $idx = Get-Content $indexPath -Raw | ConvertFrom-Json -AsHashtable
        $hasAlpha = $idx.files.Contains('src/ModuleA.ps1') -and
                    ($idx.files['src/ModuleA.ps1'].functions | Where-Object { $_.name -eq 'Get-Alpha' })
        Assert-True 'Cold-start index includes Get-Alpha' $hasAlpha

        # 2. Add a brand-new file. Refresh should pick it up.
        $fileB = Join-Path $tempRoot 'src/ModuleB.ps1'
        @'
function Get-Beta {
    param([int]$N)
    $N * 2
}
'@ | Set-Content -Path $fileB -Encoding utf8NoBOM

        & $diffScript -RepoRoot $tempRoot -Mode Working | Out-Null

        $idx = Get-Content $indexPath -Raw | ConvertFrom-Json -AsHashtable
        $hasBeta = $idx.files.Contains('src/ModuleB.ps1') -and
                   ($idx.files['src/ModuleB.ps1'].functions | Where-Object { $_.name -eq 'Get-Beta' })
        Assert-True 'New file Get-Beta indexed by warm refresh' $hasBeta

        # 3. Modify ModuleA: rename Get-Alpha -> Get-AlphaPrime. Hash changes,
        # so the warm refresh must re-parse and reflect the new function name.
        @'
function Get-AlphaPrime {
    [CmdletBinding()]
    param([string]$Name)
    "alpha-prime: $Name"
}
'@ | Set-Content -Path $fileA -Encoding utf8NoBOM

        & $diffScript -RepoRoot $tempRoot -Mode Working | Out-Null

        $idx = Get-Content $indexPath -Raw | ConvertFrom-Json -AsHashtable
        $aFuncs = @($idx.files['src/ModuleA.ps1'].functions | ForEach-Object { $_.name })
        Assert-True 'ModuleA reparsed: Get-AlphaPrime present' ('Get-AlphaPrime' -in $aFuncs)
        Assert-True 'ModuleA reparsed: Get-Alpha gone'         ('Get-Alpha' -notin $aFuncs)

        # 4. Delete ModuleB. Refresh prunes it.
        Remove-Item -LiteralPath $fileB -Force

        & $diffScript -RepoRoot $tempRoot -Mode Working | Out-Null

        $idx = Get-Content $indexPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True 'Deleted ModuleB pruned from index' (-not $idx.files.Contains('src/ModuleB.ps1'))

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
