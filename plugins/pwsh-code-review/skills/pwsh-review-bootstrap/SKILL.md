---
name: pwsh-review-bootstrap
description: How to bootstrap a PowerShell project with pwsh-code-review. Use when the user is setting up the reviewer on a new repo, when /pwsh-review-bootstrap runs, or when the existing profile needs refreshing.
---

# pwsh-review bootstrap skill

This skill is invoked by `/pwsh-review-bootstrap`. It contains the procedure for walking a PowerShell repo, generating the project profile, and producing a usable starting point.

## What "good bootstrap" looks like

The user runs the bootstrap once. They get back a `.pwsh-review/` directory with files that:

- Reflect the actual project (not generic templates)
- Are honest about uncertainty (mark `<!-- TODO -->` where unsure)
- Make the user's first edits cheap (the right structure, just needs hand-curation)
- Do not break or trigger spurious findings on first review

Bad bootstrap looks like: generic boilerplate, made-up architecture descriptions, hallucinated function lists, glossary terms with invented definitions. Avoid this aggressively.

## Walk procedure

### Inventory pass

```powershell
$psFiles = Get-ChildItem -Recurse -File -Include *.ps1, *.psm1, *.psd1
```

For each file, classify:

- `.psd1` with `RootModule` set: module manifest
- `.psd1` without `RootModule`: data file (like our config files)
- `.psm1`: module
- `.ps1` in `tests/` or matching `*.Tests.ps1`: Pester test
- `.ps1` in `Public/`: public function file
- `.ps1` in `Private/`: private function file
- `.ps1` at root or `scripts/`: entry script

Build a table:

```
File | Role | Lines | Functions defined | Functions called externally
```

### AST pass

For each file, parse with `[System.Management.Automation.Language.Parser]::ParseFile`. Extract:

- All `FunctionDefinitionAst`
- All `CommandAst` (function/cmdlet calls)
- All `VariableExpressionAst` for `$script:`, `$global:`, `$env:`
- All `AssignmentStatementAst` writing to those scopes
- Module manifest contents via `Import-PowerShellDataFile`

Identify cross-platform signals by scanning for:

- Hard-coded `\` in string literals representing paths
- `Get-CimInstance`, `Get-WmiObject`, `Get-ItemProperty 'HKLM:..'`, `New-PSDrive -PSProvider Registry`
- `$env:USERPROFILE`, `$env:APPDATA`, `$env:LOCALAPPDATA`, `$env:PROGRAMFILES`
- `powershell.exe` references
- `$IsWindows`, `$IsLinux`, `$IsMacOS` references (good signal: project is platform-aware)
- `New-Object -ComObject`, `[System.__ComObject]`
- `Test-NetConnection`, `Get-NetAdapter`, `*-Service`, etc.

Identify dependencies:

- Module manifest `RequiredModules`
- `Import-Module` calls
- `using module` statements
- Native command invocations (`& <name>` where `<name>` is not a function)

### Pattern detection

Look for the cleanest existing example of each canonical pattern:

**`pattern-pipeline-cmdlet.ps1`**: search for `FunctionDefinitionAst` where:
- Has `[CmdletBinding()]`
- Has `[OutputType()]`
- Has at least one parameter with `ValueFromPipeline = $true`
- Has a `process` block
- Has comment-based help with at least synopsis, description, parameter, example

Score each candidate by:
- 5 points for `[OutputType()]` matching what is actually returned
- 3 points for `SupportsShouldProcess` if state-changing
- 3 points for proper error handling pattern
- 2 points for length under 60 lines
- -10 points if it has obvious issues (Write-Host in a non-CLI module, `+=` in a loop)

Pick the highest-scoring candidate. Copy verbatim with a header comment:

```powershell
# Canonical example from <relative-path>
# Picked because: pipeline-shaped, OutputType honest, CBH complete
```

If no candidate scores above zero, copy the template version.

**`pattern-error-handling.ps1`**: search for the cleanest existing function that uses `try/catch` with `Write-Error -ErrorAction Stop` (not bare `throw "string"`), distinguishes terminating from non-terminating, and has a justifying comment.

**`pattern-module-init.psm1`**: search for the cleanest `.psm1` that does dot-source loading of `Public/` and `Private/`, calls `Export-ModuleMember` correctly, and handles errors during load.

### Glossary detection

Walk all source files and extract identifiers (function names, parameter names, comment words) that:

- Appear 5+ times across the codebase
- Are not in standard pwsh vocabulary
- Are not in standard English (a small stopword list)
- Look domain-specific (e.g. uppercase project nouns: `DOTBOT`, `Worktree`, `Whisper`, `Outpost`)

Take the top 20. For each, find the first definition or descriptive use in a README or `.SYNOPSIS` block. Draft a glossary entry:

```markdown
### Term

