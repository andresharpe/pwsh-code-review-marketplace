#requires -Version 7.4
<#
.SYNOPSIS
    Self-test runner for Merge-Findings.ps1's agent-findings input parsing.

.DESCRIPTION
    Regression coverage for the StrictMode 3.0 crash on a one-finding agent
    output. ConvertFrom-Json -AsHashtable unwraps a single-element JSON
    array into the element itself, so a one-finding `[{...}]` parses to a
    hashtable. The original `elseif ($raw.findings)` then accessed a
    missing key and threw under StrictMode, breaking every one-finding
    review. This test exercises three input shapes:

      1. Array wrapper:    [ {finding}, {finding} ]
      2. findings key:     { "findings": [ {finding} ] }
      3. Bare finding:     { ...finding fields... }

    All three should produce the same merged output. The test runs against
    a synthetic .pwsh-review/ skeleton so the merger can read its config.

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

function New-Scenario {
    <#
    Build a minimal repo skeleton (.pwsh-review/cache + an agent-findings.json
    written in $Shape). Returns the temp root path.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('array', 'findings-key', 'bare-object')]
        [string]$Shape
    )
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("mergefindings-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path "$temp/.pwsh-review/cache" -Force | Out-Null

    # Empty static findings shaped like Invoke-StaticAnalysis output. All keys
    # populated so the merger's StrictMode-3.0 reads against `$static.<key>`
    # find what they expect.
    @{
        psscriptanalyzer      = @()
        compatibility         = @()
        injection_hunter      = @()
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

    # Stable single finding for shape comparison.
    $finding = [ordered]@{
        agent      = 'pwsh-idioms'
        rule       = 'PWSH-LANG-DEMO'
        severity   = 'major'
        confidence = 85
        file       = 'core/foo.ps1'
        line_start = 10
        line_end   = 10
        message    = 'demo finding'
    }

    $payload = switch ($Shape) {
        'array'        { @($finding) }
        'findings-key' { [ordered]@{ findings = @($finding) } }
        'bare-object'  { $finding }
    }

    $payload | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $temp '.pwsh-review/cache/agent-findings.json') -Encoding utf8NoBOM

    return $temp
}

function Invoke-Merge {
    param([string]$Root)
    & $mergePath -RepoRoot $Root -AgentFindingsPath (Join-Path $Root '.pwsh-review/cache/agent-findings.json')
}

# --- Scenario 1: array wrapper (the canonical legacy shape) ----
$arrayRoot = New-Scenario -Shape 'array'
try {
    $out = Invoke-Merge -Root $arrayRoot
    Assert-True 'Array shape: parses and emits 1 agent finding' `
        ($out.AgentFindingsRaw -eq 1)
    Assert-True 'Array shape: 1 major in counts' `
        ($out.Counts['major'] -eq 1)
} finally {
    Remove-Item -LiteralPath $arrayRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Scenario 2: { "findings": [...] } wrapper ----
$findingsRoot = New-Scenario -Shape 'findings-key'
try {
    $out = Invoke-Merge -Root $findingsRoot
    Assert-True 'findings-key shape: parses and emits 1 agent finding' `
        ($out.AgentFindingsRaw -eq 1)
    Assert-True 'findings-key shape: 1 major in counts' `
        ($out.Counts['major'] -eq 1)
} finally {
    Remove-Item -LiteralPath $findingsRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Scenario 3: bare finding object (the StrictMode-3.0 crash case) ----
# Before the fix: `[{finding}]` was unwrapped by ConvertFrom-Json to a single
# hashtable, `-is [array]` was false, and `$raw.findings` then crashed under
# StrictMode 3.0. After the fix the bare-object branch picks it up.
$bareRoot = New-Scenario -Shape 'bare-object'
try {
    $out = Invoke-Merge -Root $bareRoot
    Assert-True 'Bare-object shape: parses and emits 1 agent finding' `
        ($out.AgentFindingsRaw -eq 1)
    Assert-True 'Bare-object shape: 1 major in counts' `
        ($out.Counts['major'] -eq 1)
} finally {
    Remove-Item -LiteralPath $bareRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($failures.Count -gt 0) {
    Write-Output 'FAILURES:'
    foreach ($msg in $failures) { Write-Output "  $msg" }
    exit 1
}
Write-Output 'All Merge-Findings input-shape self-tests passed.'
exit 0
