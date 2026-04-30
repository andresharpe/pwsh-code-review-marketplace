# Contributing

Thanks for considering a contribution. The plugin lives under `plugins/pwsh-code-review/`; the rest of the repo is the marketplace shell.

## Local review (dogfood)

This repo dogfoods its own plugin. Every push goes through a static-only review locally before it leaves your machine, and the same review runs in CI on every PR.

### Setup

Enable the local pre-push hook once per clone:

```bash
git config core.hooksPath .githooks
```

The hook lives at `.githooks/pre-push` and runs `Invoke-LocalReview.ps1` against the working tree before each push. It refuses the push when the verdict is `needs rework` (any blocker present) and warns but allows on `fix majors first`.

Bypass for a one-off (e.g. emergency revert):

```bash
git push --no-verify
```

### Manual run

You can run the review at any time without pushing:

```bash
pwsh ./Invoke-LocalReview.ps1
```

That executes:

1. `plugins/pwsh-code-review/scripts/Invoke-StaticAnalysis.ps1 -All` (PSScriptAnalyzer, Pester, optional external linters).
2. `plugins/pwsh-code-review/scripts/Merge-Findings.ps1` (computes verdict).
3. Reads the verdict from `.pwsh-review/cache/merged-findings.json` and exits 0 (`ship` / `fix majors first`) or 1 (`needs rework`).

The full review markdown lands at `.pwsh-review/cache/review.md`.

### Deeper review (agent dispatch)

`Invoke-LocalReview.ps1` runs the static layer only. For the deeper agent layer (conventions, pwsh-idioms, diff-bug, security, history, markdown-content, js-content), invoke the slash command from Claude Code:

```
/pwsh-review --branch <your-branch>
```

That dispatches all eight reviewer agents in parallel, calibrates their findings, and posts the result to the terminal (or to GitHub with `--comment --pr <n>`).

## CI

`.github/workflows/pwsh-review.yml` runs `Invoke-LocalReview.ps1` on every PR that touches `plugins/**`, `.pwsh-review/**`, or the review entry point itself. The job fails on `needs rework`. Findings are uploaded as artefacts (`pwsh-review-static-findings`) for post-hoc inspection.

CI does not run agents -- agent dispatch needs API budget and an operator to react to `question`-class findings, which is poor fit for a CI job.

## Self-improvement loop

When an external reviewer (Copilot, CodeRabbit, a human) catches something the plugin missed, log it under "Recently observed gaps" in `ideas/reviewer-gap-analysis.md`. Each fix-PR drains the corresponding entry and appends to "Closed gaps" at the bottom.

Stop conditions for the loop are documented at the top of `ideas/reviewer-gap-analysis.md`.

## Auto-bump

The `.github/workflows/version-bump.yml` workflow bumps the minor version on every push to `main` and tags `v(N+1).0.0`. **Do not** modify version fields in PRs -- the workflow owns versioning. A PR that touches a version field is a finding.

## Style

The project's own profile (`.pwsh-review/standards.md`) is the rulebook. Highlights:

- `pwsh` 7.4+ on Windows + Linux. `Set-StrictMode -Version 3.0` and `$ErrorActionPreference = 'Stop'` at the top of every script.
- Approved verbs (`Get-Verb`); singular cmdlet nouns; `[switch]` not `[bool]`.
- One output type per function. `Write-Information` for status, not `Write-Host` (test runners excepted).
- `try/catch` only where the catch can do something. Empty `catch { }` is forbidden.
- `-ErrorAction SilentlyContinue` requires an inline `# why: ...` comment within one line.
- Native command arguments in array form: `& gh api $endpoint`, never `& gh "api $endpoint"`.

See `.pwsh-review/standards.md` for the full list.
