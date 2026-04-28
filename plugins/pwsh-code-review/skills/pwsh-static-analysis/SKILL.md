---
name: pwsh-static-analysis
description: How to run the deterministic static-analysis pre-pass for pwsh-code-review. Covers PSScriptAnalyzer, InjectionHunter, Gitleaks, Pester, and optional auxiliary tools. Defines the output schema agents consume. Use when invoking the static phase of a review or when explaining what the static layer covers.
---

# Static analysis skill

The deterministic layer. Runs before any AI agent. Findings here are ground truth: agents must not re-flag what this layer caught.

## Tools

### Required

**PSScriptAnalyzer 1.22+** - the primary linter. Run twice: once with project settings, once with compatibility rules.

```powershell
# Project settings (rules + excludes from .pwsh-review/)
Invoke-ScriptAnalyzer `
    -Path . `
    -Recurse `
    -Settings .pwsh-review/PSScriptAnalyzerSettings.psd1 `
    -ReportSummary

# Compatibility rules (separate run because the settings differ)
$compatSettings = @{
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable = $true
            TargetVersions = @('7.4')
        }
        PSUseCompatibleCmdlets = @{
            Enable = $true
            compatibility = $config.Platforms
        }
        PSUseCompatibleCommands = @{
            Enable = $true
            TargetProfiles = $config.Platforms
        }
        PSUseCompatibleTypes = @{
            Enable = $true
            TargetProfiles = $config.Platforms
        }
    }
}
Invoke-ScriptAnalyzer -Path . -Recurse -Settings $compatSettings
```

The two runs combine into one PSScriptAnalyzer findings array.

**Pester 5.5+** - test runner. Skip if no tests are touched, or run with `-Output None` and only emit summary if all tests pass.

```powershell
$config = New-PesterConfiguration
$config.Run.Path = 'tests'
$config.Run.PassThru = $true
$config.Output.Verbosity = 'None'
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = $changedPwshFiles
Invoke-Pester -Configuration $config
```

The reviewer cares about: pass/fail count, failed test names, coverage delta on changed files (compare to the same calc from `git stash` of the pre-change state).

### Recommended

**InjectionHunter** - PSScriptAnalyzer custom rules for injection vulnerabilities.

```powershell
$injectionHunterPath = (Get-Module InjectionHunter -ListAvailable | Select-Object -First 1).Path
Invoke-ScriptAnalyzer `
    -Path . `
    -Recurse `
    -CustomRulePath $injectionHunterPath `
    -RecurseCustomRulePath
```

Findings merge into the PSScriptAnalyzer array but tag with `source: "injection_hunter"` so agents can distinguish.

**Gitleaks** - secret scanner. Runs against the diff (faster) and against working-tree config files.

```powershell
gitleaks protect --staged --report-path .pwsh-review/cache/gitleaks.json --report-format json --no-banner
gitleaks detect --source . --report-path .pwsh-review/cache/gitleaks-full.json --report-format json --no-banner --no-git
```

Skip cleanly if `gitleaks` is not on `$PATH`. Note the absence in the static-findings output so agents do not assume secret-free.

### Optional

**markdownlint-cli2** - on changed `.md` files only.
**actionlint** - on changed `.github/workflows/*.yml`.
**editorconfig-checker** - on all changed text files. Catches whitespace and line-ending drift.
**PSCodeHealth** - maintainability metrics. Slow; run only if explicitly enabled in `config.psd1`.

## Parallelism

The static tools are independent. Run as parallel pwsh jobs:

```powershell
$jobs = @(
    Start-ThreadJob -Name PSSA-Project -ScriptBlock { ... }
    Start-ThreadJob -Name PSSA-Compat -ScriptBlock { ... }
    Start-ThreadJob -Name InjectionHunter -ScriptBlock { ... }
    Start-ThreadJob -Name Gitleaks -ScriptBlock { ... }
    Start-ThreadJob -Name Pester -ScriptBlock { ... }
)
$results = $jobs | Wait-Job | Receive-Job
```

