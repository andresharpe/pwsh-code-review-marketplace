#requires -Version 7.4
<#
.SYNOPSIS
    Self-test runner for Merge-Findings.ps1 hunk-scope filter and per-rule
    severity overrides.

.DESCRIPTION
    Verifies two pieces of merger behaviour added to keep PR-scope reviews
    quiet and accurate:

      1. Static-pass findings whose `line` falls outside every diff hunk
         for their file are dropped at merge time. File-level findings
         (no line) are dropped too — they are almost always pre-existing
         structural issues (BOM, encoding) that don't belong on a PR
         review of unrelated changes.

      2. config.psd1's `RuleSeverityOverrides` hashtable lets a project
         downgrade (or upgrade) a specific static-pass rule by `rule_name`.
         Targets InjectionHunter false positives without disabling the
         rule class globally.

    Four scenarios:
      - In-hunk vs out-of-hunk vs file-level (no line) findings.
      - Override downgrades InjectionHunter blocker -> minor.
      - No diff-context.json present (e.g. -All bootstrap mode): filter
        is disabled and findings carry through.
      - Override value typo ('minro') is rejected with a Write-Warning;
        the finding keeps its default severity rather than getting a
        bogus severity that fails to count toward the verdict.

    Exits 0 on success, non-zero on any mismatch.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here       = Split-Path -Parent $PSCommandPath
$scriptsDir = Split-Path -Parent $here
$mergePath  = Join-Path $scriptsDir 'Merge-Findings.ps1'
if (-not (Test-Path $mergePath)) { Write-Error "$mergePath not found" }

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

function New-Skeleton {
    param(
        [object[]]$CompatFindings = @(),
        [object[]]$InjectionFindings = @(),
        [object[]]$Hunks = $null,
        [hashtable]$RuleSeverityOverrides = @{}
    )
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("mergefilt-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path "$temp/.pwsh-review/cache" -Force | Out-Null

    @{
        psscriptanalyzer      = @()
        compatibility         = $CompatFindings
        injection_hunter      = $InjectionFindings
        gitleaks              = @()
        eslint                = @()
        test_brittleness      = @()
        template_substitution = @()
        test_coverage         = @()
        pester                = @{ ran = $false }
        tools_missing         = @()
        tools_errors          = @()
    } | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $temp '.pwsh-review/cache/static-findings.json') -Encoding utf8NoBOM

    if ($null -ne $Hunks) {
        @{
            schema_version = '1'
            mode           = 'Branch'
            changed_files  = @($Hunks | ForEach-Object { $_.file } | Sort-Object -Unique)
            changed_hunks  = $Hunks
        } | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $temp '.pwsh-review/cache/diff-context.json') -Encoding utf8NoBOM
    }

    # config.psd1: emit a hashtable literal that includes the override.
    $cfgLines = @('@{', '    ConfidenceThreshold = 80', '    NitCap = 3')
    if ($RuleSeverityOverrides.Count -gt 0) {
        $cfgLines += '    RuleSeverityOverrides = @{'
        foreach ($k in $RuleSeverityOverrides.Keys) {
            $cfgLines += "        '$k' = '$($RuleSeverityOverrides[$k])'"
        }
        $cfgLines += '    }'
    }
    $cfgLines += '}'
    $cfgLines -join "`n" | Set-Content -LiteralPath (Join-Path $temp '.pwsh-review/config.psd1') -Encoding utf8NoBOM

    return $temp
}

# --- Scenario 1: hunk-scope filter -------------------------------------------
$root = New-Skeleton `
    -CompatFindings @(
        @{ rule_name='PSAvoidUsingWriteHost'; file='core/foo.ps1'; line=10;  severity='Warning'; message='write-host' }
        @{ rule_name='PSAvoidUsingWriteHost'; file='core/foo.ps1'; line=200; severity='Warning'; message='write-host (out of hunks)' }
        @{ rule_name='PSUseBOMForUnicodeEncodedFile'; file='core/foo.ps1'; line=$null; severity='Warning'; message='no BOM (file-level)' }
    ) `
    -Hunks @(
        @{ file='core/foo.ps1'; line_start=5; line_end=15 }
    )
