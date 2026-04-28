#requires -Version 7.4
<#
.SYNOPSIS
    Bootstraps a PowerShell repo for pwsh-code-review.

.DESCRIPTION
    Walks the repository, detects structure, drafts the project profile
    (architecture.md, standards.md, glossary.md, patterns/, PSScriptAnalyzerSettings.psd1,
    config.psd1, profile.lock.json), and computes the initial AST index.

    Designed to run once per repo. Subsequent reviews load the profile this
    command produces.

.PARAMETER RepoRoot
    Repository root.

.PARAMETER PluginRoot
    Path to the pwsh-code-review plugin (where templates/ lives).

.PARAMETER Mode
    'Default' (interactive-friendly), 'Refresh' (preserve hand edits), or 'Force'
    (overwrite all files).

.EXAMPLE
    Initialize-ReviewProfile.ps1 -PluginRoot ~/.claude/plugins/pwsh-code-review

.EXAMPLE
    Initialize-ReviewProfile.ps1 -Mode Refresh
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string]$RepoRoot = (Get-Location).Path,

    [Parameter(Mandatory)]
    [string]$PluginRoot,

    [ValidateSet('Default', 'Refresh', 'Force')]
    [string]$Mode = 'Default'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

Push-Location $RepoRoot
try {
    # Read plugin version so the user can see which build is running
    $pluginManifestPath = Join-Path $PluginRoot '.claude-plugin/plugin.json'
    $pluginVersion = if (Test-Path $pluginManifestPath) {
        (Get-Content $pluginManifestPath -Raw | ConvertFrom-Json).version
    } else {
        'unknown'
    }
    Write-Host "pwsh-code-review v$pluginVersion - bootstrap" -ForegroundColor Cyan
    Write-Host ""

    $profileDir = Join-Path $RepoRoot '.pwsh-review'
    $cacheDir   = Join-Path $profileDir 'cache'
    $patternDir = Join-Path $profileDir 'patterns'
    $templateDir = Join-Path $PluginRoot 'templates'

    # ---- Pre-flight ----

    if (-not (Test-Path (Join-Path $RepoRoot '.git'))) {
        throw "Not a git repository: $RepoRoot"
    }

    $existingProfile = Test-Path $profileDir
    if ($existingProfile -and $Mode -eq 'Default') {
        throw "Profile already exists at $profileDir. Use -Mode Refresh or -Mode Force."
    }

    if ($Mode -eq 'Force' -and $existingProfile) {
        $confirm = Read-Host "This will overwrite all hand edits in $profileDir. Type 'overwrite' to confirm"
        if ($confirm -ne 'overwrite') {
            Write-Host "Aborted." -ForegroundColor Yellow
            return
        }
    }

    foreach ($d in @($profileDir, $cacheDir, $patternDir)) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }

    # ---- Phase 1: Discovery ----

    Write-Host "Walking repository..." -ForegroundColor Cyan

    $allPwshFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '[/\\]\.pwsh-review[/\\]' -and
            $_.FullName -notmatch '[/\\]\.git[/\\]' -and
            $_.FullName -notmatch '[/\\]node_modules[/\\]'
        }

    if (-not $allPwshFiles) {
        throw "No PowerShell files found in $RepoRoot. Cannot bootstrap."
    }

    $manifests = @()
    $modules   = @()
    $tests     = @()
    $publicFns = @()
    $allFns    = @()
    $platformSignals = @{
        platform_check    = 0
        windows_only      = 0
        unix_only         = 0
        hardcoded_sep     = 0
        com_object        = 0
        registry          = 0
        powershell_exe    = 0
    }
    $requiredModules = @{}

    foreach ($file in $allPwshFiles) {
        $rel = [System.IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')

        switch -Wildcard ($file.Name) {
            '*.psd1' {
                try {
                    $data = Import-PowerShellDataFile -Path $file.FullName -ErrorAction Stop
                    if ($data.RootModule -or $data.ModuleVersion) {
                        $manifests += [pscustomobject]@{
                            Path                 = $rel
                            ModuleVersion        = $data.ModuleVersion
                            PowerShellVersion    = $data.PowerShellVersion
                            CompatiblePSEditions = $data.CompatiblePSEditions
                            FunctionsToExport    = $data.FunctionsToExport
                            RequiredModules      = $data.RequiredModules
                        }
                        if ($data.RequiredModules) {
                            foreach ($req in $data.RequiredModules) {
                                $name = if ($req -is [hashtable]) { $req.ModuleName } else { $req }
                                $version = if ($req -is [hashtable]) { $req.ModuleVersion ?? $req.RequiredVersion } else { $null }
                                $requiredModules[$name] = $version
                            }
                        }
                    }
                } catch { }
                continue
            }
            '*.psm1' { $modules += $rel; continue }
        }

        if ($file.Name -match '\.Tests\.ps1$' -or $rel -match '[/\\]tests?[/\\]') {
            $tests += $rel
        }

        # Parse for function inventory and platform signals
        try {
            $tokens = $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$tokens, [ref]$errors
            )

            $funcs = $ast.FindAll({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)

            foreach ($f in $funcs) {
                $entry = [pscustomobject]@{
                    Name = $f.Name
                    File = $rel
                    Line = $f.Extent.StartLineNumber
                    IsPublic = $rel -match '[/\\]Public[/\\]' -or $rel -match '[/\\]public[/\\]'
                }
                $allFns += $entry
                if ($entry.IsPublic) { $publicFns += $entry }
            }

            $text = $ast.Extent.Text
            if ($text -match '\$IsWindows|\$IsLinux|\$IsMacOS') { $platformSignals.platform_check++ }
            if ($text -match 'Get-CimInstance|Get-WmiObject|HKLM:|HKCU:') { $platformSignals.windows_only++ }
            if ($text -match 'New-Object\s+-ComObject|\[System\.__ComObject\]') { $platformSignals.com_object++ }
            if ($text -match 'New-PSDrive\s+-PSProvider\s+Registry|HKLM:|HKCU:') { $platformSignals.registry++ }
            if ($text -match 'powershell\.exe') { $platformSignals.powershell_exe++ }
            if ($text -match '"[^"]*\\\\[^"]*"') { $platformSignals.hardcoded_sep++ }
        } catch {
            Write-Verbose "Skipping ${rel}: $($_.Exception.Message)"
        }
    }

    # Decide platforms
    $detectedPlatforms = @('core-7.4-windows', 'core-7.4-linux', 'core-7.4-macos')
    $editions = $manifests | Where-Object { $_.CompatiblePSEditions } |
        ForEach-Object { $_.CompatiblePSEditions } | Select-Object -Unique
    if ($editions -eq 'Desktop' -and $editions -notcontains 'Core') {
        $detectedPlatforms = @('windows-powershell-5.1', 'core-7.4-windows')
    } elseif ($platformSignals.windows_only -gt 5 -and $platformSignals.platform_check -eq 0) {
        $detectedPlatforms = @('core-7.4-windows')
    }

    # Project shape
    $shape = if ($modules.Count -eq 0) { 'script-collection' }
             elseif ($modules.Count -eq 1) { 'single-module' }
             elseif ($modules.Count -gt 1) { 'multi-module' }
             else { 'unknown' }

    $projectName = (Split-Path -Path $RepoRoot -Leaf)
    if ($manifests) {
        $primary = $manifests | Sort-Object { ($_.Path -split '/').Count } | Select-Object -First 1
        $manifestName = [System.IO.Path]::GetFileNameWithoutExtension($primary.Path)
        if ($manifestName) { $projectName = $manifestName }
    }

    # ---- Phase 2: Generate files ----

    Write-Host "Drafting profile files..." -ForegroundColor Cyan

    # config.psd1
    $configPath = Join-Path $profileDir 'config.psd1'
    if ($Mode -ne 'Refresh' -or -not (Test-Path $configPath)) {
        $platformsList = ($detectedPlatforms | ForEach-Object { "'$_'" }) -join ', '
        $configContent = @"
@{
    ConfidenceThreshold = 80
    NitCap              = 3
    Platforms           = @($platformsList)
    SkipAgents          = @()
    StaticAnalysisOnly  = `$false
}
"@
        $configContent | Set-Content $configPath -Encoding utf8NoBOM
    }

    # PSScriptAnalyzerSettings.psd1
    $settingsPath = Join-Path $profileDir 'PSScriptAnalyzerSettings.psd1'
    if ($Mode -ne 'Refresh' -or -not (Test-Path $settingsPath)) {
        $template = Get-Content (Join-Path $templateDir 'PSScriptAnalyzerSettings.psd1') -Raw
        $platformList = ($detectedPlatforms | ForEach-Object { "                '$_'" }) -join ",`n"
        $template = $template -replace "(?ms)compatibility = @\(.*?\)", "compatibility = @(`n$platformList`n            )"
        $template = $template -replace "(?ms)TargetProfiles = @\(.*?\)", "TargetProfiles = @(`n$platformList`n            )"
        $template | Set-Content $settingsPath -Encoding utf8NoBOM
    }

    # standards.md
    $standardsPath = Join-Path $profileDir 'standards.md'
    if ($Mode -ne 'Refresh' -or -not (Test-Path $standardsPath)) {
        Copy-Item (Join-Path $templateDir 'standards.md') $standardsPath -Force
    }

    # architecture.md (always rendered with detected facts)
    $archPath = Join-Path $profileDir 'architecture.md'
    if ($Mode -ne 'Refresh' -or -not (Test-Path $archPath)) {
        $moduleRows = ($manifests | ForEach-Object {
            $modName = [System.IO.Path]::GetFileNameWithoutExtension($_.Path)
            $modDir = Split-Path -Path $_.Path -Parent
            $publicCount = @($publicFns | Where-Object { $_.File -like "$modDir/*" }).Count
            $internalCount = @($allFns | Where-Object { $_.File -like "$modDir/*" -and -not $_.IsPublic }).Count
            "| $modName | ``$modDir`` | $publicCount | $internalCount | _check tests/_ |"
        }) -join "`n"
        if (-not $moduleRows) { $moduleRows = "| _none detected_ | | | | |" }

        # Pre-compute values that the here-string needs, to avoid null-conditional gymnastics inside `$(...)`
        $lowestPwshVersion = '_unspecified_'
        if ($manifests) {
            $found = $manifests | Where-Object { $_.PowerShellVersion } | Sort-Object PowerShellVersion | Select-Object -First 1
            if ($found -and $found.PowerShellVersion) {
                $lowestPwshVersion = $found.PowerShellVersion
            }
        }

        $editionsLabel = if ($editions) { $editions -join ', ' } else { 'Core' }

        $publicSurfaceTable = if ($publicFns) {
            ($publicFns | ForEach-Object { "| $($_.Name) | ``$($_.File):$($_.Line)`` |" }) -join "`n"
        } else {
            "| _none detected_ | |"
        }

        $requiredModulesSection = if ($requiredModules.Count -eq 0) {
            "_None detected._"
        } else {
            $rows = ($requiredModules.GetEnumerator() | ForEach-Object {
                $ver = if ($_.Value) { $_.Value } else { '_unspecified_' }
                "| $($_.Key) | $ver | <!-- TODO --> |"
            }) -join "`n"
            "| Module | Version | Purpose |`n| ------ | ------- | ------- |`n$rows"
        }

        $archContent = @"
# Architecture

## Project shape

<!-- TODO: confirm or replace -->
$projectName is a **$shape**. Auto-detected from $($manifests.Count) module manifest(s) and $($modules.Count) .psm1 file(s).

## Module map

<!-- TODO: regenerate with /pwsh-review-bootstrap --refresh after structural changes -->

| Module | Path | Public | Internal | Tests |
| ------ | ---- | ------ | -------- | ----- |
$moduleRows

## Dependency direction

<!-- TODO: state explicitly which module depends on which -->

## Public surface

<!-- TODO: review and trim. The reviewer treats this list as the contract surface. -->

$($publicFns.Count) public function(s) detected.

| Function | File |
| -------- | ---- |
$publicSurfaceTable

## Side-effect boundary

<!-- TODO: describe where I/O is allowed and where it is not -->

## External dependencies

### PowerShell modules

$requiredModulesSection

### Native commands assumed on PATH

<!-- TODO: list & exe / native commands the project invokes -->

## Target platform

- pwsh: 7.4+ (detected lowest from manifests: $lowestPwshVersion)
- editions: $editionsLabel
- platforms: $($detectedPlatforms -join ', ')

Cross-platform signals detected:
- Platform-check variables (`$IsWindows / `$IsLinux / `$IsMacOS) referenced: $($platformSignals.platform_check) time(s)
- Windows-only cmdlets without guard: $($platformSignals.windows_only) (review for cross-platform safety)
- COM object usage: $($platformSignals.com_object)
- Hard-coded path separators: $($platformSignals.hardcoded_sep)
- ``powershell.exe`` invocations: $($platformSignals.powershell_exe)

## Build and test

<!-- TODO -->

- Tests: $($tests.Count) Pester test file(s) detected
- CI: $(if (Test-Path '.github/workflows') { 'GitHub Actions detected' } elseif (Test-Path 'azure-pipelines.yml') { 'Azure Pipelines detected' } else { '_TODO_' })

## Conventions specific to this project

<!-- TODO: list project-specific conventions the reviewer should respect -->
"@
        $archContent | Set-Content $archPath -Encoding utf8NoBOM
    }

    # glossary.md - mine repeated identifiers
    $glossaryPath = Join-Path $profileDir 'glossary.md'
    if ($Mode -ne 'Refresh' -or -not (Test-Path $glossaryPath)) {
        # Mine top capitalised tokens from function names and comments
        $tokenCounts = @{}
        $stopwords = @('Get', 'Set', 'New', 'Remove', 'Add', 'Test', 'Invoke', 'Out', 'Write',
                       'Read', 'Import', 'Export', 'Start', 'Stop', 'The', 'This', 'That',
                       'Param', 'Path', 'Name', 'Value', 'Object', 'String', 'Default')

        foreach ($f in $allFns) {
            $parts = $f.Name -split '-' | Select-Object -Skip 1
            foreach ($p in $parts) {
                if ($p.Length -ge 4 -and $p -notin $stopwords -and $p -cmatch '^[A-Z]') {
                    if (-not $tokenCounts.Contains($p)) { $tokenCounts[$p] = @{ Count = 0; Files = @() } }
                    $tokenCounts[$p].Count++
                    $tokenCounts[$p].Files += "$($f.File):$($f.Line)"
                }
            }
        }

        $topTerms = @($tokenCounts.GetEnumerator() |
            Where-Object { $_.Value.Count -ge 3 } |
            Sort-Object { $_.Value.Count } -Descending |
            Select-Object -First 20)

        $entries = if ($topTerms) {
            ($topTerms | ForEach-Object {
                $term = $_.Key
                $count = $_.Value.Count
                $usages = ($_.Value.Files | Select-Object -First 3 -Unique | ForEach-Object { "``$_``" }) -join ', '
                @"
### $term

<!-- TODO: confirm definition -->
Domain term, appears in $count function name(s).

Used in: $usages
"@
            }) -join "`n`n"
        } else {
            @"
### Example

A placeholder. Replace with real domain terms specific to this project.
"@
        }

        $glossaryContent = @"
# Glossary

Domain terms used in this codebase. The reviewer uses this file to **avoid** flagging deliberate naming as misnamings. If a term appears here, the agent treats it as authoritative.

## Format

```markdown
### TermName

One-sentence definition.

Used in: ``path/to/file.ps1:line``
Related: TermB, TermC
```

## Entries

<!-- All entries below were inferred from repeated usage in function names. Confirm or replace. -->

$entries
"@
        $glossaryContent | Set-Content $glossaryPath -Encoding utf8NoBOM
    }

    # patterns/ - only copy templates if Force or fresh
    if ($Mode -ne 'Refresh') {
        foreach ($pattern in @('pattern-pipeline-cmdlet.ps1', 'pattern-error-handling.ps1', 'pattern-module-init.psm1')) {
            $src = Join-Path $templateDir "patterns/$pattern"
            $dst = Join-Path $patternDir $pattern
            if ((Test-Path $src) -and (-not (Test-Path $dst) -or $Mode -eq 'Force')) {
                Copy-Item $src $dst -Force
            }
        }
    }

    # ---- Phase 3: AST index ----

    Write-Host "Building AST index..." -ForegroundColor Cyan
    $astScript = Join-Path $PluginRoot 'scripts/Get-AstIndex.ps1'
    if (Test-Path $astScript) {
        & $astScript -RepoRoot $RepoRoot -Cold | Out-Null
    } else {
        Write-Warning "Get-AstIndex.ps1 not found at $astScript. Skipping AST index."
    }

    # ---- Phase 4: profile.lock.json ----

    Write-Host "Writing profile.lock.json..." -ForegroundColor Cyan
    $lockData = [ordered]@{
        version          = '1'
        generated        = (Get-Date).ToUniversalTime().ToString('o')
        public_surface   = [ordered]@{}
        manifests        = [ordered]@{}
        top_dirs         = [ordered]@{}
        ruleset_version  = '1'
    }

    foreach ($pf in $publicFns) {
        $sigBytes = [System.Text.Encoding]::UTF8.GetBytes("$($pf.Name)|$($pf.File)")
        $sigHash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($sigBytes) |
            ForEach-Object { $_.ToString('x2') }
        $lockData.public_surface[$pf.Name] = @{
            signature_hash = ($sigHash -join '')
            file           = $pf.File
        }
    }

    foreach ($m in $manifests) {
        $fullPath = Join-Path $RepoRoot $m.Path
        if (Test-Path $fullPath) {
            $h = (Get-FileHash $fullPath -Algorithm SHA256).Hash
            $lockData.manifests[$m.Path] = @{
                hash    = $h
                version = $m.ModuleVersion
            }
        }
    }

    $topDirs = Get-ChildItem -Path $RepoRoot -Directory |
        Where-Object { $_.Name -notmatch '^\.' -and $_.Name -ne 'node_modules' }
    foreach ($d in $topDirs) {
        $listing = Get-ChildItem $d.FullName -Recurse -File |
            ForEach-Object { [System.IO.Path]::GetRelativePath($RepoRoot, $_.FullName) } |
            Sort-Object
        $combined = ($listing -join "`n")
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
        $h = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
        $lockData.top_dirs[$d.Name] = (($h | ForEach-Object { $_.ToString('x2') }) -join '')
    }

    $lockData | ConvertTo-Json -Depth 10 |
        Set-Content (Join-Path $profileDir 'profile.lock.json') -Encoding utf8NoBOM

    # ---- Phase 5: Static layer dry-run ----

    Write-Host "Verifying static-analysis tooling..." -ForegroundColor Cyan
    $staticScript = Join-Path $PluginRoot 'scripts/Invoke-StaticAnalysis.ps1'
    $tools = if (Test-Path $staticScript) {
        & $staticScript -RepoRoot $RepoRoot -DryRun
    } else {
        $null
    }

    # ---- Phase 6: Summary ----

    Write-Host ""
    Write-Host "pwsh-code-review profile created at $profileDir" -ForegroundColor Green
    Write-Host ""
    Write-Host "Detected:"
    Write-Host "  Project:        $projectName"
    Write-Host "  Shape:          $shape"
    Write-Host "  Modules:        $($modules.Count)"
    Write-Host "  Manifests:      $($manifests.Count)"
    Write-Host "  Public funcs:   $($publicFns.Count)"
    Write-Host "  Total funcs:    $($allFns.Count)"
    Write-Host "  Tests:          $($tests.Count)"
    Write-Host "  Platforms:      $($detectedPlatforms -join ', ')"
    Write-Host ""
    Write-Host "Drafted (please review and edit):"
    Write-Host "  architecture.md         (sections marked TODO)"
    Write-Host "  standards.md            (filled from template)"
    Write-Host "  glossary.md             (terms drafted, all marked TODO)"
    Write-Host "  patterns/               (templates - replace with real examples from your codebase)"
    Write-Host "  PSScriptAnalyzerSettings.psd1"
    Write-Host "  config.psd1"
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Review the drafted files. Especially glossary.md and architecture.md."
    Write-Host "  2. Replace template patterns/ with real canonical examples from your codebase."
    Write-Host "  3. Commit .pwsh-review/ to the repo."
    Write-Host "  4. Run /pwsh-review on a real change to test."
    Write-Host ""

    [pscustomobject]@{
        ProfileDir       = $profileDir
        Project          = $projectName
        Shape            = $shape
        ModulesDetected  = $modules.Count
        ManifestsDetected = $manifests.Count
        PublicFunctions  = $publicFns.Count
        TotalFunctions   = $allFns.Count
        TestsDetected    = $tests.Count
        Platforms        = $detectedPlatforms
        ToolsAvailable   = $tools
    }
} finally {
    Pop-Location
}
