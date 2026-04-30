#requires -Version 7.4
<#
.SYNOPSIS
    Self-test runner for Get-PriorReviews.ps1.

.DESCRIPTION
    Replays three captured GraphQL response fixtures through the parser and
    asserts the resulting cache shape: bot detection, per-thread (not
    per-comment) accounting, mid-thread bot detection, multi-bot coverage,
    top-level reviews, replay-mode hygiene, and empty/no-PR edge cases.

    Bot detection is exercised through fixture replay AND directly via the
    shared helper `_PriorReviewHelpers.ps1` so the test always tracks the
    production logic rather than a re-implementation of it.

    Exits 0 on success, non-zero on any mismatch.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here       = Split-Path -Parent $PSCommandPath
$scriptsDir = Split-Path -Parent $here
$scriptPath = Join-Path $scriptsDir 'Get-PriorReviews.ps1'
$helperPath = Join-Path $scriptsDir '_PriorReviewHelpers.ps1'
foreach ($p in @($scriptPath, $helperPath)) {
    if (-not (Test-Path $p)) { Write-Error "$p not found" }
}

# Dot-source the production bot-detection helper. Test-IsBotAuthor and
# $script:KnownBotLogins now live in the test's scope and the assertions
# below exercise the same code the live script uses.
. $helperPath

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

# Per-thread accounting: 4 unresolved bot threads
#   - copilot finding (3 comments, 2 of them bot-authored)  -> 1 entry
#   - coderabbit suggestion (1 comment)                     -> 1 entry
#   - dependabot bump (1 comment)                           -> 1 entry
#   - human-started + renovate reply (2 comments)           -> 1 entry
# Plus 1 human-only thread that must NOT appear.
Assert-True 'Mixed: 4 unresolved bot threads (per-thread accounting)' `
    ($mixed.unresolved_threads.Count -eq 4) `
    "got $($mixed.unresolved_threads.Count)"

# Multi-bot-comment thread: must contribute exactly one entry, using the FIRST
# bot comment as the canonical context.
$copilotThread = $mixed.unresolved_threads | Where-Object {
    $_.path -eq 'scripts/Foo.ps1' -and $_.line -eq 42
}
Assert-True 'Mixed: copilot thread contributed exactly 1 entry (multiple bot replies collapse)' `
    ((@($copilotThread)).Count -eq 1)
Assert-True 'Mixed: copilot entry uses the FIRST bot comment body' `
    ($copilotThread.body -like '*-LiteralPath*')

# Bot mid-thread (human comment first, bot second): must still be picked up.
$renovateThread = $mixed.unresolved_threads | Where-Object {
    $_.bot -eq 'renovate[bot]'
}
Assert-True 'Mixed: bot reply mid-thread is still ingested' `
    ($null -ne $renovateThread)

# Resolved thread with two bot comments: must count as 1 (per-thread, not per-comment).
Assert-True 'Mixed: 1 resolved thread (multiple bot comments collapse to one count)' `
    ($mixed.resolved_threads_count -eq 1) `
    "got $($mixed.resolved_threads_count)"

# Human-only thread must not appear in the unresolved list at all.
Assert-True 'Mixed: human-only thread filtered out' `
    (-not ($mixed.unresolved_threads | Where-Object { $_.path -eq 'scripts/Foo.ps1' -and $_.line -eq 88 }))

# Top-level reviews: only one bot review with a non-empty body.
Assert-True 'Mixed: 1 top-level bot review (empty body filtered)' `
    ($mixed.top_level_reviews.Count -eq 1)
Assert-True 'Mixed: top-level review is from copilot' `
    ($mixed.top_level_reviews[0].bot -eq 'copilot-pull-request-reviewer[bot]')

# bots[] must contain every distinct bot login encountered.
Assert-True 'Mixed: bots includes copilot[bot]'      ('copilot-pull-request-reviewer[bot]' -in $mixed.bots)
Assert-True 'Mixed: bots includes coderabbitai'      ('coderabbitai' -in $mixed.bots)
Assert-True 'Mixed: bots includes dependabot[bot]'   ('dependabot[bot]' -in $mixed.bots)
Assert-True 'Mixed: bots includes renovate[bot]'     ('renovate[bot]' -in $mixed.bots)
Assert-True 'Mixed: bots excludes andresharpe'       ('andresharpe' -notin $mixed.bots)
Assert-True 'Mixed: bots excludes github-actions[bot] (review body was empty)' `
    ('github-actions[bot]' -notin $mixed.bots)

# Replay-mode hygiene: the cache must NOT carry a bogus `pr` field.
Assert-True 'Mixed (replay mode): no `pr` field in cache' `
    (-not $mixed.Contains('pr')) `
    "Replay mode should omit the field; got pr=$($mixed['pr'])"

# --- Scenario 2: empty fixture ----------------------------------------------
$empty = Invoke-Replay -Fixture 'fixture-empty.json'

Assert-True 'Empty: zero unresolved threads' ($empty.unresolved_threads.Count -eq 0)
Assert-True 'Empty: zero resolved threads'   ($empty.resolved_threads_count -eq 0)
Assert-True 'Empty: zero top-level reviews'  ($empty.top_level_reviews.Count -eq 0)
Assert-True 'Empty: zero bots'               ($empty.bots.Count -eq 0)

# --- Scenario 3: PR not found (pullRequest: null) --------------------------
$noPr = Invoke-Replay -Fixture 'fixture-no-pr.json'

Assert-True 'NoPR: zero unresolved threads' ($noPr.unresolved_threads.Count -eq 0)
Assert-True 'NoPR: zero resolved threads'   ($noPr.resolved_threads_count -eq 0)
Assert-True 'NoPR: zero top-level reviews'  ($noPr.top_level_reviews.Count -eq 0)

# --- Scenario 4: Test-IsBotAuthor unit checks via the production helper -----
# These call the SAME function the live script uses (dot-sourced above).
Assert-True 'Detect: copilot[bot] -> bot'             (Test-IsBotAuthor 'copilot-pull-request-reviewer[bot]')
Assert-True 'Detect: dependabot[bot] -> bot'          (Test-IsBotAuthor 'dependabot[bot]')
Assert-True 'Detect: renovate[bot] -> bot'            (Test-IsBotAuthor 'renovate[bot]')
Assert-True 'Detect: codecov[bot] -> bot'             (Test-IsBotAuthor 'codecov[bot]')
Assert-True 'Detect: coderabbitai (bare) -> bot'      (Test-IsBotAuthor 'coderabbitai')
Assert-True 'Detect: SonarCloud (mixed case) -> bot'  (Test-IsBotAuthor 'SonarCloud')
Assert-True 'Detect: dependabot (no suffix) -> bot'   (Test-IsBotAuthor 'dependabot')
Assert-True 'Detect: renovate (no suffix) -> bot'     (Test-IsBotAuthor 'renovate')
Assert-True 'Detect: codecov-commenter -> bot'        (Test-IsBotAuthor 'codecov-commenter')
Assert-True 'Detect: andresharpe -> human'            (-not (Test-IsBotAuthor 'andresharpe'))
Assert-True 'Detect: empty -> false'                  (-not (Test-IsBotAuthor ''))

Write-Output ''
if ($failures.Count -gt 0) {
    Write-Output 'FAILURES:'
    foreach ($msg in $failures) { Write-Output "  $msg" }
    exit 1
}
Write-Output 'All Get-PriorReviews self-tests passed.'
exit 0
