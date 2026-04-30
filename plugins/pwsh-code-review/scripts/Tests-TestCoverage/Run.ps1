#requires -Version 7.4
<#
.SYNOPSIS
    Self-test runner for Test-Coverage.ps1.

.DESCRIPTION
    Each scenario synthesises a `-ChangedFiles` array (paths only — no
    actual file content needed; the rule reasons about path patterns) and
    asserts the expected number of PWSH-COV-001 findings.

    Exits 0 on success, non-zero on any mismatch.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here       = Split-Path -Parent $PSCommandPath
$scriptPath = Join-Path (Split-Path $here -Parent) 'Test-Coverage.ps1'
if (-not (Test-Path $scriptPath)) {
    Write-Error "Test-Coverage.ps1 not found at $scriptPath"
}

# Synthetic repo root — never written to. Test-Coverage doesn't read file
# content; it reasons about path patterns in -ChangedFiles.
$repoRoot = '/tmp/synthetic-repo'

function Invoke-Scenario {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string[]]$ChangedFiles
    )
    return @(& $scriptPath -RepoRoot $repoRoot -ChangedFiles $ChangedFiles)
}

$failures = @()

function Assert-Hit {
    param(
        [string]$Name,
        [int]$Expected,
        [object[]]$Findings,
        [string]$ExpectedFileSubstring
    )
    $count = @($Findings).Count
    if ($count -ne $Expected) {
        $script:failures += "FAIL: $Name expected $Expected finding(s), got $count"
        return
    }
    if ($Expected -gt 0 -and $ExpectedFileSubstring) {
        $hitFile = $Findings[0].file
        if ($hitFile -notmatch [regex]::Escape($ExpectedFileSubstring)) {
            $script:failures += "FAIL: $Name expected finding on '*$ExpectedFileSubstring*', got '$hitFile'"
            return
        }
    }
    Write-Output "PASS: $Name -> $count finding(s)"
}

# 1. Functional file changed, no test file in diff.
Assert-Hit -Name 'Functional change without any test' -Expected 1 `
    -ExpectedFileSubstring 'core/runtime/launch-process.ps1' `
    -Findings (Invoke-Scenario -ChangedFiles @(
        'core/runtime/launch-process.ps1'
    ))

# 2. Functional file changed AND name-matched test file in diff.
Assert-Hit -Name 'Functional change with name-matched test' -Expected 0 `
    -Findings (Invoke-Scenario -ChangedFiles @(
        'src/Modules/Foo/Public/Get-Foo.ps1',
        'src/Modules/Foo/Public/Get-Foo.Tests.ps1'
    ))

# 3. Functional file changed AND a tests/ name-matched test in diff.
Assert-Hit -Name 'Functional change with tests/ name-matched test' -Expected 0 `
    -Findings (Invoke-Scenario -ChangedFiles @(
        'src/Foo.psm1',
        'tests/Foo.Tests.ps1'
    ))

# 4. Functional file changed AND ANY test file in diff (loose fallback).
Assert-Hit -Name 'Loose fallback: any test file in diff covers' -Expected 0 `
    -Findings (Invoke-Scenario -ChangedFiles @(
        'core/runtime/launch-process.ps1',
        'tests/Test-Components.ps1'
    ))

# 5. Multiple functional files, no tests in diff — one finding per file.
Assert-Hit -Name 'Two functional files, no tests' -Expected 2 `
    -Findings (Invoke-Scenario -ChangedFiles @(
        'src/A.ps1',
        'src/B.ps1'
    ))

# 6. Exempt: docs only.
Assert-Hit -Name 'Documentation-only diff is exempt' -Expected 0 `
    -Findings (Invoke-Scenario -ChangedFiles @(
        'README.md',
        'docs/principles.md'
    ))

# 7. Exempt: configs only.
Assert-Hit -Name 'Config-only diff is exempt' -Expected 0 `
    -Findings (Invoke-Scenario -ChangedFiles @(
        'package.json',
        '.gitignore',
        'config.psd1'
    ))

# 8. Exempt: skills folder.
Assert-Hit -Name 'Skills folder is exempt' -Expected 0 `
    -Findings (Invoke-Scenario -ChangedFiles @(
        'plugins/foo/skills/my-skill/SKILL.md'
    ))

# 9. Exempt: agent prompts.
Assert-Hit -Name 'Agents folder is exempt' -Expected 0 `
    -Findings (Invoke-Scenario -ChangedFiles @(
        'plugins/foo/agents/security-agent.md'
    ))

# 10. Empty changed-files list returns nothing.
Assert-Hit -Name 'Empty changed-files list' -Expected 0 `
    -Findings (Invoke-Scenario -ChangedFiles @())

Write-Output ''
if ($failures.Count -gt 0) {
    Write-Output 'FAILURES:'
    foreach ($msg in $failures) { Write-Output "  $msg" }
    exit 1
}
Write-Output 'All Test-Coverage self-tests passed.'
exit 0
