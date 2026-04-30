#requires -Version 7.4
<#
.SYNOPSIS
    Self-test runner for Get-PriorReviews.ps1.

.DESCRIPTION
    Replays three captured GraphQL response fixtures through the parser and
    asserts the resulting cache shape: bot detection, resolved/unresolved
    partition, top-level reviews, and empty / no-PR edge cases.

    Exits 0 on success, non-zero on any mismatch.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here       = Split-Path -Parent $PSCommandPath
$scriptPath = Join-Path (Split-Path $here -Parent) 'Get-PriorReviews.ps1'
if (-not (Test-Path $scriptPath)) {
    Write-Error "Get-PriorReviews.ps1 not found at $scriptPath"
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

function Invoke-Replay {
    param([string]$Fixture)
    $tempOut  = Join-Path ([IO.Path]::GetTempPath()) ("prior-reviews-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $fixturePath = Join-Path $here $Fixture
    & $scriptPath -InputPath $fixturePath -OutputPath $tempOut -Owner 'O' -Repo 'R' | Out-Null
    if (-not (Test-Path -LiteralPath $tempOut)) {
        throw "Get-PriorReviews did not write $tempOut"
    }
    $cache = Get-Content -LiteralPath $tempOut -Raw | ConvertFrom-Json -AsHashtable
    Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
    return $cache
}

# --- Scenario 1: mixed fixture ----------------------------------------------
$mixed = Invoke-Replay -Fixture 'fixture-mixed.json'

Assert-True 'Mixed: 2 unresolved bot threads (Copilot + CodeRabbit)' `
    ($mixed.unresolved_threads.Count -eq 2) `
    "got $($mixed.unresolved_threads.Count)"

Assert-True 'Mixed: human-authored thread filtered out' `
    (-not ($mixed.unresolved_threads | Where-Object { $_.bot -eq 'andresharpe' }))

Assert-True 'Mixed: 1 resolved thread counted' `
    ($mixed.resolved_threads_count -eq 1) `
    "got $($mixed.resolved_threads_count)"

Assert-True 'Mixed: 1 top-level bot review (empty body filtered)' `
    ($mixed.top_level_reviews.Count -eq 1) `
    "got $($mixed.top_level_reviews.Count)"

Assert-True 'Mixed: top-level review is from copilot' `
    ($mixed.top_level_reviews[0].bot -eq 'copilot-pull-request-reviewer[bot]')

Assert-True 'Mixed: bots list contains copilot[bot]' `
    ('copilot-pull-request-reviewer[bot]' -in $mixed.bots)

Assert-True 'Mixed: bots list contains coderabbitai (no [bot] suffix)' `
    ('coderabbitai' -in $mixed.bots)

Assert-True 'Mixed: bots list excludes andresharpe' `
    ('andresharpe' -notin $mixed.bots)

Assert-True 'Mixed: github-actions[bot] empty body excluded from top-level' `
    (-not ($mixed.top_level_reviews | Where-Object { $_.bot -eq 'github-actions[bot]' }))

# Per-finding shape check on the unresolved thread.
$copilotThread = $mixed.unresolved_threads | Where-Object { $_.bot -eq 'copilot-pull-request-reviewer[bot]' } | Select-Object -First 1
Assert-True 'Mixed: copilot unresolved thread has path' ($copilotThread.path -eq 'scripts/Foo.ps1')
Assert-True 'Mixed: copilot unresolved thread has line' ($copilotThread.line -eq 42)
Assert-True 'Mixed: copilot unresolved thread has body' ($copilotThread.body -like '*-LiteralPath*')

# --- Scenario 2: empty fixture ----------------------------------------------
$empty = Invoke-Replay -Fixture 'fixture-empty.json'

Assert-True 'Empty: zero unresolved threads' ($empty.unresolved_threads.Count -eq 0)
Assert-True 'Empty: zero resolved threads' ($empty.resolved_threads_count -eq 0)
Assert-True 'Empty: zero top-level reviews' ($empty.top_level_reviews.Count -eq 0)
Assert-True 'Empty: zero bots'              ($empty.bots.Count -eq 0)

# --- Scenario 3: PR not found (pullRequest: null) --------------------------
$noPr = Invoke-Replay -Fixture 'fixture-no-pr.json'

Assert-True 'NoPR: zero unresolved threads' ($noPr.unresolved_threads.Count -eq 0)
Assert-True 'NoPR: zero resolved threads' ($noPr.resolved_threads_count -eq 0)
Assert-True 'NoPR: zero top-level reviews' ($noPr.top_level_reviews.Count -eq 0)

# --- Scenario 4: bot-detection unit checks -----------------------------------
# We deliberately don't dot-source Get-PriorReviews.ps1 (its [Parameter(Mandatory)]
# blocks would prompt). Instead, mirror the detection rule inline here. If the
# inlined rule diverges from the script, the mixed-fixture assertions above
# catch it — this scenario only covers logins that aren't in fixture-mixed.json.
function Test-Detect {
    param([string]$Login)
    # Inline the detection rule (must match Get-PriorReviews.ps1 exactly).
    # If the rule diverges, the mixed-fixture assertions above will catch it
    # — this scenario just covers names that aren't in the mixed fixture.
    $known = @('coderabbitai','sonarcloud','sonarqubecloud','snyk-bot','sentry-io','deepsource-io','codeclimate')
    if (-not $Login) { return $false }
    if ($Login -like '*[[]bot[]]') { return $true }
    return ($Login.ToLowerInvariant() -in $known)
}

Assert-True 'Detect: copilot[bot] -> bot' (Test-Detect 'copilot-pull-request-reviewer[bot]')
Assert-True 'Detect: dependabot[bot] -> bot' (Test-Detect 'dependabot[bot]')
Assert-True 'Detect: coderabbitai (bare) -> bot' (Test-Detect 'coderabbitai')
Assert-True 'Detect: SonarCloud (mixed case) -> bot' (Test-Detect 'SonarCloud')
Assert-True 'Detect: andresharpe -> human' (-not (Test-Detect 'andresharpe'))
Assert-True 'Detect: empty -> false' (-not (Test-Detect ''))

Write-Output ''
if ($failures.Count -gt 0) {
    Write-Output 'FAILURES:'
    foreach ($msg in $failures) { Write-Output "  $msg" }
    exit 1
}
Write-Output 'All Get-PriorReviews self-tests passed.'
exit 0
