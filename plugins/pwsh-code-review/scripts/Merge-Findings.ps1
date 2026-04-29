#requires -Version 7.4
<#
.SYNOPSIS
    Merges static-analysis findings and calibrated agent findings into a single review.

.DESCRIPTION
    Applies the severity x confidence filter matrix from docs/severity-rubric.md,
    clusters similar findings, caps nits, sorts, and renders the final Markdown
    review.

.PARAMETER RepoRoot
    Repository root.

.PARAMETER AgentFindingsPath
    Path to JSON file containing calibrated findings from the agents.
    Schema: array of finding objects per docs/severity-rubric.md.

.PARAMETER OutputPath
    Where to write the rendered Markdown. Defaults to .pwsh-review/cache/review.md.

.PARAMETER ConfidenceThreshold
    Override the default threshold (80).

.PARAMETER NitCap
    Override the default nit cap (3).

.EXAMPLE
    Merge-Findings.ps1 -AgentFindingsPath .pwsh-review/cache/agent-findings.json
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$AgentFindingsPath,
    [string]$OutputPath,
    [int]$ConfidenceThreshold = 0,
    [int]$NitCap = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

Push-Location $RepoRoot
try {
    $cacheDir = Join-Path $RepoRoot '.pwsh-review/cache'
    if (-not $OutputPath) {
        $OutputPath = Join-Path $cacheDir 'review.md'
    }

    # Load config
    $configPath = Join-Path $RepoRoot '.pwsh-review/config.psd1'
    $config = if (Test-Path $configPath) {
        Import-PowerShellDataFile $configPath
    } else {
        @{ ConfidenceThreshold = 80; NitCap = 3 }
    }
    if ($ConfidenceThreshold -eq 0) { $ConfidenceThreshold = $config.ConfidenceThreshold ?? 80 }
    if ($NitCap -eq 0) { $NitCap = $config.NitCap ?? 3 }

    # Load static findings
    $staticPath = Join-Path $cacheDir 'static-findings.json'
    $static = if (Test-Path $staticPath) {
        Get-Content $staticPath -Raw | ConvertFrom-Json -AsHashtable
    } else {
        @{ psscriptanalyzer = @(); compatibility = @(); injection_hunter = @(); gitleaks = @(); pester = $null; markdownlint = @(); test_brittleness = @(); template_substitution = @(); tools_missing = @() }
    }

    # Load calibrated agent findings
    $agentFindings = @()
    if ($AgentFindingsPath -and (Test-Path $AgentFindingsPath)) {
        $raw = Get-Content $AgentFindingsPath -Raw | ConvertFrom-Json -AsHashtable
        if ($raw -is [array]) { $agentFindings = $raw }
        elseif ($raw.findings) { $agentFindings = $raw.findings }
    }

    # ---- Map static findings to our schema ----

    $staticToOur = @{
        Error       = 'blocker'
        ParseError  = 'blocker'
        Warning     = 'major'
        Information = 'minor'
    }

    $staticAsFindings = @()

    # PSScriptAnalyzer & Compatibility & InjectionHunter & heuristic sources
    $heuristicSources = @('test_brittleness', 'template_substitution')
    foreach ($cat in @('psscriptanalyzer', 'compatibility', 'injection_hunter') + $heuristicSources) {
        foreach ($f in @($static[$cat])) {
            if (-not $f) { continue }
            $sev = $staticToOur[$f.severity] ?? 'minor'
            if ($cat -eq 'injection_hunter') { $sev = 'blocker' }
            # Heuristic sources carry a per-finding `confidence` field;
            # deterministic sources are 100 by default.
            $conf = if (($cat -in $heuristicSources) -and $f.confidence) { [int]$f.confidence } else { 100 }
            $staticAsFindings += [ordered]@{
                source     = $cat
                agent      = 'static'
                severity   = $sev
                confidence = $conf
                rule       = $f.rule_name
                file       = $f.file
                line_start = $f.line
                line_end   = $f.line
                message    = $f.message
                static     = $true
            }
        }
    }

    # Gitleaks - always blocker
    foreach ($g in @($static.gitleaks)) {
        if (-not $g) { continue }
        $staticAsFindings += [ordered]@{
            source     = 'gitleaks'
            agent      = 'static'
            severity   = 'blocker'
            confidence = 100
            rule       = ($g.RuleID ?? $g.rule_id ?? 'gitleaks')
            file       = ($g.File ?? $g.file)
            line_start = ($g.StartLine ?? $g.line ?? 0)
            line_end   = ($g.EndLine ?? $g.line ?? 0)
            message    = "Potential secret detected: $($g.Description ?? $g.description ?? $g.RuleID ?? 'see gitleaks output')"
            static     = $true
        }
    }

    # ---- Apply filter matrix to agent findings ----

    function Test-Pass {
        param($severity, $confidence)
        if ($confidence -lt 60) { return $false }
        switch ($severity) {
            'blocker'  { return $true }
            'major'    { return $confidence -ge 60 }
            'minor'    { return $confidence -ge 80 }
            'nit'      { return $confidence -ge 80 }
            'question' { return $confidence -ge 60 }
            'praise'   { return $confidence -ge 80 }
            default    { return $false }
        }
    }

    $passedAgent = @($agentFindings | Where-Object { Test-Pass $_.severity $_.confidence })

    # Heuristic static findings (test_brittleness, template_substitution) carry
    # per-rule confidence and must flow through the same filter matrix as agent
    # findings.
    $passedStaticHeuristic = @($staticAsFindings | Where-Object {
        ($_.source -in $heuristicSources) -and (Test-Pass $_.severity $_.confidence)
    })
    $deterministicStatic = @($staticAsFindings | Where-Object { $_.source -notin $heuristicSources })
    $staticAsFindings = $deterministicStatic + $passedStaticHeuristic

    # ---- Cap nits and praises ----

    $nits = @($passedAgent | Where-Object { $_.severity -eq 'nit' } | Sort-Object { -$_.confidence })
    $praises = @($passedAgent | Where-Object { $_.severity -eq 'praise' } | Sort-Object { -$_.confidence })
    $rest = @($passedAgent | Where-Object { $_.severity -ne 'nit' -and $_.severity -ne 'praise' })

    $cappedNits = @($nits | Select-Object -First $NitCap)
    $cappedPraises = @($praises | Select-Object -First 1)

    $afterCaps = @($rest) + @($cappedNits) + @($cappedPraises)

    # ---- Cluster: group identical (rule, file) pairs across contiguous lines ----

    $clusters = @{}
    foreach ($f in $afterCaps) {
        $key = "$($f.rule)|$($f.file)"
        if (-not $clusters.Contains($key)) { $clusters[$key] = @() }
        $clusters[$key] += $f
    }

    $clustered = @()
    foreach ($k in $clusters.Keys) {
        $items = @($clusters[$k] | Sort-Object line_start)
        if ($items.Count -le 1) { $clustered += $items; continue }

        # If all same severity and within 20 lines, fold into one with a "(+ N more)" message
        $sev = $items[0].severity
        $allSame = ($items | Where-Object { $_.severity -ne $sev }).Count -eq 0
        if (-not $allSame) { $clustered += $items; continue }

        $top = $items[0]
        $extra = $items.Count - 1
        $top.message = "$($top.message) (+ $extra similar in same file)"
        $clustered += $top
    }

    # ---- Combine static + clustered agent findings ----

    $all = @($staticAsFindings) + @($clustered)

    # ---- Sort: severity, file, line ----

    $sevOrder = @{ blocker = 0; major = 1; minor = 2; nit = 3; question = 4; praise = 5 }
    $sorted = $all | Sort-Object @{ Expression = { $sevOrder[$_.severity] } }, file, line_start

    # ---- Render Markdown ----

    $sb = [System.Text.StringBuilder]::new()

    $counts = @{ blocker = 0; major = 0; minor = 0; nit = 0; question = 0; praise = 0 }
    foreach ($f in $sorted) {
        if ($counts.ContainsKey($f.severity)) { $counts[$f.severity]++ }
    }

    $diffMode = 'staged/working'
    $diffContextPath = Join-Path $cacheDir 'diff-context.json'
    if (Test-Path $diffContextPath) {
        $dc = Get-Content $diffContextPath -Raw | ConvertFrom-Json
        if ($dc.mode) { $diffMode = $dc.mode }
    }

    [void]$sb.AppendLine("## Code review ($diffMode)")
    [void]$sb.AppendLine()

    $summary = @(
        "$($counts.blocker) blocker"
        "$($counts.major) major"
        "$($counts.minor) minor"
        "$($counts.nit) nit"
        "$($counts.question) question"
    ) -join ', '
    [void]$sb.AppendLine($summary)
    [void]$sb.AppendLine()

    # Static analysis summary
    [void]$sb.AppendLine("### Static analysis")
    [void]$sb.AppendLine()
    $pssaCount = @($static.psscriptanalyzer).Count + @($static.compatibility).Count
    [void]$sb.AppendLine("- PSScriptAnalyzer: $pssaCount finding(s)")
    [void]$sb.AppendLine("- InjectionHunter: $(@($static.injection_hunter).Count) finding(s)")
    [void]$sb.AppendLine("- Gitleaks: $(@($static.gitleaks).Count) finding(s)")
    if ($static.ContainsKey('test_brittleness')) {
        $tbRaw  = @($static.test_brittleness).Count
        $tbKept = @($passedStaticHeuristic | Where-Object { $_.source -eq 'test_brittleness' }).Count
        if ($tbRaw -eq $tbKept) {
            [void]$sb.AppendLine("- Test brittleness: $tbRaw finding(s)")
        } else {
            [void]$sb.AppendLine("- Test brittleness: $tbRaw raw, $tbKept post-filter")
        }
    }
    if ($static.ContainsKey('template_substitution')) {
        $tplRaw  = @($static.template_substitution).Count
        $tplKept = @($passedStaticHeuristic | Where-Object { $_.source -eq 'template_substitution' }).Count
        if ($tplRaw -eq $tplKept) {
            [void]$sb.AppendLine("- Template substitution: $tplRaw finding(s)")
        } else {
            [void]$sb.AppendLine("- Template substitution: $tplRaw raw, $tplKept post-filter")
        }
    }
    if ($static.pester -and $static.pester.ran) {
        [void]$sb.AppendLine("- Pester: $($static.pester.passed)/$($static.pester.total) passed, $($static.pester.failed) failed")
    } else {
        [void]$sb.AppendLine("- Pester: not run")
    }
    if ($static.tools_missing -and @($static.tools_missing).Count -gt 0) {
        [void]$sb.AppendLine("- Tools missing on PATH: $((@($static.tools_missing)) -join ', ')")
    }
    [void]$sb.AppendLine()

    # Findings by severity
    foreach ($sev in @('blocker', 'major', 'minor', 'nit', 'question', 'praise')) {
        $section = @($sorted | Where-Object { $_.severity -eq $sev })
        if (-not $section -or $section.Count -eq 0) { continue }

        [void]$sb.AppendLine("### $sev ($($section.Count))")
        [void]$sb.AppendLine()

        foreach ($f in $section) {
            # Optional keys via indexer to avoid strict-mode throws when the
            # finding (e.g. a static one) does not carry agent-only fields.
            $consequence = $f['consequence']
            $fix         = $f['fix']
            $fixSnippet  = $f['fix_snippet']
            $isStatic    = [bool]$f['static']
            $rule        = if ($f['rule']) { " [$($f['rule'])]" } else { '' }

            $line = if ($f.line_start -eq $f.line_end -or -not $f.line_end) { "$($f.line_start)" }
                    else { "$($f.line_start)-$($f.line_end)" }
            $confDisplay = if ($isStatic) { 'static' } else { "$($f.confidence)" }

            [void]$sb.AppendLine("**[$sev] ($confDisplay) ``$($f.file):$line``**$rule")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine($f.message)
            [void]$sb.AppendLine()

            if ($consequence) {
                [void]$sb.AppendLine($consequence)
                [void]$sb.AppendLine()
            }

            if ($fix) {
                [void]$sb.AppendLine("Fix: $fix")
                [void]$sb.AppendLine()
            }

            if ($fixSnippet) {
                [void]$sb.AppendLine('```powershell')
                [void]$sb.AppendLine($fixSnippet)
                [void]$sb.AppendLine('```')
                [void]$sb.AppendLine()
            }
        }
    }

    if (-not $sorted -or $sorted.Count -eq 0) {
        [void]$sb.AppendLine("No findings.")
        [void]$sb.AppendLine()
    }

    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("_Reviewed by pwsh-code-review. Use ``# pwsh-review:disable-next-line <rule>`` to suppress._")

    $markdown = $sb.ToString()
    $markdown | Set-Content $OutputPath -Encoding utf8NoBOM

    [pscustomobject]@{
        OutputPath           = $OutputPath
        TotalFindings        = @($sorted).Count
        Counts               = $counts
        StaticFindings       = @($staticAsFindings).Count
        AgentFindingsRaw     = @($agentFindings).Count
        AgentFindingsKept    = @($clustered).Count
        ConfidenceThreshold  = $ConfidenceThreshold
        NitCap               = $NitCap
    }
} finally {
    Pop-Location
}
