# Architecture

The high-level shape of `pwsh-code-review-marketplace`. Every reviewer agent loads this so it can check changes against project intent.

## Project shape

Single-plugin Claude Code marketplace. The repo ships one plugin, `pwsh-code-review`, under `plugins/pwsh-code-review/`. There is no PowerShell module in the traditional sense -- the deliverables are agent prompts (markdown), static analysis scanners (PowerShell scripts), self-test fixtures, and a slash-command pipeline definition.

Every push to `main` auto-bumps a minor version tag via `.github/workflows/version-bump.yml`. The operator does not bump versions in PRs.

## Module map

| Surface | Path | Purpose |
| ------- | ---- | ------- |
| Agent prompts | `plugins/pwsh-code-review/agents/*.md` | Per-agent instruction files (conventions, pwsh-idioms, diff-bug, security, history, markdown-content, js-content, calibrator) |
| Static scanners | `plugins/pwsh-code-review/scripts/Test-*.ps1` | Heuristic AST scanners (`Test-Brittleness.ps1`, `Test-Coverage.ps1`, `Test-TemplateSubstitution.ps1`) |
| Pipeline scripts | `plugins/pwsh-code-review/scripts/{Invoke,Get,Merge,Post,Resolve,Initialize}-*.ps1` | Orchestration: static analysis, diff context, prior reviews, profile resolution, finding merge, PR review posting |
| Self-test fixtures | `plugins/pwsh-code-review/scripts/Tests-*/Run.ps1` + `R<n>-*.Tests.ps1` | Fixture harnesses pinning scanner / merger / posting behavior |
| Slash commands | `plugins/pwsh-code-review/commands/*.md` | `pwsh-review` (review pipeline) and `pwsh-review-bootstrap` (profile setup) |
| Skills | `plugins/pwsh-code-review/skills/*/SKILL.md` | Reusable subroutines for the pipeline |
| Docs | `plugins/pwsh-code-review/docs/*.md` | `principles.md` (universal rules) and `severity-rubric.md` (filter matrix) |
| Templates | `plugins/pwsh-code-review/templates/*` | Profile-bootstrap starters consumed by `pwsh-review-bootstrap` |

## Dependency direction

The pipeline scripts compose left-to-right:

```
Invoke-StaticAnalysis.ps1 -> static-findings.json
Get-DiffContext.ps1       -> diff-context.json
Get-PriorReviews.ps1      -> prior-reviews.json (when --pr)
        |
        v
agents (parallel dispatch, each reads the JSONs)
        |
        v
calibrator
        |
        v
Merge-Findings.ps1 -> merged-findings.json + review.md
        |
        v
Post-PrReview.ps1 -> single GitHub review with per-finding comments (when --comment)
```

Reverse dependencies (e.g. an agent file calling out to a script) are blockers. Agents read JSON only.

## Public surface

This repo has no exported PowerShell module surface. The "public" surface is:

- The `pwsh-review` and `pwsh-review-bootstrap` slash commands (and their flags).
- The agent prompt names (used in `--skip` arguments).
- The rule namespaces emitted to `merged-findings.json`: `PWSH-CONV-`, `PWSH-LANG-`, `PWSH-DIFF-`, `PWSH-SEC-`, `PWSH-HIST-`, `PWSH-MD-`, `PWSH-JS-`, `PWSH-TEST-`, `PWSH-COV-`, `PWSH-TPL-`.
- The cache file shapes under `.pwsh-review/cache/*.json` (consumed by external tooling).

Renaming any of these is a breaking change requiring deprecation. The auto-bump workflow does not detect this -- the operator must remember.

## Side-effect boundary

I/O happens in a small set of scripts. Agent prompts and templates are pure data.

- `Invoke-StaticAnalysis.ps1` reads the working tree, runs PSScriptAnalyzer / Pester / external linters, writes JSON.
- `Get-DiffContext.ps1` reads git diff + the AST index, writes diff-context JSON.
- `Get-PriorReviews.ps1` calls `gh api graphql`, writes prior-reviews JSON.
- `Merge-Findings.ps1` reads JSONs, writes `review.md` + `merged-findings.json`.
- `Post-PrReview.ps1` calls `gh api`, posts the review.
- `Initialize-ReviewProfile.ps1` writes a templated `.pwsh-review/` to a target repo.
- `Resolve-Profile.ps1` reads from `git show <baseRef>:` to recover a profile from a base ref.
- `Test-*.ps1` scanners read source files, return findings (no writes).

A new write outside this set merits a finding under `PWSH-DIFF-302` (write-without-read) unless explicitly justified.

## External dependencies

### PowerShell modules

| Module | Min version | Purpose |
| ------ | ----------- | ------- |
| PSScriptAnalyzer | 1.x | Static analysis core |
| Pester | 5.x | Fixture harness in `Tests-*/` |
| InjectionHunter | (custom) | Optional security-rule extension |

### Native commands assumed on PATH

| Command | Purpose | Platforms |
| ------- | ------- | --------- |
| `git` | Diff context, blame, log | all |
| `gh` | All GitHub interaction (PR fetch, review post, prior reviews) | all |
| `pwsh` | The plugin runs under PowerShell 7 | all |

Optional, silently degraded if absent: `gitleaks`, `markdownlint`, `actionlint`, `editorconfig-checker`, `eslint`.

## Target platform

- pwsh: 7.4+
- editions: Core only (Desktop edition is not supported)
- OS: Windows + Linux are gated; macOS is expected to work but not part of CI

## Build and test

- No build step -- files are consumed in place by the Claude Code plugin runtime.
- Self-tests: `pwsh -File plugins/pwsh-code-review/scripts/Tests-<Name>/Run.ps1`. Each fixture dir is independent. There is no aggregate runner today.
- CI: `.github/workflows/version-bump.yml` (auto-bump) is in place today. `.github/workflows/pwsh-review.yml` (static-only review on every PR) is planned for PR-F and is not present yet.
- Release: every push to `main` is auto-tagged `v(N+1).0.0` minor by the bump workflow. PRs do not bump versions.

## Conventions specific to this project

- Agent prompt files (`agents/*.md`) follow the shape pinned in `patterns/pattern-agent-prompt.md`: frontmatter, a short title, `## Inputs`, `## Scope` (with "you own" / "you do not own"), then named rule sections, then `## Output` and `## Calibration discipline`.
- Scanner scripts (`scripts/Test-*.ps1`) follow the shape pinned in `patterns/pattern-scanner.ps1`: a `$script:Rules` table, per-rule `Test-RuleNNN` predicates, a single `Invoke-FileScan` driver.
- Self-test fixtures (`Tests-<Name>/`) follow `patterns/pattern-fixture.ps1`: one `R<n>-<Name>.Tests.ps1` per rule, plus `Negative-*.Tests.ps1` clean cases, plus `Run.ps1` asserting each fixture fires its expected rule and the negatives stay clean.
- Severity-rubric vocabulary is fixed: `blocker`, `major`, `minor`, `nit`, `question`, `praise`. New severities are a breaking change.
- Rule IDs use `PWSH-<AGENT>-NNN` where NNN is zero-padded. Once published, never reused. New rules allocate the next free number.
