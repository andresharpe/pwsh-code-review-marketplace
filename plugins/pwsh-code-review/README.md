# pwsh-code-review

Multi-agent code review for PowerShell 7+ projects. Cross-platform aware, diff-focused, deterministic-first.

Built to outperform generalist reviewers (Copilot, Cursor, base Claude) on PowerShell specifically by combining a deterministic static-analysis pre-pass with five specialised agents that share a project profile. Designed to run in Claude Code as a plugin, but the scripts under `scripts/` are pure pwsh 7+ and run anywhere.

## What it does

On every pull request or set of staged changes, the plugin:

1. Runs a deterministic static-analysis pass (PSScriptAnalyzer with project settings, InjectionHunter, Gitleaks, Pester) and captures findings as ground truth.
2. Computes a diff context: which functions changed, who calls them, who they call, which tests reference them. Walks the repo via PowerShell AST, not text search.
3. Loads the project profile (`architecture.md`, `standards.md`, `patterns/`, `glossary.md`) so the agents reason against project-specific intent, not generic pwsh.
4. Dispatches five agents in parallel: conventions, pwsh idioms, diff bugs, security, history.
5. Each finding gets a confidence score (0-100) and a severity (`blocker`, `major`, `minor`, `nit`, `question`, `praise`).
6. A calibrator pass reviews the agents' own ratings to prevent inflation.
7. Findings are filtered, grouped, and emitted as a single review.

The static layer is ground truth: agents never re-flag what PSScriptAnalyzer or Gitleaks already caught.

## Why it beats Copilot for PowerShell

Copilot is a generalist. This is a specialist. Specifically:

- **Deterministic linters bundled with AI.** PSScriptAnalyzer findings feed the agents as known-bad, so the AI never spends its budget on lint-class issues.
- **Cross-platform pwsh 7+ is a first-class concern.** Path separators, native command argument passing, encoding, line endings, platform-gated cmdlets all have explicit checks.
- **Project profile.** The reviewer knows what your code is supposed to look like (`architecture.md`, `patterns/`), not just what is idiomatic in pwsh generally.
- **Diff-first context.** AST-based call graph keeps the reviewer focused on changed lines plus their immediate neighbourhood. No drive-by comments on unchanged code.
- **Severity + confidence.** A two-axis filter prevents the wall-of-comments problem.

## Quick start

```bash
# 1. Add the marketplace (one-time, from the marketplace directory's parent)
/plugin marketplace add ./pwsh-code-review-marketplace

# 2. Install the plugin
/plugin install pwsh-code-review@pwsh-code-review-marketplace

# 3. From inside your PowerShell project repo, bootstrap the project profile
/pwsh-review-bootstrap

# 4. Review staged or PR changes
/pwsh-review                  # review uncommitted/staged changes, output to terminal
/pwsh-review --pr 42          # review PR #42 via gh CLI
/pwsh-review --comment        # post results as PR comment
```

## Bootstrap workflow

The bootstrap is a one-time per-repo step that creates the project profile under `.pwsh-review/`. It runs an exploration agent that walks the repo, infers structure, and drafts these files:

```
.pwsh-review/
├── architecture.md       # module boundaries, dependency direction, public surface
├── standards.md          # project rules beyond PSScriptAnalyzer defaults
├── glossary.md           # domain terms the reviewer should not "fix"
├── patterns/             # canonical examples ("this is how we do X")
│   ├── pattern-pipeline-cmdlet.ps1
│   ├── pattern-error-handling.ps1
│   └── pattern-module-init.psm1
├── PSScriptAnalyzerSettings.psd1   # project linter config
└── profile.lock.json     # hashes used to detect when the profile is stale
```

You review the drafts, edit, commit. Subsequent reviews load these as system context. A freshness check on every review flags drift (new top-level modules, manifest changes, public surface deltas) so the profile gets refreshed deliberately rather than rotting.

See `skills/pwsh-review-bootstrap/SKILL.md` for the full bootstrap procedure.

## Layout

