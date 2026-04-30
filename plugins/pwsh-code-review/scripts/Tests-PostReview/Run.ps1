#requires -Version 7.4
<#
.SYNOPSIS
    Self-test runner for Post-PrReview.ps1.

.DESCRIPTION
    Synthesises merged-findings.json and diff-context.json fixtures, runs
    Post-PrReview.ps1 in -DryRun mode, and asserts the resulting GitHub
    review payload:

      - verdict -> event mapping (ship -> APPROVE, fix majors -> REQUEST_CHANGES,
        needs rework -> REQUEST_CHANGES, unknown -> COMMENT)
      - ASCII folding (em dash -> --, right arrow -> ->, smart quotes -> ',
        non-mapped non-ASCII dropped)
      - In-hunk line preserved as-is
      - Out-of-hunk line clamped to first hunk's start
      - File with zero hunks -> comment posted file-level (no `line` field)
      - Suggestion block preserved verbatim
      - Body is summary-only (counts + verdict, no per-finding details)
      - Comment count matches non-skipped findings

    Exits 0 on success, non-zero on any mismatch.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here       = Split-Path -Parent $PSCommandPath
$scriptsDir = Split-Path -Parent $here
$scriptPath = Join-Path $scriptsDir 'Post-PrReview.ps1'
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

