#requires -Version 7.4
<#
.SYNOPSIS
    Detects functional files in the diff that lack a corresponding test file
    change. Emits PWSH-COV-001 (Warning, conf 75, major).

.DESCRIPTION
    The static layer can determine deterministically that a diff modifies
    production-shaped code without touching the tests/ folder. That signal is
    too noisy to act on without an exemption list, so this rule:

      1. Walks the changed-files list and filters to "functional" files
         (`.ps1` / `.psm1` not matching the test-file or harness conventions
         and not in an exempt path).
      2. For each functional file, looks for a related test file in the
         changed-files list using two strategies in order:
           a. Name-matched: tests/<basename>.Tests.ps1, <basename>.Tests.ps1
              alongside the source, tests/Test-<basename>.ps1, or
              Test-<basename>.ps1 alongside the source.
           b. Loose: any *.Tests.ps1 or Test-*.ps1 file is in the diff
              (covers projects with a single shared test runner).
      3. Files with no test signal at all emit PWSH-COV-001.

    Exemption list (do not flag for missing tests):
      - Markdown / text documentation
      - JSON / YAML / TOML / `.psd1` configuration
      - CSS / SCSS / LESS style files
      - `.github/`, `.azure-pipelines*`, `.vscode/` tooling
      - `.gitignore`, `.editorconfig`, `.env.example`
      - Anything under a `skills/` folder (agent prompts, not code)
      - Anything under `templates/` (these ship as plugin templates)
      - Test files themselves and known harnesses (`Run.ps1`, `Run-Tests.ps1`)

.PARAMETER RepoRoot
    Repository root. Findings emit with paths relative to this.

.PARAMETER ChangedFiles
    Explicit list of changed file paths (relative or absolute). Use this when
    invoking from a script that has already computed the diff.

.PARAMETER DiffContextPath
    Path to a diff-context.json. When -ChangedFiles is empty, the script
    reads this and uses its `changed_files` array instead. Defaults to
    `.pwsh-review/cache/diff-context.json` under -RepoRoot.

.OUTPUTS
    Array of finding hashtables in the same shape as Test-Brittleness.ps1.
    Empty array when nothing to flag.
#>
[CmdletBinding()]
[OutputType([object[]])]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string[]]$ChangedFiles = @(),
    [string]$DiffContextPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:Rules = @{
    'PWSH-COV-001' = @{ Severity = 'Warning'; Confidence = 75 }  # major
}

function Get-RuleSeverity {
    param([Parameter(Mandatory)][string]$Rule)
    return $script:Rules[$Rule].Severity
}

function Get-RuleConfidence {
    param([Parameter(Mandatory)][string]$Rule)
    return $script:Rules[$Rule].Confidence
}

function New-Finding {
    param(
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Message,
        [int]$Line = 1,
        [int]$Column = 0
    )
    [ordered]@{
        rule_name  = $Rule
        severity   = Get-RuleSeverity $Rule
        file       = $File
        line       = $Line
        column     = $Column
        message    = $Message
        confidence = Get-RuleConfidence $Rule
    }
}

function ConvertTo-RelativePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    if (-not [IO.Path]::IsPathRooted($Path)) { return ($Path -replace '\\', '/') }
    try {
        $resolved     = [IO.Path]::GetFullPath($Path)
        $rootResolved = [IO.Path]::GetFullPath($Root)
        if ($resolved.StartsWith($rootResolved, [StringComparison]::OrdinalIgnoreCase)) {
            $rel = $resolved.Substring($rootResolved.Length).TrimStart('\', '/')
            return ($rel -replace '\\', '/')
        }
        return ($Path -replace '\\', '/')
    } catch {
        return ($Path -replace '\\', '/')
    }
}

function Test-IsTestFile {
    param([Parameter(Mandatory)][string]$RelativePath)
    $base = [IO.Path]::GetFileName($RelativePath)
    if ($base -like '*.Tests.ps1') { return $true }
    if ($base -like 'Test-*.ps1') {
        # Exclude harnesses that are not actual test files: Run.ps1 lives next
        # to fixtures, Test-Helpers / Test-Utilities-style files don't carry
        # assertions. We can't read content here; the safer assumption is that
        # any Test-X.ps1 is a test file. Genuine harnesses are usually named
        # Run.ps1 / Run-Tests.ps1 / Test-Helpers.ps1 — handled below.
        if ($base -in @('Test-Helpers.ps1', 'Test-Utilities.ps1')) { return $false }
        return $true
    }
    return $false
}

function Test-IsHarnessFile {
    param([Parameter(Mandatory)][string]$RelativePath)
    $base = [IO.Path]::GetFileName($RelativePath)
    return ($base -in @('Run.ps1', 'Run-Tests.ps1', 'Test-Helpers.ps1', 'Test-Utilities.ps1'))
}