```
pwsh-code-review/
├── .claude-plugin/plugin.json       # plugin manifest
├── commands/
│   ├── pwsh-review.md               # /pwsh-review orchestrator
│   └── pwsh-review-bootstrap.md     # /pwsh-review-bootstrap orchestrator
├── agents/                           # the five reviewers + the calibrator
│   ├── conventions-agent.md
│   ├── pwsh-idioms-agent.md
│   ├── diff-bug-agent.md
│   ├── security-agent.md
│   ├── history-agent.md
│   └── calibrator-agent.md
├── skills/                           # auto-loaded knowledge packages
│   ├── pwsh-review-bootstrap/SKILL.md
│   ├── pwsh-static-analysis/SKILL.md
│   └── pwsh-ast-context/SKILL.md
├── scripts/                          # deterministic, pure pwsh 7+
│   ├── Invoke-StaticAnalysis.ps1
│   ├── Get-DiffContext.ps1
│   ├── Get-AstIndex.ps1
│   ├── Initialize-ReviewProfile.ps1
│   └── Merge-Findings.ps1
├── templates/                        # copied into the target repo on bootstrap
│   ├── PSScriptAnalyzerSettings.psd1
│   ├── architecture.md
│   ├── standards.md
│   ├── glossary.md
│   └── patterns/...
└── docs/
    ├── principles.md                 # universal code-quality principles
    └── severity-rubric.md            # severity + confidence scoring rules
```

## Requirements

- PowerShell 7.4 or later (cross-platform)
- Git
- GitHub CLI (`gh`) for PR mode
- Claude Code

The plugin auto-installs PowerShell modules on first run:

- `PSScriptAnalyzer` (1.22.0+)
- `InjectionHunter`
- `Pester` (5.5+)
- `PSCodeHealth` (optional)

External tools the bootstrap will look for and use if present:

- `gitleaks` (recommended)
- `markdownlint-cli2`
- `actionlint`
- `editorconfig-checker`

## Performance budget

Target for a 500-line PR on a warm cache:

| Phase                          | Target |
| ------------------------------ | ------ |
| Static analysis (parallel)     | 30s    |
| AST index refresh              | 5s     |
| Five agents in parallel        | 60-90s |
| Calibrator + merge             | 10s    |
| **Total**                      | ~2 min |

The cache is keyed by file hash. The first review on a fresh repo is slow; everything after reuses the AST index.

## Configuration

`/pwsh-review` accepts options that map to environment-style overrides. A repo can also commit `.pwsh-review/config.psd1` to set defaults.

```powershell
# .pwsh-review/config.psd1
@{
    ConfidenceThreshold = 80    # findings below this are dropped (default 80)
    NitCap              = 3     # max nits per review (default 3)
    Platforms           = @('core-7.4-windows', 'core-7.4-linux', 'core-7.4-macos')
    SkipAgents          = @()   # e.g. @('history') to skip specific agents
    StaticAnalysisOnly  = $false
}
```

## Output format

Findings render as Markdown grouped by severity, then by file. Each has:

- Severity tag (`[blocker]`, `[major]`, `[minor]`, `[nit]`, `[question]`, `[praise]`)
- Confidence score
- File and line range
- One-sentence problem statement
- One-sentence consequence
- Suggested fix (snippet where possible)

Example:

```
## Code review

### blocker (1)

**[blocker] (95) `src/Modules/DotbotCore/Public/New-Worktree.ps1:42-48`**
Removed `[ValidateNotNullOrEmpty()]` from `-Path` parameter. Callers in
`server.ps1:120` and `tests/New-Worktree.Tests.ps1:55` rely on the validation
to fail fast; without it, an empty path will reach `Join-Path` and produce
a confusing PathTooLong error.

Fix: restore the validation attribute.

### major (2)
...

### minor (1)
...
```

## Reading order for contributors

1. `docs/principles.md` - the universal rules
2. `docs/severity-rubric.md` - how findings are rated
3. `commands/pwsh-review.md` - the orchestrator
4. `agents/*.md` - the five agents and the calibrator
5. `skills/pwsh-ast-context/SKILL.md` - how diff context is computed
6. `skills/pwsh-static-analysis/SKILL.md` - how the deterministic pass runs

## Licence

MIT.
