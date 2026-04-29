#requires -Version 7.4
<#
.SYNOPSIS
    Self-test runner for Test-TemplateSubstitution.ps1 (and the
    Get-TemplateTokens discovery helper).

.DESCRIPTION
    Treats this directory as a synthetic repo. The companion source.ps1
    defines two -replace rules: KNOWN_NONEMPTY (always non-empty via
    if/else fallback) and KNOWN_MAYBE_EMPTY (RHS = bare parameter).

    Asserts:
      - positive-tpl001.md fires PWSH-TPL-001 (UNKNOWN_TOKEN, conf 90)
      - positive-tpl002-provable.md fires PWSH-TPL-002 at conf 80
      - positive-tpl002-uncertain.md fires PWSH-TPL-002 at conf 60
      - negative-known-token.md and negative-inverse-check.md emit nothing
      - Get-TemplateTokens.ps1 reports KNOWN_NONEMPTY as always_nonempty=true
        and KNOWN_MAYBE_EMPTY as always_nonempty=false
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here = Split-Path -Parent $PSCommandPath
$tplScript = Join-Path (Split-Path $here -Parent) 'Test-TemplateSubstitution.ps1'
$tokenScript = Join-Path (Split-Path $here -Parent) 'Get-TemplateTokens.ps1'
foreach ($p in @($tplScript, $tokenScript)) {
    if (-not (Test-Path $p)) { Write-Error "Required script not found: $p" }
}

$failures = @()

# --- Discovery sanity check ---

$tokens = & $tokenScript -RepoRoot $here
$tokenMap = @{}
foreach ($t in $tokens) { $tokenMap[$t.Name] = $t }

if (-not $tokenMap.ContainsKey('KNOWN_NONEMPTY')) {
    $failures += "FAIL: discovery missed KNOWN_NONEMPTY"
} elseif (-not $tokenMap['KNOWN_NONEMPTY'].AlwaysNonEmpty) {
    $failures += "FAIL: KNOWN_NONEMPTY should be always_nonempty=true"
} else {
    Write-Output "PASS: KNOWN_NONEMPTY discovered with always_nonempty=true"
}

if (-not $tokenMap.ContainsKey('KNOWN_MAYBE_EMPTY')) {
    $failures += "FAIL: discovery missed KNOWN_MAYBE_EMPTY"
} elseif ($tokenMap['KNOWN_MAYBE_EMPTY'].AlwaysNonEmpty) {
    $failures += "FAIL: KNOWN_MAYBE_EMPTY should be always_nonempty=false"
} else {
    Write-Output "PASS: KNOWN_MAYBE_EMPTY discovered with always_nonempty=false"
}

# --- Static check ---

$findings = & $tplScript -RepoRoot $here

$byFile = @{}
foreach ($f in $findings) {
    $base = [IO.Path]::GetFileName($f.file)
    if (-not $byFile.ContainsKey($base)) {
        $byFile[$base] = [System.Collections.Generic.List[object]]::new()
    }
    [void]$byFile[$base].Add($f)
}

function Assert-FixtureHit {
    param(
        [string]$File,
        [string]$Rule,
        [int]$ExpectedConfidence
    )
    $hits = @()
    if ($byFile.ContainsKey($File)) {
        $hits = @($byFile[$File] | Where-Object { $_.rule_name -eq $Rule })
    }
    if (@($hits).Count -eq 0) {
        $script:failures += "FAIL: $File expected at least one $Rule, got 0"
        return
    }
    $matchingConf = @($hits | Where-Object { $_.confidence -eq $ExpectedConfidence })
    if (@($matchingConf).Count -eq 0) {
        $script:failures += "FAIL: $File ${Rule} should fire at confidence $ExpectedConfidence; got [$(@($hits | ForEach-Object { $_.confidence }) -join ', ')]"
        return
    }
    Write-Output "PASS: $File -> $Rule at conf $ExpectedConfidence"
}

function Assert-FixtureClean {
    param([string]$File)
    $hits = @()
    if ($byFile.ContainsKey($File)) {
        $hits = @($byFile[$File])
    }
    if (@($hits).Count -gt 0) {
        $rules = @($hits | ForEach-Object { $_.rule_name }) -join ', '
        $script:failures += "FAIL: $File expected zero findings, got $(@($hits).Count): $rules"
        return
    }
    Write-Output "PASS: $File -> 0 findings"
}

Assert-FixtureHit -File 'positive-tpl001.md' -Rule 'PWSH-TPL-001' -ExpectedConfidence 90
Assert-FixtureHit -File 'positive-tpl002-provable.md' -Rule 'PWSH-TPL-002' -ExpectedConfidence 80
Assert-FixtureHit -File 'positive-tpl002-uncertain.md' -Rule 'PWSH-TPL-002' -ExpectedConfidence 60
Assert-FixtureClean -File 'negative-known-token.md'
Assert-FixtureClean -File 'negative-inverse-check.md'

Write-Output ''
Write-Output "Total findings: $($findings.Count)"

if ($failures.Count -gt 0) {
    Write-Output ''
    Write-Output 'FAILURES:'
    foreach ($msg in $failures) { Write-Output "  $msg" }
    exit 1
}

Write-Output ''
Write-Output 'All fixtures passed.'
exit 0