function Test-IsExemptPath {
    param([Parameter(Mandatory)][string]$RelativePath)
    $base = [IO.Path]::GetFileName($RelativePath)
    $ext  = [IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    $rel  = ($RelativePath -replace '\\', '/')

    # Documentation, configuration, style.
    if ($ext -in @('.md', '.markdown', '.txt', '.rst')) { return $true }
    if ($ext -in @('.json', '.yaml', '.yml', '.toml', '.psd1', '.xml', '.ini')) { return $true }
    if ($ext -in @('.css', '.scss', '.less')) { return $true }
    if ($ext -in @('.svg', '.png', '.jpg', '.jpeg', '.gif', '.ico')) { return $true }

    # CI / tooling / editor / env.
    if ($rel -match '(^|/)(\.github|\.gitea|\.azuredevops|\.vscode|\.idea)/') { return $true }
    if ($base -like '.azure-pipelines*') { return $true }
    if ($base -in @('.gitignore', '.editorconfig', '.env.example', '.env.sample', '.gitattributes', '.dockerignore')) { return $true }

    # Plugin / framework content that intentionally has no per-file tests.
    if ($rel -match '(^|/)skills/') { return $true }
    if ($rel -match '(^|/)templates/') { return $true }
    if ($rel -match '(^|/)agents/') { return $true }    # agent prompts
    if ($rel -match '(^|/)commands/') { return $true }  # command prompts
    if ($rel -match '(^|/)docs/') { return $true }      # documentation
    if ($rel -match '(^|/)\.claude-plugin/') { return $true }

    # Test fixtures.
    if ($rel -match '(^|/)Tests-[A-Za-z0-9_-]+/') { return $true }

    return $false
}

function Test-IsFunctionalFile {
    param([Parameter(Mandatory)][string]$RelativePath)
    $ext = [IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    if ($ext -notin @('.ps1', '.psm1')) { return $false }
    if (Test-IsTestFile -RelativePath $RelativePath) { return $false }
    if (Test-IsHarnessFile -RelativePath $RelativePath) { return $false }
    if (Test-IsExemptPath -RelativePath $RelativePath) { return $false }
    return $true
}

function Get-RelatedTestCandidates {
    # Returns the relative test-file paths that, if they appeared in the diff
    # alongside the functional file, would satisfy "name-matched coverage".
    # Caller compares against the changed-files set.
    param([Parameter(Mandatory)][string]$RelativePath)
    $base = [IO.Path]::GetFileNameWithoutExtension($RelativePath)
    $dir  = ([IO.Path]::GetDirectoryName($RelativePath) -replace '\\', '/')
    if (-not $dir) { $dir = '' }

    $candidates = [System.Collections.Generic.List[string]]::new()

    # Sibling patterns (next to the source).
    if ($dir) {
        [void]$candidates.Add("$dir/$base.Tests.ps1")
        [void]$candidates.Add("$dir/Test-$base.ps1")
    } else {
        [void]$candidates.Add("$base.Tests.ps1")
        [void]$candidates.Add("Test-$base.ps1")
    }

    # Repo-root tests/ patterns.
    [void]$candidates.Add("tests/$base.Tests.ps1")
    [void]$candidates.Add("tests/Test-$base.ps1")

    # tests/ alongside source (for nested layouts like core/runtime/tests/).
    if ($dir) {
        [void]$candidates.Add("$dir/tests/$base.Tests.ps1")
        [void]$candidates.Add("$dir/tests/Test-$base.ps1")
    }

    return $candidates
}

# --- Driver -----------------------------------------------------------------

# Resolve the changed-files list from explicit parameter or a diff-context.json.
if ($ChangedFiles.Count -eq 0) {
    if (-not $DiffContextPath) {
        $DiffContextPath = Join-Path $RepoRoot '.pwsh-review/cache/diff-context.json'
    }
    if (Test-Path -LiteralPath $DiffContextPath) {
        try {
            $dc = Get-Content -LiteralPath $DiffContextPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($dc.PSObject.Properties.Name -contains 'changed_files') {
                $ChangedFiles = @($dc.changed_files)
            }
        } catch {
            Write-Warning "Test-Coverage: failed to read $DiffContextPath - $($_.Exception.Message)"
            $ChangedFiles = @()
        }
    }
}

if ($ChangedFiles.Count -eq 0) {
    , @()
    return
}

# Normalize all changed paths to relative-with-forward-slashes.
$relativeChanged = @($ChangedFiles | ForEach-Object {
    ConvertTo-RelativePath -Path $_ -Root $RepoRoot
})
$relativeChanged = @($relativeChanged | Where-Object { $_ })  # drop empties

# Bucket into functional, test, exempt.
$functional   = @($relativeChanged | Where-Object { Test-IsFunctionalFile -RelativePath $_ })
$testInDiff   = @($relativeChanged | Where-Object { Test-IsTestFile -RelativePath $_ })
$diffHasTests = ($testInDiff.Count -gt 0)

$findings = @()
foreach ($func in $functional) {
    # Strict name-match first.
    $candidates = Get-RelatedTestCandidates -RelativePath $func
    $matched = $null
    foreach ($cand in $candidates) {
        if ($relativeChanged -contains $cand) { $matched = $cand; break }
    }
    if ($matched) { continue }

    # Loose fallback: any test file in the diff is treated as covering the change.
    if ($diffHasTests) { continue }

    $hint = if ($candidates.Count -gt 0) { $candidates[0] } else { "tests/$([IO.Path]::GetFileNameWithoutExtension($func)).Tests.ps1" }
    $msg  = "Functional file changed without a corresponding test file change in the diff. Add coverage for the change (e.g. ``$hint``) or update an existing test that exercises this code path."
    $findings += (New-Finding -Rule 'PWSH-COV-001' -File $func -Message $msg)
}

, $findings
