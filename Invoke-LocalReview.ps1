#requires -Version 7.4
<#
.SYNOPSIS
    Runs the static-only pwsh-review pipeline against this repo.

.DESCRIPTION
    Convenience entry point for dogfooding the plugin against itself.
    Runs in three steps:

      1. Invoke-StaticAnalysis.ps1 -All   (PSScriptAnalyzer + Pester +
         optional external linters; writes static-findings.json)
      2. Merge-Findings.ps1               (computes verdict from static
         findings only; agents are not dispatched in this entry point)
      3. Reads the verdict and exits accordingly:
           - 'ship'             -> exit 0 (success)
           - 'fix majors first' -> exit 0 with a warning (push allowed)
           - 'needs rework'     -> exit 1 (push refused by the hook)

    Used by .githooks/pre-push and the CI workflow. Operators can also
    invoke it directly: `pwsh ./Invoke-LocalReview.ps1`.

    Agent dispatch lives in the slash command (/pwsh-review) and is not
    available from this entry point. Use it from Claude Code when you
    want a deeper review.

.PARAMETER RepoRoot
    Repository root. Defaults to the directory of this script.
.OUTPUTS
    None. The verdict is written to stdout and the exit code reflects it.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

if (-not $RepoRoot) {
    $RepoRoot = (Get-Location).Path
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$pluginScripts = Join-Path $RepoRoot 'plugins/pwsh-code-review/scripts'
$staticScript  = Join-Path $pluginScripts 'Invoke-StaticAnalysis.ps1'
$mergeScript   = Join-Path $pluginScripts 'Merge-Findings.ps1'

if (-not (Test-Path -LiteralPath $staticScript)) {
    Write-Error "Plugin scripts not found at $pluginScripts. Are you running this from the marketplace repo root?"
}

Write-Information '[pwsh-review] running static analysis...' -InformationAction Continue
& $staticScript -RepoRoot $RepoRoot -All | Out-Host

Write-Information '[pwsh-review] merging findings...' -InformationAction Continue
& $mergeScript -RepoRoot $RepoRoot | Out-Host

$mergedPath = Join-Path $RepoRoot '.pwsh-review/cache/merged-findings.json'
if (-not (Test-Path -LiteralPath $mergedPath)) {
    Write-Error "merged-findings.json not produced at $mergedPath. The merger may have failed."
}

$merged = Get-Content -LiteralPath $mergedPath -Raw | ConvertFrom-Json
$verdict = [string]$merged.verdict
if (-not $verdict) { $verdict = 'unknown' }

Write-Output ''
Write-Output "[pwsh-review] verdict: $verdict"

switch ($verdict) {
    'ship' {
        Write-Output '[pwsh-review] OK -- no blockers, no majors. Push allowed.'
        exit 0
    }
    'fix majors first' {
        Write-Warning "[pwsh-review] majors present. Push allowed but address them in this PR."
        exit 0
    }
    'needs rework' {
        Write-Output '[pwsh-review] BLOCKER findings present. Refusing push.'
        Write-Output "Inspect $mergedPath or .pwsh-review/cache/review.md for details."
        exit 1
    }
    default {
        Write-Warning "[pwsh-review] unknown verdict '$verdict'. Push allowed; investigate."
        exit 0
    }
}