<!-- TODO: confirm definition -->
<inferred definition from first descriptive use, or "Domain term used in <count> places, definition not auto-inferable">

Used in: file:line, file:line, file:line
```

The user fills in or corrects. Never invent definitions.

### Public surface

From the module manifests' `FunctionsToExport` (if not `'*'`), build the list of public functions. If `FunctionsToExport = '*'`, fall back to: every function defined in a `Public/` directory, or every function whose file matches the function name.

For each public function, capture:

- Signature (parameters, types, attributes)
- Output type (declared and inferred)
- Comment-based help completeness
- Caller count within the repo

This goes into `architecture.md` and `profile.lock.json`.

## File generation rules

### `architecture.md`

Honest. Where uncertain, leave a TODO. Do not write paragraphs of generic prose about how "this project follows clean architecture". Stick to facts you can verify from the code:

- Number of modules
- Module dependency direction (use the AST call graph)
- Public function count
- Test count and Pester version
- Cross-platform signals detected (yes/no for each platform)

### `standards.md`

Start from `templates/standards.md`. Then merge in any rules detected from existing files:

- `.editorconfig`: line endings, indent style, charset
- Existing `PSScriptAnalyzerSettings.psd1`: rule excludes and includes
- `STYLE.md` or `CODING_STANDARDS.md` if present at repo root: copy relevant sections
- `CONTRIBUTING.md`: pull in any "code style" section

If the project has its own conventions that contradict the template, preserve the project's.

### `glossary.md`

20 entries maximum. All marked TODO. If you cannot infer the definition, say so explicitly:

```markdown
### Worktree

<!-- TODO: confirm definition -->
Domain term, appears in 47 places. Not auto-inferable from context.

Used in: src/server.ps1:42, src/Modules/WidgetCore/Public/New-Widget.ps1:1, ...
```

### `patterns/`

Three files minimum (pipeline, error handling, module init). Add more if obvious patterns emerge from the codebase (e.g. a clear "configuration loading" pattern, a clear "logging" pattern).

### `PSScriptAnalyzerSettings.psd1`

Copy `templates/PSScriptAnalyzerSettings.psd1`. Set `Rules.PSUseCompatibleSyntax.TargetVersions` based on the lowest `PowerShellVersion` in any manifest, or 7.4 if no manifest. Set `Rules.PSUseCompatibleCmdlets.compatibility` based on detected platforms.

### `config.psd1`

Set `Platforms` based on detection. Default `ConfidenceThreshold` to 80, `NitCap` to 3.

### `profile.lock.json`

Schema:

```json
{
  "version": "1",
  "generated": "<ISO timestamp>",
  "public_surface": {
    "<function-name>": {
      "signature_hash": "<sha256>",
      "file": "<relative-path>"
    }
  },
  "manifests": {
    "<relative-path>": {
      "hash": "<sha256>",
      "version": "<from manifest>"
    }
  },
  "top_dirs": {
    "<dir>": "<sha256 of sorted file list>"
  },
  "ruleset_version": "1"
}
```

The freshness check on every review compares this against the current state.

## Refresh mode behaviour

`--refresh` regenerates intelligently:

- Re-run discovery and pattern detection.
- For each file in `.pwsh-review/`, compute a structural diff between the new version and the existing.
- For `architecture.md`, `standards.md`: show the user a section-by-section diff and ask which to apply. Default: apply factual updates (counts, lists), preserve prose edits.
- For `glossary.md`, `patterns/*.ps1`: never overwrite. These are hand-curated. Just print "Skipped, hand-curated."
- For `PSScriptAnalyzerSettings.psd1`: if the user has not modified it (matches the original generated version), update freely. If modified, show diff and ask.
- For `profile.lock.json` and `cache/`: always regenerate.

## Force mode

`--force` overwrites everything except cache. One confirmation prompt: "This will overwrite all hand edits in `.pwsh-review/`. Type 'overwrite' to confirm:". Anything other than exact match aborts.
