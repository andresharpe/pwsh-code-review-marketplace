#requires -Version 7.4
<#
.SYNOPSIS
    Runs the deterministic static-analysis pre-pass for pwsh-code-review.

.DESCRIPTION
    Runs PSScriptAnalyzer (project + compatibility), InjectionHunter,
    Gitleaks, Pester (if test files changed), markdownlint, actionlint
    and editorconfig-checker (if available) in parallel.

    Writes results to .pwsh-review/cache/static-findings.json.

.PARAMETER RepoRoot
    Repository root.

.PARAMETER All
    Scan the whole repo, not just changed files. Use during bootstrap.

.PARAMETER DryRun
    Verify tools are installed and configurations parse, but do not
    perform a full scan.

.EXAMPLE
    Invoke-StaticAnalysis.ps1
    Runs against the diff scope.

.EXAMPLE
    Invoke-StaticAnalysis.ps1 -All
    Runs against the entire repo.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [switch]$All,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

Push-Location $RepoRoot
try {
    $cacheDir = Join-Path $RepoRoot '.pwsh-review/cache'
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    $configPath = Join-Path $RepoRoot '.pwsh-review/config.psd1'
    $config = if (Test-Path $configPath) {
        Import-PowerShellDataFile $configPath
    } else {
        @{
            Platforms = @('core-7.4-windows', 'core-7.4-linux', 'core-7.4-macos')
        }
    }

    $settingsPath = Join-Path $RepoRoot '.pwsh-review/PSScriptAnalyzerSettings.psd1'
    if (-not (Test-Path $settingsPath)) {
        throw "PSScriptAnalyzerSettings.psd1 not found at $settingsPath. Run /pwsh-review-bootstrap first."
    }

    # Determine scope
    $scopePaths = if ($All) {
        @('.')
    } else {
        $diffContextPath = Join-Path $cacheDir 'diff-context.json'
        if (Test-Path $diffContextPath) {
            $dc = Get-Content $diffContextPath -Raw | ConvertFrom-Json
            @($dc.changed_files | Where-Object { Test-Path $_ })
        } else {
            @('.')
        }
    }
    if (-not $scopePaths) { $scopePaths = @('.') }

    # Verify required modules
    $required = @('PSScriptAnalyzer', 'Pester')
    $optional = @('InjectionHunter', 'PSCodeHealth')
    foreach ($mod in $required) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            if ($DryRun) {
                Write-Warning "$mod not installed."
            } else {
                Write-Verbose "Installing $mod..."
                Install-Module -Name $mod -Scope CurrentUser -Force -SkipPublisherCheck
            }
        }
    }
    foreach ($mod in $optional) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            Write-Verbose "Optional module $mod not installed."
        }
    }

    if ($DryRun) {
        $pssaMod = Get-Module -ListAvailable PSScriptAnalyzer -ErrorAction SilentlyContinue | Select-Object -First 1
        $pesterMod = Get-Module -ListAvailable Pester -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
        $ihMod = Get-Module -ListAvailable InjectionHunter -ErrorAction SilentlyContinue | Select-Object -First 1

        return [pscustomobject]@{
            DryRun       = $true
            ScopePaths   = $scopePaths
            SettingsPath = $settingsPath
            Tools        = @{
                PSScriptAnalyzer  = if ($pssaMod)   { $pssaMod.Version.ToString() }   else { $null }
                Pester            = if ($pesterMod) { $pesterMod.Version.ToString() } else { $null }
                InjectionHunter   = if ($ihMod)     { $ihMod.Version.ToString() }     else { $null }
                Gitleaks          = if (Get-Command gitleaks -ErrorAction SilentlyContinue) { (gitleaks version 2>$null) } else { $null }
                Markdownlint      = if (Get-Command markdownlint-cli2 -ErrorAction SilentlyContinue) { 'available' } else { $null }
                Actionlint        = if (Get-Command actionlint -ErrorAction SilentlyContinue) { 'available' } else { $null }
                EditorConfig      = if (Get-Command editorconfig-checker -ErrorAction SilentlyContinue) { 'available' } else { $null }
            }
        }
    }

    Import-Module PSScriptAnalyzer -ErrorAction Stop

    # ---- Run all tools in parallel ----

    $jobs = @()

    # 1. PSScriptAnalyzer with project settings
    $jobs += Start-ThreadJob -Name 'PSSA-Project' -ScriptBlock {
        param($paths, $settings, $repoRoot)
        Import-Module PSScriptAnalyzer
        Push-Location $repoRoot
        try {
            $findings = @()
            foreach ($p in $paths) {
                $findings += Invoke-ScriptAnalyzer -Path $p -Recurse -Settings $settings -ErrorAction SilentlyContinue
            }
            ,$findings
        } finally { Pop-Location }
    } -ArgumentList $scopePaths, $settingsPath, $RepoRoot

    # 2. Compatibility rules (separate run)
    $jobs += Start-ThreadJob -Name 'PSSA-Compat' -ScriptBlock {
        param($paths, $platforms, $repoRoot)
        Import-Module PSScriptAnalyzer
        Push-Location $repoRoot
        try {
            $compatSettings = @{
                Rules = @{
                    PSUseCompatibleSyntax = @{
                        Enable         = $true
                        TargetVersions = @('7.4')
                    }
                    PSUseCompatibleCmdlets = @{
                        Enable        = $true
                        compatibility = $platforms
                    }
                    PSUseCompatibleCommands = @{
                        Enable         = $true
                        TargetProfiles = $platforms
                    }
                    PSUseCompatibleTypes = @{
                        Enable         = $true
                        TargetProfiles = $platforms
                    }
                }
            }
            $findings = @()
            foreach ($p in $paths) {
                $findings += Invoke-ScriptAnalyzer -Path $p -Recurse -Settings $compatSettings -ErrorAction SilentlyContinue
            }
            ,$findings
        } finally { Pop-Location }
    } -ArgumentList $scopePaths, $config.Platforms, $RepoRoot

    # 3. InjectionHunter (optional)
    if (Get-Module -ListAvailable -Name InjectionHunter) {
        $ihPath = (Get-Module -ListAvailable InjectionHunter | Select-Object -First 1).Path
        $jobs += Start-ThreadJob -Name 'InjectionHunter' -ScriptBlock {
            param($paths, $ihPath, $repoRoot)
            Import-Module PSScriptAnalyzer
            Push-Location $repoRoot
            try {
                $findings = @()
                foreach ($p in $paths) {
                    $findings += Invoke-ScriptAnalyzer -Path $p -Recurse -CustomRulePath $ihPath -ErrorAction SilentlyContinue
                }
                ,$findings
            } finally { Pop-Location }
        } -ArgumentList $scopePaths, $ihPath, $RepoRoot
    }

    # 4. Gitleaks (optional, external binary)
    if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
        $jobs += Start-ThreadJob -Name 'Gitleaks' -ScriptBlock {
            param($repoRoot, $cacheDir)
            Push-Location $repoRoot
            try {
                $reportPath = Join-Path $cacheDir 'gitleaks.json'
                & gitleaks detect --source . --report-path $reportPath --report-format json --no-banner --exit-code 0 2>$null | Out-Null
                if (Test-Path $reportPath) {
                    $content = Get-Content $reportPath -Raw -ErrorAction SilentlyContinue
                    if ($content) {
                        ,(@($content | ConvertFrom-Json))
                    } else { ,@() }
                } else { ,@() }
            } finally { Pop-Location }
        } -ArgumentList $RepoRoot, $cacheDir
    }

    # 5. Pester (only if test files were touched, or -All)
    $runPester = $All -or ($scopePaths | Where-Object { $_ -match '\.Tests\.ps1$' })
    if ($runPester) {
        $jobs += Start-ThreadJob -Name 'Pester' -ScriptBlock {
            param($repoRoot)
            Import-Module Pester
            Push-Location $repoRoot
            try {
                $cfg = New-PesterConfiguration
                $cfg.Run.Path = if (Test-Path 'tests') { 'tests' } else { '.' }
                $cfg.Run.PassThru = $true
                $cfg.Output.Verbosity = 'None'
                $cfg.Run.Throw = $false
                $result = Invoke-Pester -Configuration $cfg
                ,[ordered]@{
                    ran           = $true
                    total         = $result.TotalCount
                    passed        = $result.PassedCount
                    failed        = $result.FailedCount
                    skipped       = $result.SkippedCount
                    failed_tests  = @($result.Failed | ForEach-Object {
                        @{
                            name           = $_.ExpandedName
                            file           = $_.ScriptBlock.File
                            line           = $_.ScriptBlock.StartPosition.StartLine
                            error_message  = $_.ErrorRecord[0].ToString()
                        }
                    })
                }
            } catch {
                ,[ordered]@{ ran = $false; error = $_.Exception.Message }
            } finally { Pop-Location }
        } -ArgumentList $RepoRoot
    }

    # 6. Markdownlint (optional)
    if (Get-Command markdownlint-cli2 -ErrorAction SilentlyContinue) {
        $mdScope = if ($All) { @('**/*.md') } else { $scopePaths | Where-Object { $_ -match '\.md$' } }
        if ($mdScope) {
            $jobs += Start-ThreadJob -Name 'Markdownlint' -ScriptBlock {
                param($repoRoot, $files)
                Push-Location $repoRoot
                try {
                    $output = & markdownlint-cli2 --json @files 2>&1
                    ,@($output | ConvertFrom-Json -ErrorAction SilentlyContinue)
                } finally { Pop-Location }
            } -ArgumentList $RepoRoot, $mdScope
        }
    }

    # 7. Test brittleness (heuristic AST scan over Pester / dotbot test files)
    $tbScript = Join-Path $PSScriptRoot 'Test-Brittleness.ps1'
    if (Test-Path $tbScript) {
        $tbScope = if ($All) {
            @($RepoRoot)
        } else {
            @($scopePaths | Where-Object {
                $leaf = Split-Path $_ -Leaf
                $_ -match '\.Tests\.ps1$' -or $leaf -like 'Test-*.ps1'
            })
        }
        if ($tbScope) {
            $jobs += Start-ThreadJob -Name 'TestBrittleness' -ScriptBlock {
                param($repoRoot, $scope, $script)
                Push-Location $repoRoot
                try {
                    , (& $script -RepoRoot $repoRoot -Path $scope)
                } finally { Pop-Location }
            } -ArgumentList $RepoRoot, $tbScope, $tbScript
        }
    }

    # 8. Template-substitution check (heuristic scan of `.md` for `{{TOKEN}}`
    #    misuse — unknown tokens, dead "if {{X}} is empty" conditionals).
    $tplScript = Join-Path $PSScriptRoot 'Test-TemplateSubstitution.ps1'
    if (Test-Path $tplScript) {
        $jobs += Start-ThreadJob -Name 'TemplateSubstitution' -ScriptBlock {
            param($repoRoot, $script)
            Push-Location $repoRoot
            try {
                , (& $script -RepoRoot $repoRoot)
            } finally { Pop-Location }
        } -ArgumentList $RepoRoot, $tplScript
    }

    # Wait for all
    $results = $jobs | Wait-Job | ForEach-Object {
        $name = $_.Name
        $value = Receive-Job -Job $_ -ErrorAction SilentlyContinue
        @{ Name = $name; Value = $value }
    }
    $jobs | Remove-Job -Force

    # Aggregate
    $aggregate = [ordered]@{
        schema_version    = '1'
        generated         = (Get-Date).ToUniversalTime().ToString('o')
        psscriptanalyzer  = @()
        compatibility     = @()
        injection_hunter  = @()
        gitleaks          = @()
        pester            = $null
        markdownlint      = @()
        test_brittleness  = @()
        template_substitution = @()
        tools_missing     = @()
    }

    foreach ($r in $results) {
        switch ($r.Name) {
            'PSSA-Project'    { $aggregate.psscriptanalyzer = @($r.Value | ForEach-Object {
                @{
                    rule_name             = $_.RuleName
                    severity              = $_.Severity.ToString()
                    file                  = ($_.ScriptPath ?? $_.ScriptName)
                    line                  = $_.Line
                    column                = $_.Column
                    message               = $_.Message
                    suggested_corrections = @()
                }
            }) }
            'PSSA-Compat'     { $aggregate.compatibility = @($r.Value | ForEach-Object {
                @{
                    rule_name = $_.RuleName
                    severity  = $_.Severity.ToString()
                    file      = ($_.ScriptPath ?? $_.ScriptName)
                    line      = $_.Line
                    message   = $_.Message
                }
            }) }
            'InjectionHunter' { $aggregate.injection_hunter = @($r.Value | ForEach-Object {
                @{
                    rule_name = $_.RuleName
                    severity  = $_.Severity.ToString()
                    file      = ($_.ScriptPath ?? $_.ScriptName)
                    line      = $_.Line
                    message   = $_.Message
                }
            }) }
            'Gitleaks'        { $aggregate.gitleaks = @($r.Value) }
            'Pester'          { $aggregate.pester = $r.Value }
            'Markdownlint'    { $aggregate.markdownlint = @($r.Value) }
            'TestBrittleness' { $aggregate.test_brittleness = @($r.Value | ForEach-Object {
                @{
                    rule_name  = $_.rule_name
                    severity   = $_.severity
                    file       = $_.file
                    line       = $_.line
                    column     = $_.column
                    message    = $_.message
                    confidence = $_.confidence
                }
            }) }
            'TemplateSubstitution' { $aggregate.template_substitution = @($r.Value | ForEach-Object {
                @{
                    rule_name  = $_.rule_name
                    severity   = $_.severity
                    file       = $_.file
                    line       = $_.line
                    column     = $_.column
                    message    = $_.message
                    confidence = $_.confidence
                }
            }) }
        }
    }

    foreach ($tool in @('gitleaks', 'markdownlint-cli2', 'actionlint', 'editorconfig-checker')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            $aggregate.tools_missing += $tool
        }
    }

    $outputPath = Join-Path $cacheDir 'static-findings.json'
    $aggregate | ConvertTo-Json -Depth 20 | Set-Content $outputPath -Encoding utf8NoBOM

    [pscustomobject]@{
        OutputPath                  = $outputPath
        PSSAFindings                = $aggregate.psscriptanalyzer.Count
        CompatibilityIssues         = $aggregate.compatibility.Count
        InjectionFindings           = $aggregate.injection_hunter.Count
        GitleaksFindings            = $aggregate.gitleaks.Count
        TestBrittlenessFindings     = $aggregate.test_brittleness.Count
        TemplateSubstitutionFindings = $aggregate.template_substitution.Count
        PesterFailed                = if ($aggregate.pester) { $aggregate.pester.failed } else { 'not-run' }
        ToolsMissing                = $aggregate.tools_missing
    }
} finally {
    Pop-Location
}
