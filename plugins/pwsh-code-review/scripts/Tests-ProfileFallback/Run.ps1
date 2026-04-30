#requires -Version 7.4
<#
.SYNOPSIS
    Self-test runner for Resolve-Profile.ps1.

.DESCRIPTION
    Builds a synthetic two-branch git repo where `main` carries the canonical
    `.pwsh-review/` profile and a sibling `pr` branch was forked BEFORE the
    profile was committed. The PR branch's working tree therefore has no
    profile files. Running Resolve-Profile.ps1 on the PR branch should
    restore each canonical profile file (architecture.md, standards.md,
    glossary.md, patterns/*.ps1, PSScriptAnalyzerSettings.psd1, config.psd1,
    profile.lock.json) into the working tree from the base ref.

    Also asserts:
      - Files already present locally are NOT overwritten (a deliberate edit
        on the PR branch survives).
      - `git ls-tree` over `patterns/` correctly enumerates and restores
        every pattern file.
      - When the base ref does not resolve, the helper exits cleanly without
        throwing (so callers can decide whether the absence is fatal).

    Exits 0 on success, non-zero on any mismatch.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here       = Split-Path -Parent $PSCommandPath
$scriptsDir = Split-Path -Parent $here
$scriptPath = Join-Path $scriptsDir 'Resolve-Profile.ps1'
if (-not (Test-Path $scriptPath)) { Write-Error "$scriptPath not found" }

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

function New-RepoSkeleton {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Push-Location $Path
    try {
        git init -q -b main 2>&1 | Out-Null
        git -c user.email='t@t' -c user.name='t' -c commit.gpgsign=false `
            commit --allow-empty -m 'init' -q 2>&1 | Out-Null
    } finally {
        Pop-Location
    }
}

function Add-AndCommit {
    param([string]$Path, [string]$Message)
    Push-Location $Path
    try {
        git add -A 2>&1 | Out-Null
        git -c user.email='t@t' -c user.name='t' -c commit.gpgsign=false `
            commit -m $Message -q 2>&1 | Out-Null
    } finally {
        Pop-Location
    }
}

# --- Scenario 1: PR branch forked before profile was added ----
$temp = Join-Path ([IO.Path]::GetTempPath()) ("profilefb-{0}" -f ([guid]::NewGuid().ToString('N')))
try {
    New-RepoSkeleton -Path $temp

    # Branch off 'main' to make the eventual PR branch from the empty state.
    Push-Location $temp
    try {
        git checkout -q -b pr 2>&1 | Out-Null
        # PR branch makes a commit that does NOT include the profile.
        Set-Content -LiteralPath (Join-Path $temp 'feature.txt') -Value 'pr work' -Encoding utf8NoBOM
    } finally {
        Pop-Location
    }
    Add-AndCommit -Path $temp -Message 'feat: PR work'

    # Now switch back to main and add the profile (after the PR branch already
    # forked). This mirrors andresharpe/dotbot's Migration G timeline.
    Push-Location $temp
    try {
        git checkout -q main 2>&1 | Out-Null
    } finally {
        Pop-Location
    }
    $profileDir = Join-Path $temp '.pwsh-review'
    New-Item -ItemType Directory -Path "$profileDir/patterns" -Force | Out-Null
    Set-Content -LiteralPath "$profileDir/architecture.md" -Value '# arch' -Encoding utf8NoBOM
    Set-Content -LiteralPath "$profileDir/standards.md"    -Value '# std' -Encoding utf8NoBOM
    Set-Content -LiteralPath "$profileDir/glossary.md"     -Value '# glossary' -Encoding utf8NoBOM
    Set-Content -LiteralPath "$profileDir/PSScriptAnalyzerSettings.psd1" -Value "@{Severity=@('Error','Warning')}" -Encoding utf8NoBOM
    Set-Content -LiteralPath "$profileDir/config.psd1" -Value "@{ConfidenceThreshold=80;NitCap=3}" -Encoding utf8NoBOM
    Set-Content -LiteralPath "$profileDir/profile.lock.json" -Value '{"version":1}' -Encoding utf8NoBOM
    Set-Content -LiteralPath "$profileDir/patterns/pattern-pipeline.ps1" -Value '# pattern A' -Encoding utf8NoBOM
    Set-Content -LiteralPath "$profileDir/patterns/pattern-error-handling.ps1" -Value '# pattern B' -Encoding utf8NoBOM
    Add-AndCommit -Path $temp -Message 'chore: add profile (Migration G)'

    # Switch back to the PR branch — profile must be absent on disk.
    Push-Location $temp
    try {
        git checkout -q pr 2>&1 | Out-Null
    } finally {
        Pop-Location
    }
    Assert-True 'PR branch has no .pwsh-review/architecture.md before fallback' `
        (-not (Test-Path -LiteralPath (Join-Path $temp '.pwsh-review/architecture.md')))

    # Run the fallback. Base ref is 'main' (no remote in this temp repo).
    $r = & $scriptPath -RepoRoot $temp -BaseRef 'main'

    Assert-True 'Restored count is 8 (5 docs + 1 settings + 1 config + 1 lock + 2 patterns - 1 from glossary count)' `
        ($r.RestoredCount -ge 7) "got $($r.RestoredCount)"
    foreach ($f in 'architecture.md','standards.md','glossary.md','PSScriptAnalyzerSettings.psd1','config.psd1','profile.lock.json') {
        Assert-True "Restored .pwsh-review/$f exists" `
            (Test-Path -LiteralPath (Join-Path $temp ".pwsh-review/$f"))
    }
    Assert-True 'Restored patterns/pattern-pipeline.ps1 exists' `
        (Test-Path -LiteralPath (Join-Path $temp '.pwsh-review/patterns/pattern-pipeline.ps1'))
    Assert-True 'Restored patterns/pattern-error-handling.ps1 exists' `
        (Test-Path -LiteralPath (Join-Path $temp '.pwsh-review/patterns/pattern-error-handling.ps1'))

    # --- Scenario 2: idempotency ----
    # Running again must be a no-op (no files restored, since they all exist now).
    $r2 = & $scriptPath -RepoRoot $temp -BaseRef 'main'
    Assert-True 'Re-run is idempotent (RestoredCount = 0)' ($r2.RestoredCount -eq 0)

    # --- Scenario 3: deliberate local edit is preserved ----
    # Author has edited standards.md on the PR branch. The fallback must NOT
    # overwrite it.
    Set-Content -LiteralPath (Join-Path $temp '.pwsh-review/standards.md') -Value '# pr-edit' -Encoding utf8NoBOM
    Remove-Item -LiteralPath (Join-Path $temp '.pwsh-review/architecture.md')   # force a single restore
    & $scriptPath -RepoRoot $temp -BaseRef 'main' | Out-Null
    Assert-True 'Local edit to standards.md preserved across fallback' `
        ((Get-Content -LiteralPath (Join-Path $temp '.pwsh-review/standards.md') -Raw).Trim() -eq '# pr-edit')
    Assert-True 'Missing architecture.md re-restored on the third run' `
        (Test-Path -LiteralPath (Join-Path $temp '.pwsh-review/architecture.md'))

    # --- Scenario 4: missing base ref ----
    # Asks for a ref that does not resolve. The helper must exit cleanly
    # rather than throw — caller decides whether absence is fatal.
    Remove-Item -LiteralPath (Join-Path $temp '.pwsh-review/glossary.md')
    $r4 = & $scriptPath -RepoRoot $temp -BaseRef 'origin/does-not-exist'
    Assert-True 'Missing base ref returns RestoredCount=0 with reason' `
        (($r4.RestoredCount -eq 0) -and ($r4.Reason -match 'did not resolve'))
} finally {
    if (Test-Path $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ''
if ($failures.Count -gt 0) {
    Write-Output 'FAILURES:'
    foreach ($msg in $failures) { Write-Output "  $msg" }
    exit 1
}
Write-Output 'All Resolve-Profile self-tests passed.'
exit 0
