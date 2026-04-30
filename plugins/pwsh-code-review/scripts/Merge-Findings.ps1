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

# Plugin version (rendered into the review markdown header and footer
# so reviewers can tell which build of the plugin produced this output).
. (Join-Path $PSScriptRoot '_PluginVersion.ps1')
$pluginRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pluginVersion = Get-PluginVersion -PluginRoot $pluginRoot

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
        @{ psscriptanalyzer = @(); compatibility = @(); injection_hunter = @(); gitleaks = @(); pester = $null; markdownlint = @(); test_brittleness = @(); template_substitution = @(); test_coverage = @(); eslint = @(); tools_missing = @(); tools_errors = @() }
    }

    # Load calibrated agent findings.
    # ConvertFrom-Json unwraps a single-element JSON array into the element
    # itself. With `-AsHashtable`, a one-finding JSON file `[{...}]` parses
    # to a single hashtable rather than a one-element array, so `-is [array]`
    # is false and the original `elseif ($raw.findings)` then accessed
    # `.findings` on a hashtable that didn't have that key — which throws
    # under StrictMode 3.0 and broke the merger for any one-finding input.
    # Probe the shape explicitly: array | {findings: [...]} | bare finding.
    $agentFindings = @()
    if ($AgentFindingsPath -and (Test-Path $AgentFindingsPath)) {
        $raw = Get-Content $AgentFindingsPath -Raw | ConvertFrom-Json -AsHashtable
        if ($raw -is [array]) {
            $agentFindings = $raw
        } elseif ($raw -is [System.Collections.IDictionary] -and $raw.Contains('findings')) {
            $agentFindings = @($raw['findings'])
        } elseif ($raw -is [System.Collections.IDictionary] -and $raw.Contains('severity')) {
            # Bare finding object (no array wrapper, no findings key, but has
            # the schema's `severity` field). Treat as a one-element list so
            # the simplest agent output shape works.
            $agentFindings = @($raw)
        }
    }

    # ---- Map static findings to our schema ----

    $staticToOur = @{
        Error       = 'blocker'
        ParseError  = 'blocker'
        Warning     = 'major'
        Information = 'minor'
    }

    $staticAsFindings = @()

    # PSScriptAnalyzer & Compatibility & InjectionHunter & ESLint & heuristic sources.
    # ESLint reports are deterministic (linter output, confidence 100), so they
    # join the deterministic-static bucket alongside PSSA / compatibility.
    $heuristicSources = @('test_brittleness', 'template_substitution', 'test_coverage')
    foreach ($cat in @('psscriptanalyzer', 'compatibility', 'injection_hunter', 'eslint') + $heuristicSources) {
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
    [void]$sb.AppendLine("_pwsh-code-review v${pluginVersion}_")
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

    # Prior automated-review summary (only when prior-reviews.json exists and
    # carries any bot activity). Sits above the static-analysis block so the
    # human reviewer sees what bots have already said before reading new
    # findings.
    $priorPath = Join-Path $cacheDir 'prior-reviews.json'
    $priorReviews = $null
    if (Test-Path $priorPath) {
        try {
            $priorReviews = Get-Content $priorPath -Raw | ConvertFrom-Json -AsHashtable
        } catch {
            Write-Verbose "Could not read $priorPath - $($_.Exception.Message)"
        }
    }
    function Get-PriorField {
        # StrictMode 3 friendly: read a key from the prior-reviews hashtable
        # without throwing when it's absent.
        param($ht, [string]$Key)
        if (-not $ht) { return $null }
        if ($ht -is [hashtable] -or $ht -is [System.Collections.IDictionary]) {
            if ($ht.Contains($Key)) { return $ht[$Key] } else { return $null }
        }
        if ($ht.PSObject.Properties[$Key]) { return $ht.$Key }
        return $null
    }

    $priorUnresolved = @(Get-PriorField $priorReviews 'unresolved_threads')
    $priorTopLevel   = @(Get-PriorField $priorReviews 'top_level_reviews')
    $priorResolved   = (Get-PriorField $priorReviews 'resolved_threads_count') ?? 0
    $priorBots       = @(Get-PriorField $priorReviews 'bots')

    $priorHasContent = ($priorUnresolved.Count -gt 0) -or ($priorTopLevel.Count -gt 0) -or ($priorResolved -gt 0)
    if ($priorHasContent) {
        [void]$sb.AppendLine("### Prior agent review summary")
        [void]$sb.AppendLine()
        $bots = $priorBots -join ', '
        if (-not $bots) { $bots = '(none recognised)' }
        [void]$sb.AppendLine("Bots seen: $bots")
        [void]$sb.AppendLine()

        [void]$sb.AppendLine("- Unresolved bot threads: $($priorUnresolved.Count)")
        [void]$sb.AppendLine("- Resolved bot threads: $priorResolved")
        [void]$sb.AppendLine("- Top-level bot reviews: $($priorTopLevel.Count)")
        [void]$sb.AppendLine()

        if ($priorUnresolved.Count -gt 0) {
            [void]$sb.AppendLine('| Bot | File | Line | Comment |')
            [void]$sb.AppendLine('| --- | ---- | ---- | ------- |')
            foreach ($t in $priorUnresolved) {
                # Single-line cell content. Replace pipes/newlines so the table
                # stays valid.
                $bot  = Get-PriorField $t 'bot'
                $path = Get-PriorField $t 'path'
                $line = Get-PriorField $t 'line'
                $body = (Get-PriorField $t 'body') ?? ''
                $body = $body.Trim() -replace '\r?\n', ' ' -replace '\|', '\|'
                if ($body.Length -gt 140) { $body = $body.Substring(0, 137) + '...' }
                [void]$sb.AppendLine("| $bot | $path | $line | $body |")
            }
            [void]$sb.AppendLine()
        }
    }

    # Static analysis summary
    [void]$sb.AppendLine("### Static analysis")
    [void]$sb.AppendLine()
    $pssaCount = @($static.psscriptanalyzer).Count + @($static.compatibility).Count
    [void]$sb.AppendLine("- PSScriptAnalyzer: $pssaCount finding(s)")
    [void]$sb.AppendLine("- InjectionHunter: $(@($static.injection_hunter).Count) finding(s)")
    [void]$sb.AppendLine("- Gitleaks: $(@($static.gitleaks).Count) finding(s)")
    if ($static.ContainsKey('eslint')) {
        [void]$sb.AppendLine("- ESLint: $(@($static.eslint).Count) finding(s)")
    }
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
    if ($static.ContainsKey('test_coverage')) {
        $tcRaw  = @($static.test_coverage).Count
        $tcKept = @($passedStaticHeuristic | Where-Object { $_.source -eq 'test_coverage' }).Count
        if ($tcRaw -eq $tcKept) {
            [void]$sb.AppendLine("- Test coverage: $tcRaw finding(s)")
        } else {
            [void]$sb.AppendLine("- Test coverage: $tcRaw raw, $tcKept post-filter")
        }
    }
    if ($static.pester -and $static.pester.ran) {
        [void]$sb.AppendLine("- Pester: $($static.pester.passed)/$($static.pester.total) passed, $($static.pester.failed) failed")
    } else {
        [void]$sb.AppendLine("- Pester: not run")
    }
    if ($static.tools_missing -and @($static.tools_missing).Count -gt 0) {
        [void]$sb.AppendLine("- Tools missing on PATH: $((@($static.tools_missing)) -join ', ')")
        # Per-tool install hints. Only emit hints for tools that are in the
        # missing list AND have a portable install command we can recommend.
        $hints = @{
            'eslint'              = 'npm install -g eslint'
            'gitleaks'            = 'See https://github.com/gitleaks/gitleaks for platform-specific install'
            'markdownlint-cli2'   = 'npm install -g markdownlint-cli2'
            'actionlint'          = 'See https://github.com/rhysd/actionlint for platform-specific install'
            'editorconfig-checker' = 'See https://editorconfig-checker.github.io/ for install'
        }
        foreach ($tool in @($static.tools_missing)) {
            if ($hints.ContainsKey($tool)) {
                [void]$sb.AppendLine("  - To install ``$tool``: ``$($hints[$tool])``")
            }
        }
    }
    # Tools that ran but failed at runtime — surface so a "0 findings"
    # result is never silently a tool failure.
    if ($static.ContainsKey('tools_errors') -and @($static.tools_errors).Count -gt 0) {
        [void]$sb.AppendLine("- Tools that errored during the run:")
        foreach ($te in @($static.tools_errors)) {
            $msg = ($te.message ?? '').ToString().Trim()
            if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 197) + '...' }
            $msg = $msg -replace '\r?\n', ' '
            [void]$sb.AppendLine("  - ``$($te.tool)`` (exit $($te.exit)): $msg")
        }
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
    [void]$sb.AppendLine("_Reviewed by pwsh-code-review v$pluginVersion. Use ``# pwsh-review:disable-next-line <rule>`` to suppress._")

    $markdown = $sb.ToString()
    $markdown | Set-Content $OutputPath -Encoding utf8NoBOM

    # Also emit the post-filter, post-cluster, sorted findings as JSON so
    # downstream posting tools (Post-PrReview.ps1) can consume the same
    # structure without re-running the filter/cluster pipeline.
    $mergedJsonPath = Join-Path $cacheDir 'merged-findings.json'
    $verdict = if ($counts.blocker -gt 0) { 'needs rework' }
               elseif ($counts.major -gt 0) { 'fix majors first' }
               else { 'ship' }
    $mergedPayload = [ordered]@{
        schema_version = '1'
        plugin_version = $pluginVersion
        generated      = (Get-Date).ToUniversalTime().ToString('o')
        counts         = $counts
        verdict        = $verdict
        findings       = @($sorted)
    }
    $mergedPayload | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $mergedJsonPath -Encoding utf8NoBOM

    [pscustomobject]@{
        OutputPath           = $OutputPath
        MergedJsonPath       = $mergedJsonPath
        TotalFindings        = @($sorted).Count
        Counts               = $counts
        Verdict              = $verdict
        StaticFindings       = @($staticAsFindings).Count
        AgentFindingsRaw     = @($agentFindings).Count
        AgentFindingsKept    = @($clustered).Count
        ConfidenceThreshold  = $ConfidenceThreshold
        NitCap               = $NitCap
    }
} finally {
    Pop-Location
}
