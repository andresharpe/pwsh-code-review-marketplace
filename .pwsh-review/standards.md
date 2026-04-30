# Standards

The rulebook the reviewer enforces against this repo. Every `minor` finding from the conventions agent must point to a section here. If a rule is not in this file, the agent will at most flag it as a `nit`.

This is the project's own profile, dogfooded so the plugin reviews itself before every push to `main`.

## Naming

- PowerShell function names use approved verbs (`Get-Verb`).
- Cmdlet nouns are singular.
- Variable names describe what the variable holds, not how it was computed. `$findings` not `$result`.
- Boolean parameters are `[switch]` not `[bool]`.
- Rule IDs are `PWSH-<AGENT>-NNN` zero-padded. Each rule's ID is allocated once and never reused.

## Function shape

This repo has no public-module surface; most scripts are top-level entry points or pipeline composition. Even so:

- Top-level scripts (`scripts/*.ps1`) start with `#requires -Version 7.4`, set `$ErrorActionPreference = 'Stop'`, and `Set-StrictMode -Version 3.0`.
- Functions inside scripts use `[CmdletBinding()]` when they take parameters.
- Functions that return data declare `[OutputType()]` matching what they actually emit.
- Comment-based help is required only on the top-level script's outermost help block (`<# .SYNOPSIS ... #>`); per-function help is not required for internal helpers.
- `[Parameter()]` attributes on every script parameter.
- `[ValidateSet()]` / `[ValidateNotNullOrEmpty()]` for inputs from a fixed set.
- `process` blocks when `ValueFromPipeline` is declared.

## Error handling

- `try/catch` only where the catch can do something meaningful. Empty `catch { }` is forbidden.
- Throw with `Write-Error -ErrorAction Stop -Category <Specific> -ErrorId <Stable>` from production code; bare `throw "string"` is acceptable in scanners and fixtures only.
- Do not use `-ErrorAction SilentlyContinue` without an inline `# why: ...` comment within one line of the call.
- Do not use `-ErrorAction Ignore`; it discards the error from `$Error` entirely. Use `SilentlyContinue` plus a justification comment.
- Probe-cmdlet exemptions: `Test-Path`, `Get-Command`, `Get-Module`, `Get-Variable`, and `Get-Item -Path Variable:*` / `Function:*` / `Alias:*` may use `-EA SilentlyContinue` without a justification comment -- suppression is the standard idiom for those.

## Output discipline

- One output type per function. No mixed types across branches.
- Pipeline scripts emit progress through `Write-Information` so callers can opt in via `-InformationAction Continue` or `6>&1`. Bare `Write-Host` is reserved for `Tests-*/Run.ps1` test runners (terminal-only, operator-facing).
- `Write-Verbose` is for debug-only diagnostics gated behind `-Verbose`.
- `Write-Warning` is for recoverable problems.
- The `merged-findings.json` schema is the only structured output across script boundaries. Other scripts emit hashtables only.

## Cross-platform

This project targets Windows + Linux (CI runs both). The following are blockers:

