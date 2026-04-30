#requires -Version 7.4
<#
.SYNOPSIS
    Self-test runner for the JS content agent and the optional ESLint
    static runner.

.DESCRIPTION
    The agent itself is an LLM (no deterministic invocation), so this test
    has three layers:

      1. Mechanical fixture-shape checks (always run). For each rule, the
         positive fixture (`R0NN-Name.bad.js`) must contain the syntactic
         marker that makes the rule applicable, and the negative fixture
         (`R0NN-Name.good.js`) must contain a clear mitigation. Catches
         the case where someone edits a fixture into something that no
         longer demonstrates the rule.

      2. ESLint integration (run when `eslint` is on PATH or `npx` can
         reach a project-local install). Uses the local `eslint.config.js`
         to verify the eslint output is parseable JSON, that R004.bad.js
         trips `eqeqeq`, and that every `.good.js` is eslint-clean.

      3. Invoke-StaticAnalysis integration (run when eslint is reachable).
         Spins up a synthetic temp repo, runs Invoke-StaticAnalysis.ps1,
         and asserts the eslint findings flow into static-findings.json.

    Exits 0 on success, non-zero on any mismatch.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here       = Split-Path -Parent $PSCommandPath
$scriptsDir = Split-Path -Parent $here

function Remove-JsComments {
    # Strip line comments (`// ...`) and block comments (`/* ... */`) so the
    # regex match doesn't trip on rule-describing comments inside fixtures.
    # Naive (does not handle comments inside strings), which is fine for
    # fixtures we write and control.
    param([string]$Text)
    $stripped = $Text -replace '/\*[\s\S]*?\*/', ''
    $stripped = $stripped -replace '(?m)//[^\n]*', ''
    return $stripped
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

# --- Layer 1: mechanical fixture-shape checks --------------------------------
#
# Each entry says: in the .bad.js, these patterns MUST appear (and these
# MUST NOT). In the .good.js, these patterns MUST appear (the mitigation)
# and these MUST NOT (the bad pattern). Patterns are PowerShell regexes.
#
# Goal: catch fixture rot. If someone edits R008-DomInjection.bad.js to
# add escapeHtml(), the test fails — the fixture no longer demonstrates
# the rule.

$rules = @(
    @{
        Id = 'PWSH-JS-001'
        Name = 'GlobalPollution'
        Stem = 'R001-GlobalPollution'
        BadMustMatch = @('window\.\w+\s*=')
        BadMustNotMatch = @()
        GoodMustMatch = @('export\b')
        GoodMustNotMatch = @('window\.\w+\s*=')
    }
    @{
        Id = 'PWSH-JS-002'
        Name = 'ListenerLeak'
        Stem = 'R002-ListenerLeak'
        BadMustMatch = @('addEventListener')
        BadMustNotMatch = @('removeEventListener', 'AbortController', '\{\s*once\s*:')
        GoodMustMatch = @('AbortController|removeEventListener|\{\s*once\s*:')
        GoodMustNotMatch = @()
    }
    @{
        Id = 'PWSH-JS-003'
        Name = 'TimerLeak'
        Stem = 'R003-TimerLeak'
        BadMustMatch = @('setInterval\(')
        BadMustNotMatch = @('clearInterval')
        GoodMustMatch = @('clearInterval')
        GoodMustNotMatch = @()
    }
    @{
        Id = 'PWSH-JS-004'
        Name = 'TypeCoercion'
        Stem = 'R004-TypeCoercion'
        BadMustMatch = @('(?<![\!=])==\s*null|!\s*\w')
        BadMustNotMatch = @()
        GoodMustMatch = @('===|!==')
        GoodMustNotMatch = @('(?<![\!=])==\s*null')
    }
    @{
        Id = 'PWSH-JS-005'
        Name = 'FetchNoErrorPath'
        Stem = 'R005-FetchNoErrorPath'
        BadMustMatch = @('fetch\(')
        BadMustNotMatch = @('try', 'catch', '\.ok')
        GoodMustMatch = @('try', 'catch', '\.ok')
        GoodMustNotMatch = @()
    }
    @{
        Id = 'PWSH-JS-006'
        Name = 'JsonParseUnsafe'
        Stem = 'R006-JsonParseUnsafe'
        BadMustMatch = @('JSON\.parse\(')
        BadMustNotMatch = @('try', 'catch')
        GoodMustMatch = @('try', 'catch')
        GoodMustNotMatch = @()
    }
    @{
        Id = 'PWSH-JS-007'
        Name = 'SanitizeOrder'
        Stem = 'R007-SanitizeOrder'
        BadMustMatch = @('if\s*\(\s*raw\b', 'sanitize\(')
        BadMustNotMatch = @()
        GoodMustMatch = @('sanitize\(', 'if\s*\(\s*safe\b')
        GoodMustNotMatch = @()
    }
    @{
        Id = 'PWSH-JS-008'
        Name = 'DomInjection'
        Stem = 'R008-DomInjection'
        BadMustMatch = @('innerHTML\s*=')
        BadMustNotMatch = @('escapeHtml\(')
        GoodMustMatch = @('escapeHtml\(', 'innerHTML\s*=')
        GoodMustNotMatch = @()
    }
    @{
        Id = 'PWSH-JS-009'
        Name = 'PrototypePollution'
        Stem = 'R009-PrototypePollution'
        BadMustMatch = @('Object\.assign\(\s*target\s*,\s*incoming')
        BadMustNotMatch = @('ALLOWED_KEYS|allowList|hasOwnProperty')
        GoodMustMatch = @('ALLOWED_KEYS|hasOwnProperty')
        GoodMustNotMatch = @('Object\.assign\(\s*target\s*,\s*incoming')
    }
    @{
        Id = 'PWSH-JS-010'
        Name = 'OpenRedirect'
        Stem = 'R010-OpenRedirect'
        BadMustMatch = @('window\.location\.href\s*=')
        BadMustNotMatch = @('ALLOWED_HOSTS|allowedHosts|new URL\(')
        GoodMustMatch = @('ALLOWED_HOSTS|allowedHosts|new URL\(')
        GoodMustNotMatch = @()
    }
)

foreach ($rule in $rules) {
    $badPath  = Join-Path $here ("{0}.bad.js"  -f $rule.Stem)
    $goodPath = Join-Path $here ("{0}.good.js" -f $rule.Stem)
    Assert-True ("$($rule.Id): bad fixture exists")  (Test-Path $badPath)
    Assert-True ("$($rule.Id): good fixture exists") (Test-Path $goodPath)
    if (-not (Test-Path $badPath) -or -not (Test-Path $goodPath)) { continue }

    $badContent  = Remove-JsComments (Get-Content -Raw -LiteralPath $badPath)
    $goodContent = Remove-JsComments (Get-Content -Raw -LiteralPath $goodPath)

    foreach ($pat in $rule.BadMustMatch) {
        Assert-True ("$($rule.Id): bad fixture matches /$pat/") ($badContent -match $pat) `
            "expected match in $($rule.Stem).bad.js"
    }
    foreach ($pat in $rule.BadMustNotMatch) {
        Assert-True ("$($rule.Id): bad fixture does not match /$pat/") (-not ($badContent -match $pat)) `
            "expected NO match in $($rule.Stem).bad.js"
    }
    foreach ($pat in $rule.GoodMustMatch) {
        Assert-True ("$($rule.Id): good fixture matches /$pat/") ($goodContent -match $pat) `
            "expected match in $($rule.Stem).good.js"
    }
    foreach ($pat in $rule.GoodMustNotMatch) {
        Assert-True ("$($rule.Id): good fixture does not match /$pat/") (-not ($goodContent -match $pat)) `
            "expected NO match in $($rule.Stem).good.js"
    }
}

# --- Layer 2: live eslint integration (when reachable) -----------------------

$eslintCmd = $null
if (Get-Command eslint -ErrorAction SilentlyContinue) { $eslintCmd = 'eslint' }
elseif (Get-Command npx -ErrorAction SilentlyContinue) { $eslintCmd = 'npx' }

if ($eslintCmd) {
    Push-Location $here
    try {
        $eslintArgs = if ($eslintCmd -eq 'npx') {
            @('eslint', '--format', 'json', '--config', 'eslint.config.js', '*.js')
        } else {
            @('--format', 'json', '--config', 'eslint.config.js', '*.js')
        }
        $rawOutput = & $eslintCmd @eslintArgs 2>$null
        # eslint exits non-zero when it finds issues; we don't care, we just
        # want the JSON. Don't check $LASTEXITCODE.

        $reports = $null
        try {
            $reports = $rawOutput | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Assert-True 'ESLint output parsed as JSON' $false "ConvertFrom-Json failed: $($_.Exception.Message)"
            $reports = @()
        }
        if ($reports) {
            Assert-True 'ESLint output is parseable JSON' $true
        }

        # Collapse to a flat per-file lookup: file -> messages[]
        $byFile = @{}
        foreach ($r in @($reports)) {
            if (-not $r) { continue }
            $base = [IO.Path]::GetFileName($r.filePath)
            $byFile[$base] = @($r.messages)
        }

        # R004.bad.js must trip eqeqeq.
        $r4Bad = if ($byFile.ContainsKey('R004-TypeCoercion.bad.js')) { $byFile['R004-TypeCoercion.bad.js'] } else { @() }
        $eqeqeqHit = @($r4Bad | Where-Object { $_.ruleId -eq 'eqeqeq' }).Count -gt 0
        Assert-True 'ESLint: R004.bad.js trips eqeqeq' $eqeqeqHit

        # Every .good.js must be eslint-clean (no errors).
        $goodFixtures = Get-ChildItem -LiteralPath $here -Filter '*.good.js' | ForEach-Object { $_.Name }
        foreach ($g in $goodFixtures) {
            $msgs = if ($byFile.ContainsKey($g)) { $byFile[$g] } else { @() }
            $errs = @($msgs | Where-Object { [int]$_.severity -eq 2 })
            Assert-True ("ESLint: $g has zero errors") ($errs.Count -eq 0) `
                ("got $($errs.Count): " + (($errs | ForEach-Object { $_.ruleId }) -join ', '))
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Output 'SKIP: ESLint not on PATH and npx unavailable. Skipping Layer 2 (eslint integration).'
}

# --- Layer 3: Invoke-StaticAnalysis integration (when eslint reachable) ------

if ($eslintCmd) {
    $invokeScript = Join-Path $scriptsDir 'Invoke-StaticAnalysis.ps1'
    if (-not (Test-Path $invokeScript)) {
        Assert-True 'Layer 3: Invoke-StaticAnalysis.ps1 exists' $false
    } else {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("jscontent-l3-{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path "$tempRoot/.pwsh-review/cache" -Force | Out-Null
        New-Item -ItemType Directory -Path "$tempRoot/.pwsh-review/patterns" -Force | Out-Null

        try {
            # Minimal project profile so Invoke-StaticAnalysis doesn't error on missing settings.
            @'
@{
    Severity = @('Error', 'Warning', 'Information')
}
'@ | Set-Content -LiteralPath "$tempRoot/.pwsh-review/PSScriptAnalyzerSettings.psd1" -Encoding utf8NoBOM

            @'
@{
    ConfidenceThreshold = 80
    NitCap = 3
    Platforms = @('core-7.4-windows')
}
'@ | Set-Content -LiteralPath "$tempRoot/.pwsh-review/config.psd1" -Encoding utf8NoBOM

            # Drop the R004 bad fixture into the temp repo so eslint has
            # something to flag.
            Copy-Item -LiteralPath (Join-Path $here 'R004-TypeCoercion.bad.js') -Destination "$tempRoot/sample.js"
            Copy-Item -LiteralPath (Join-Path $here 'eslint.config.js')         -Destination "$tempRoot/eslint.config.js"

            # Synthesise a diff-context.json so the runner picks up the JS file
            # under the diff scope (the runner reads $dc.changed_files when
            # not -All).
            $dc = [ordered]@{
                schema_version = '1'
                changed_files  = @('sample.js')
                changed_hunks  = @()
            }
            $dc | ConvertTo-Json -Depth 10 |
                Set-Content -LiteralPath "$tempRoot/.pwsh-review/cache/diff-context.json" -Encoding utf8NoBOM

            # Run static analysis.
            $null = & $invokeScript -RepoRoot $tempRoot 2>&1

            $staticPath = "$tempRoot/.pwsh-review/cache/static-findings.json"
            Assert-True 'Layer 3: static-findings.json written' (Test-Path $staticPath)
            if (Test-Path $staticPath) {
                $static = Get-Content -Raw -LiteralPath $staticPath | ConvertFrom-Json -AsHashtable
                Assert-True 'Layer 3: aggregate has eslint key' $static.ContainsKey('eslint')
                $eslintHits = if ($static.ContainsKey('eslint')) { @($static.eslint) } else { @() }
                Assert-True 'Layer 3: eslint findings flowed through aggregate' ($eslintHits.Count -gt 0) `
                    "got $($eslintHits.Count) findings"
                if ($eslintHits.Count -gt 0) {
                    $hasEqeqeq = @($eslintHits | Where-Object { $_.rule_name -like '*eqeqeq*' }).Count -gt 0
                    Assert-True 'Layer 3: aggregate carries eqeqeq finding' $hasEqeqeq
                }
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    Write-Output 'SKIP: Layer 3 (Invoke-StaticAnalysis integration) requires eslint.'
}

Write-Output ''
if ($failures.Count -gt 0) {
    Write-Output 'FAILURES:'
    foreach ($msg in $failures) { Write-Output "  $msg" }
    exit 1
}
Write-Output 'All Tests-JsContent self-tests passed.'
exit 0