try {
    $out = & $mergePath -RepoRoot $root
    Assert-True 'Scenario 1: 1 in-hunk finding survived' `
        ($out.StaticFindings -eq 1) `
        "got StaticFindings=$($out.StaticFindings)"
    Assert-True 'Scenario 1: 2 dropped by hunk filter (out-of-hunk + file-level)' `
        ($out.StaticDroppedByHunkFilter -eq 2) `
        "got dropped=$($out.StaticDroppedByHunkFilter)"
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Scenario 2: per-rule severity override ----------------------------------
# InjectionHunter is auto-classified as `blocker` by the merger. The override
# downgrades it to `minor`. The verdict drops from `needs rework` to a non-
# blocker outcome.
$root = New-Skeleton `
    -InjectionFindings @(
        @{ rule_name='InjectionRisk.UnsafeEscaping'; file='core/foo.ps1'; line=10; severity='Warning'; message='-replace chain' }
    ) `
    -Hunks @(
        @{ file='core/foo.ps1'; line_start=5; line_end=15 }
    ) `
    -RuleSeverityOverrides @{
        'InjectionRisk.UnsafeEscaping' = 'minor'
    }
try {
    $out = & $mergePath -RepoRoot $root
    Assert-True 'Scenario 2: 1 finding kept (in-hunk)' ($out.StaticFindings -eq 1)
    Assert-True 'Scenario 2: override downgraded blocker -> 0 blockers' `
        ($out.Counts['blocker'] -eq 0) "got $($out.Counts['blocker'])"
    Assert-True 'Scenario 2: override produced 1 minor (was blocker without override)' `
        ($out.Counts['minor'] -eq 1) "got $($out.Counts['minor'])"
    Assert-True 'Scenario 2: verdict is not "needs rework"' `
        ($out.Verdict -ne 'needs rework') "got $($out.Verdict)"
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Scenario 3: no diff-context (bootstrap / -All mode) ---------------------
# When diff-context.json is absent the filter is disabled. All findings carry.
$root = New-Skeleton `
    -CompatFindings @(
        @{ rule_name='PSAvoidUsingWriteHost'; file='core/foo.ps1'; line=10;  severity='Warning'; message='write-host' }
        @{ rule_name='PSAvoidUsingWriteHost'; file='core/foo.ps1'; line=200; severity='Warning'; message='write-host (would be out of any hunk)' }
    ) `
    -Hunks $null
try {
    $out = & $mergePath -RepoRoot $root
    Assert-True 'Scenario 3: filter disabled -> both findings carried through' `
        ($out.StaticFindings -eq 2) `
        "got StaticFindings=$($out.StaticFindings)"
    Assert-True 'Scenario 3: nothing dropped by hunk filter' `
        ($out.StaticDroppedByHunkFilter -eq 0)
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Scenario 4: invalid override value -----------------------------------
# A typo in RuleSeverityOverrides ('minro' instead of 'minor') must be
# rejected with a Write-Warning. The finding keeps its default severity
# (blocker for InjectionHunter) rather than getting an unrecognised value
# that the counts hashtable cannot increment, which would make the verdict
# silently wrong.
$root = New-Skeleton `
    -InjectionFindings @(
        @{ rule_name='InjectionRisk.UnsafeEscaping'; file='core/foo.ps1'; line=10; severity='Warning'; message='-replace chain' }
    ) `
    -Hunks @(
        @{ file='core/foo.ps1'; line_start=5; line_end=15 }
    ) `
    -RuleSeverityOverrides @{
        'InjectionRisk.UnsafeEscaping' = 'minro'   # deliberate typo
    }
try {
    # Capture warnings via 3>&1 so we can assert the user actually sees the
    # rejection rather than a silent miscount. Wrap with @() so a single
    # warning doesn't unwrap to a non-array under StrictMode 3.0.
    $warnings = @(& $mergePath -RepoRoot $root 3>&1 |
        Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
    $out = & $mergePath -RepoRoot $root  # second run, just for the counts object
    $matchedWarnings = @($warnings | Where-Object { $_.Message -match 'not a recognised severity' })
    Assert-True 'Scenario 4: invalid override emits Write-Warning' `
        ($matchedWarnings.Count -ge 1) `
        "got warnings=$($warnings.Count)"
    Assert-True 'Scenario 4: invalid override falls back to default severity (blocker)' `
        ($out.Counts['blocker'] -eq 1) `
        "got blocker=$($out.Counts['blocker'])"
    Assert-True 'Scenario 4: no finding sneaked into counts under the typoed severity' `
        (-not $out.Counts.ContainsKey('minro'))
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($failures.Count -gt 0) {
    Write-Output 'FAILURES:'
    foreach ($msg in $failures) { Write-Output "  $msg" }
    exit 1
}
Write-Output 'All Merge-Findings filter self-tests passed.'
exit 0
