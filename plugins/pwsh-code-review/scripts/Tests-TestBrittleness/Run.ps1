#requires -Version 7.4
<#
.SYNOPSIS
    Self-test runner for Test-Brittleness.ps1.

.DESCRIPTION
    Invokes Test-Brittleness.ps1 against this directory and asserts:
      - At least one finding per positive fixture, with the right rule_name.
      - Zero findings on the two negative fixtures.

    Exits 0 on success, non-zero on any mismatch. Writes a summary to stdout.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here = Split-Path -Parent $PSCommandPath
$scriptPath = Join-Path (Split-Path $here -Parent) 'Test-Brittleness.ps1'
if (-not (Test-Path $scriptPath)) {
    Write-Error "Test-Brittleness.ps1 not found at $scriptPath"
}

# Run against this directory, treating it as the repo root so output paths are predictable.
$findings = & $scriptPath -RepoRoot $here -Path $here

# Index findings by file basename for assertion ergonomics.
# Use a List<object> per key — `@() + $hashtable` enumerates the hashtable's
# entries instead of treating it as one item.
$byFile = @{}
foreach ($f in $findings) {
    $base = [IO.Path]::GetFileName($f.file)
    if (-not $byFile.ContainsKey($base)) {
        $byFile[$base] = [System.Collections.Generic.List[object]]::new()
    }
    [void]$byFile[$base].Add($f)
}

$expected = [ordered]@{
    'R1-Count.Tests.ps1'         = 'PWSH-TEST-001'
    'R2-MultilineRegex.Tests.ps1' = 'PWSH-TEST-002'
    'R3-SortUnique.Tests.ps1'    = 'PWSH-TEST-003'
    'R4-HashKeys.Tests.ps1'      = 'PWSH-TEST-004'
    'R5-WindowsPath.Tests.ps1'   = 'PWSH-TEST-005'
}

$negatives = @(
    'Negative-Harness.ps1'
    'Negative-AssertionContext.Tests.ps1'
)

$failures = @()

foreach ($pair in $expected.GetEnumerator()) {
    $file = $pair.Key
    $rule = $pair.Value
    $hits = if ($byFile.ContainsKey($file)) { @($byFile[$file] | Where-Object { $_.rule_name -eq $rule }) } else { @() }
    if ($hits.Count -lt 1) {
        $failures += "FAIL: expected at least one $rule in $file, got 0"
    }
    else {
        Write-Output ("PASS: {0} -> {1} ({2} hit(s))" -f $file, $rule, $hits.Count)
    }
}

foreach ($neg in $negatives) {
    $hits = @()
    if ($byFile.ContainsKey($neg)) { $hits = @($byFile[$neg]) }
    $hitCount = @($hits).Count
    if ($hitCount -gt 0) {
        $rules = @($hits | ForEach-Object { $_.rule_name }) -join ', '
        $failures += "FAIL: expected zero findings in $neg, got ${hitCount}: $rules"
    }
    else {
        Write-Output "PASS: $neg -> 0 findings"
    }
}

# Cross-rule-leak: a finding's rule must match the fixture it was found in
# (each fixture is scoped to one rule).
foreach ($f in $findings) {
    $base = [IO.Path]::GetFileName($f.file)
    if ($expected.Contains($base)) {
        $expectedRule = $expected[$base]
        if ($f.rule_name -ne $expectedRule) {
            $failures += "FAIL: $base produced unexpected rule $($f.rule_name) at line $($f.line) (expected only $expectedRule)"
        }
    }
}

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