- Hard-coded `\` in path strings. Use `Join-Path` or `[IO.Path]::Combine`.
- Hard-coded `/` in path strings, except for URLs.
- Use of `$env:USERPROFILE`, `$env:APPDATA`, `$env:LOCALAPPDATA` without an `$IsWindows` guard. Prefer `$HOME`.
- Use of `Get-CimInstance`, `Get-WmiObject`, registry cmdlets without an `if ($IsWindows)` guard.
- Invocation of `powershell.exe` instead of `pwsh`.

## Pipeline correctness

- Functions accepting pipeline input have a `process` block.
- The comma trick (`,$result`) is required when a function returning a single object is consumed by a caller iterating with `foreach`.
- `ConvertFrom-Json -AsHashtable` consumed without `@(...)` wrapping is a finding -- single-element JSON arrays return a hashtable, not an `[object[]]`.

## Strict mode

Every entry script sets `Set-StrictMode -Version 3.0`. Findings that the static layer or `pwsh-idioms-agent` raise under strict mode (unset variables, non-existent property access, single-element-array unwrap, here-string `\$` semantics, `$Matches` clobber on nested regex) are real bugs in this codebase, not cosmetic.

## Concurrency

- No `$global:` writes; `$script:` is acceptable in scanner scripts to hold the rule table and AST helpers, but never written to from an `It` block or a parallel scope.
- No `ForEach-Object -Parallel` in agent dispatch -- the orchestration is sequential by design.

## Security defaults

- No plaintext credentials in code, parameters, or fixtures. `gitleaks` runs on every commit.
- No `Invoke-Expression` on data from a parameter, file, or environment. The pipeline composes via PowerShell call sites and `gh api`, never via `iex`.
- Native command arguments passed in array form: `& gh api $endpoint --jq $query`, never `& gh "api $endpoint"`.
- All `gh api` calls that build JSON payloads write to a UTF8NoBOM tempfile and post via `gh api --input <file>`. Never pipe JSON through bash `echo` or `printf`.

## Testing

- Pester 5+ for fixtures.
- One `R<n>-<Name>.Tests.ps1` per scanner rule under `scripts/Tests-<Name>/`.
- Each `Run.ps1` asserts (a) every positive fixture fires the expected rule at least once, (b) the negative fixtures stay clean, (c) no cross-rule leak (a fixture's rule must match its file's expected rule).
- Tests describe behaviour. Do not mock the function under test.

### Test brittleness

The reviewer flags brittle assertion patterns under `PWSH-TEST-NNN`. See the canonical scanner at `plugins/pwsh-code-review/scripts/Test-Brittleness.ps1` for current rules. Fixtures live under `scripts/Tests-TestBrittleness/`.

## File hygiene

- UTF-8 without BOM (Core only; we do not target Desktop edition).
- LF line endings (configured via `.gitattributes`).
- No tabs in pwsh files.
- No trailing whitespace.
- Max line length 140.
- No `;` as line terminator.

## Auto-bump workflow contract

`.github/workflows/version-bump.yml` runs on every push to `main` and tags a new minor version `v(N+1).0.0`. PRs MUST NOT modify `version` fields in plugin manifests; the bump workflow owns that. A PR that touches a version field is a finding (`PWSH-CONV-NNN`, `major`, conf 90).

## Agent prompt formatting

Agent files (`agents/*.md`) follow the shape pinned in `patterns/pattern-agent-prompt.md`. Sections appear in this order:

1. Frontmatter (`name`, `description`)
2. `# <Title> agent` (one-line summary follows)
3. `## Inputs`
4. `## Scope` with "You own" and "You do **not** own" lists
5. Named rule sections (one heading per rule cluster)
6. `## Output` (rule-namespace declaration)
7. `## Calibration discipline`

Adding a section out of order or omitting one of these is a finding.

## Scanner script formatting

Scanner files (`scripts/Test-*.ps1`) follow `patterns/pattern-scanner.ps1`:

- `#requires -Version 7.4` first line.
- Comment-based help block.
- `[CmdletBinding()]` and `[OutputType([object[]])]` on the script.
- `$ErrorActionPreference = 'Stop'` and `Set-StrictMode -Version 3.0` immediately after `param()`.
- `$script:Rules` hashtable holding `RuleID -> @{ Severity; Confidence }`.
- One `Test-RuleNNN` predicate function per rule.
- `Invoke-FileScan` walks the AST, dispatches each rule predicate.
- `New-Finding` helper builds the result hashtable.

## Documentation

- Every new rule (in any agent or scanner) appears in the rule's owning file's prompt or `$script:Rules` table. The reviewer flags out-of-band rules.
- The `ideas/reviewer-gap-analysis.md` self-improvement-loop log is updated when a fix-PR closes a gap. Each fix-PR drains the corresponding line from "Recently observed gaps" and appends to "Closed gaps".

## Deviations

None at this time. Document any project-specific deviation here, with rationale.