function New-Scenario {
    <#
    Create a temp repo with synthetic merged-findings.json + diff-context.json.
    Returns the temp root path.
    #>
    param(
        [object[]]$Findings,
        [string]$Verdict,
        [hashtable]$Counts,
        [object[]]$Hunks
    )
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("postreview-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path "$temp/.pwsh-review/cache" -Force | Out-Null

    $merged = [ordered]@{
        schema_version = '1'
        plugin_version = '0.0.0-test'
        generated      = (Get-Date).ToUniversalTime().ToString('o')
        counts         = $Counts
        verdict        = $Verdict
        findings       = $Findings
    }
    $merged | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath (Join-Path $temp '.pwsh-review/cache/merged-findings.json') -Encoding utf8NoBOM

    $diff = [ordered]@{
        schema_version = '1'
        changed_files  = @($Hunks | ForEach-Object { $_.file } | Sort-Object -Unique)
        changed_hunks  = $Hunks
    }
    $diff | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath (Join-Path $temp '.pwsh-review/cache/diff-context.json') -Encoding utf8NoBOM

    return $temp
}

function Invoke-DryRun {
    param([string]$TempRoot)
    $payloadPath = Join-Path $TempRoot 'payload.json'
    & $scriptPath -RepoRoot $TempRoot -DryRunPath $payloadPath | Out-Null
    if (-not (Test-Path $payloadPath)) { throw "Post-PrReview did not write $payloadPath" }
    return Get-Content -LiteralPath $payloadPath -Raw | ConvertFrom-Json
}

function Remove-Scenario {
    param([string]$TempRoot)
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Scenario 1: full coverage -- verdict, hunk constraints, ASCII fold, suggestion block

$scenario1Counts = @{ blocker = 1; major = 1; minor = 0; nit = 0; question = 0; praise = 0 }
$scenario1Findings = @(
    [ordered]@{
        severity   = 'blocker'
        confidence = 95
        rule       = 'PWSH-DIFF-100'
        file       = 'src/Foo.ps1'
        line_start = 12
        line_end   = 12
        message    = 'Em dash em-dash here is bad on Windows.'
        consequence = 'Pipeline mangling.'
        fix         = 'Use -- instead.'
        fix_snippet = "Get-Foo --param 'value'"
    }
    [ordered]@{
        severity   = 'major'
        confidence = 75
        rule       = 'PWSH-DIFF-101'
        file       = 'src/Foo.ps1'
        line_start = 999            # out of every hunk
        line_end   = 999
        message    = 'Right arrow becomes ASCII arrow. Smart quote is also gone.'
    }
    [ordered]@{
        severity    = 'minor'
        confidence  = 85
        rule        = 'PWSH-COV-001'
        file        = 'src/Bar.ps1'   # file with no hunks at all
        line_start  = 1
        line_end    = 1
        message     = 'No hunks for this file; comment must attach file-level.'
    }
)
$scenario1Hunks = @(
    [pscustomobject]@{ file = 'src/Foo.ps1'; line_start = 10; line_end = 20 }
    [pscustomobject]@{ file = 'src/Foo.ps1'; line_start = 50; line_end = 60 }
)

# Inject the actual UTF-8 chars into the messages so the ASCII filter is exercised.
$scenario1Findings[0].message     = "Em dash $([char]0x2014) em-dash here is bad on Windows."
$scenario1Findings[1].message     = "Right arrow $([char]0x2192) becomes ASCII arrow. $([char]0x201C)Smart quote$([char]0x201D) is also gone."

$tmp1 = New-Scenario -Findings $scenario1Findings -Verdict 'needs rework' -Counts $scenario1Counts -Hunks $scenario1Hunks
$payload1 = Invoke-DryRun -TempRoot $tmp1

Assert-True 'S1: event=REQUEST_CHANGES for needs rework' ($payload1.event -eq 'REQUEST_CHANGES')

Assert-True 'S1: 3 comments emitted' (@($payload1.comments).Count -eq 3) `
    "got $((@($payload1.comments)).Count)"

# In-hunk line preserved (line 12 is in hunk [10..20])
$inHunkComment = $payload1.comments | Where-Object { $_.path -eq 'src/Foo.ps1' -and $_.body -like '*Em dash*' }
Assert-True 'S1: in-hunk finding keeps original line 12' ($inHunkComment.line -eq 12)
Assert-True 'S1: in-hunk comment side=RIGHT'             ($inHunkComment.side -eq 'RIGHT')

# Out-of-hunk line clamped to first hunk's start (10)
$clampedComment = $payload1.comments | Where-Object { $_.path -eq 'src/Foo.ps1' -and $_.body -like '*Right arrow*' }
Assert-True 'S1: out-of-hunk finding clamps to first hunk start (10)' ($clampedComment.line -eq 10)

# File with no hunks: comment posted without a `line` field (file-level)
$fileLevelComment = $payload1.comments | Where-Object { $_.path -eq 'src/Bar.ps1' }
Assert-True 'S1: no-hunks file gets a comment'           ($null -ne $fileLevelComment)
Assert-True 'S1: no-hunks comment omits line field' `
    (-not ($fileLevelComment.PSObject.Properties.Name -contains 'line'))

# ASCII folding inside the comment bodies
Assert-True 'S1: em dash folded to "--"'     ($inHunkComment.body -like '*--*' -and $inHunkComment.body -notmatch [regex]::Escape([string][char]0x2014))
Assert-True 'S1: right arrow folded to "->"' ($clampedComment.body -like '*->*' -and $clampedComment.body -notmatch [regex]::Escape([string][char]0x2192))
Assert-True 'S1: smart quote folded to ASCII' ($clampedComment.body -notmatch [regex]::Escape([string][char]0x201C))

# Suggestion block preserved as-is
Assert-True 'S1: suggestion block preserved' ($inHunkComment.body -like '*```suggestion*')
Assert-True 'S1: suggestion block contains the snippet' ($inHunkComment.body -like '*Get-Foo --param*')

# Body is summary-only: contains counts and Verdict, but NOT per-finding messages
Assert-True 'S1: body has count line'        ($payload1.body -like '*1 blocker, 1 major*')
Assert-True 'S1: body shows verdict'         ($payload1.body -like '*needs rework*')
Assert-True 'S1: body excludes finding text' (-not ($payload1.body -like '*Em dash*'))

Remove-Scenario -TempRoot $tmp1

# --- Scenario 2: verdict 'ship' -> APPROVE -----------------------------------

$tmp2 = New-Scenario `
    -Findings @() `
    -Verdict 'ship' `
    -Counts @{ blocker = 0; major = 0; minor = 0; nit = 0; question = 0; praise = 0 } `
    -Hunks @()

$payload2 = Invoke-DryRun -TempRoot $tmp2
Assert-True 'S2: event=APPROVE for ship verdict' ($payload2.event -eq 'APPROVE')
Assert-True 'S2: zero comments when no findings' (@($payload2.comments).Count -eq 0)
Remove-Scenario -TempRoot $tmp2

# --- Scenario 3: verdict 'fix majors first' -> REQUEST_CHANGES ----------------

$tmp3 = New-Scenario `
    -Findings @(
        [ordered]@{
            severity   = 'major'
            confidence = 85
            rule       = 'PWSH-CONV-001'
            file       = 'src/Foo.ps1'
            line_start = 5
            line_end   = 5
            message    = 'Naming.'
        }
    ) `
    -Verdict 'fix majors first' `
    -Counts @{ blocker = 0; major = 1; minor = 0; nit = 0; question = 0; praise = 0 } `
    -Hunks @([pscustomobject]@{ file = 'src/Foo.ps1'; line_start = 1; line_end = 10 })

$payload3 = Invoke-DryRun -TempRoot $tmp3
Assert-True 'S3: event=REQUEST_CHANGES for fix majors first' ($payload3.event -eq 'REQUEST_CHANGES')
Remove-Scenario -TempRoot $tmp3

# --- Scenario 4: unknown verdict -> COMMENT ----------------------------------

$tmp4 = New-Scenario `
    -Findings @() `
    -Verdict 'gibberish' `
    -Counts @{ blocker = 0; major = 0; minor = 0; nit = 0; question = 0; praise = 0 } `
    -Hunks @()

$payload4 = Invoke-DryRun -TempRoot $tmp4
Assert-True 'S4: unknown verdict falls back to COMMENT' ($payload4.event -eq 'COMMENT')
Remove-Scenario -TempRoot $tmp4

# --- Scenario 5: multi-line range across one hunk ----------------------------

$tmp5 = New-Scenario `
    -Findings @(
        [ordered]@{
            severity   = 'minor'
            confidence = 90
            rule       = 'PWSH-IDIOM-005'
            file       = 'src/Foo.ps1'
            line_start = 12
            line_end   = 18
            message    = 'Range finding.'
        }
    ) `
    -Verdict 'ship' `
    -Counts @{ blocker = 0; major = 0; minor = 1; nit = 0; question = 0; praise = 0 } `
    -Hunks @([pscustomobject]@{ file = 'src/Foo.ps1'; line_start = 10; line_end = 20 })

$payload5 = Invoke-DryRun -TempRoot $tmp5
$rangeComment = $payload5.comments | Where-Object { $_.path -eq 'src/Foo.ps1' }
Assert-True 'S5: range finding has start_line=12' ($rangeComment.start_line -eq 12)
Assert-True 'S5: range finding has line=18'       ($rangeComment.line -eq 18)
Assert-True 'S5: range finding has start_side=RIGHT' ($rangeComment.start_side -eq 'RIGHT')
Remove-Scenario -TempRoot $tmp5

Write-Output ''
if ($failures.Count -gt 0) {
    Write-Output 'FAILURES:'
    foreach ($msg in $failures) { Write-Output "  $msg" }
    exit 1
}
Write-Output 'All Post-PrReview self-tests passed.'
exit 0