Use `Start-ThreadJob` not `Start-Job`. Thread jobs share the process so module loading is cheap.

## Caching

Per-file cache keyed by SHA256 of file contents:

```
.pwsh-review/cache/static/
├── <hash>.psanalyzer.json
├── <hash>.injectionhunter.json
└── <hash>.gitleaks.json
```

Before running each tool on a file, check if the cache entry exists. If yes, load from cache. Saves the ~80% of files that did not change in this PR.

Pester results are cached per test file hash plus dependencies. If a tested function changed, its tests re-run; if neither the test nor any function it touches changed, reuse the cached result.

## Output schema

The static phase emits a single JSON file `.pwsh-review/cache/static-findings.json`:

```json
{
  "schema_version": "1",
  "generated": "<ISO timestamp>",
  "psscriptanalyzer": [
    {
      "rule_name": "PSAvoidUsingWriteHost",
      "severity": "Warning",
      "file": "src/Foo.ps1",
      "line": 42,
      "column": 5,
      "message": "File 'Foo.ps1' uses Write-Host. ...",
      "suggested_corrections": [...]
    }
  ],
  "compatibility": [
    {
      "rule_name": "PSUseCompatibleCmdlets",
      "severity": "Warning",
      "file": "...",
      "line": 12,
      "message": "The cmdlet 'Get-CimInstance' is not available...",
      "platform": "core-7.4-linux"
    }
  ],
  "injection_hunter": [...],
  "gitleaks": [
    {
      "rule_id": "generic-api-key",
      "file": "...",
      "line": 7,
      "secret": "<redacted>",
      "commit": "<sha>"
    }
  ],
  "pester": {
    "ran": true,
    "total": 142,
    "passed": 140,
    "failed": 2,
    "failed_tests": [
      {
        "name": "Get-Worktree returns array when multiple",
        "file": "tests/Get-Worktree.Tests.ps1",
        "line": 33,
        "error_message": "..."
      }
    ],
    "coverage": {
      "before": 84.2,
      "after": 83.8,
      "delta": -0.4,
      "uncovered_in_diff": [
        "src/Foo.ps1:55-58",
        "src/Bar.ps1:120"
      ]
    }
  },
  "markdownlint": [...],
  "actionlint": [...],
  "editorconfig": [...],
  "tools_missing": ["gitleaks"]
}
```

Agents read this file at the start of their work. The merger script appends the contents to the final review output under "Static analysis".

## Severity mapping

PSScriptAnalyzer severities map to our severity scale as follows:

| PSScriptAnalyzer | Our severity (default) |
| ---------------- | ----- |
| `Error`          | `blocker` |
| `Warning`        | `major` |
| `Information`    | `minor` |
| `ParseError`     | `blocker` |

The mapping is overridable in `config.psd1`:

```powershell
StaticSeverityMap = @{
    'Warning' = 'minor'  # downgrade if your project has many warnings
}
```

Gitleaks findings are always `blocker`. InjectionHunter findings are always `blocker` or `major` depending on rule.

## Failure handling

If a tool crashes, capture the stderr and emit:

```json
{
  "<tool_name>": {
    "status": "error",
    "error": "<stderr>"
  }
}
```

Continue with the remaining tools. Surface the failure in the final review as a `question` finding: "Static tool X failed: ..., review may be incomplete."

If PSScriptAnalyzer itself fails to parse a file, emit a `blocker` finding for that file (it is broken pwsh) and continue.

## Configuration

Project-level `PSScriptAnalyzerSettings.psd1` controls rules. The plugin's template includes a starter set; bootstrap merges with detected project conventions.

The plugin never modifies the project's PSScriptAnalyzer settings. If the user wants stricter rules, they edit `.pwsh-review/PSScriptAnalyzerSettings.psd1` directly.

## When to skip

The whole static phase can be skipped with `--skip-static` for diagnostics. Should rarely be used. Default is always: run static first, agents second.
