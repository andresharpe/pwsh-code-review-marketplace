---
name: pwsh-review-bootstrap
description: One-time bootstrap for a PowerShell repo. Walks the codebase, drafts the project profile (architecture.md, standards.md, glossary.md, patterns/), copies the linter settings template, and computes the initial AST index. Use this when first installing pwsh-code-review on a project, when the user asks to "set up" or "initialise" the reviewer, or when the existing profile has gone stale and needs regeneration.
---

# /pwsh-review-bootstrap

Creates `.pwsh-review/` for a PowerShell project. Runs once per repo. Subsequent reviews load the profile this command produces.

## Usage

```
/pwsh-review-bootstrap                 # interactive
/pwsh-review-bootstrap --refresh       # update existing profile, preserve hand edits
/pwsh-review-bootstrap --force         # overwrite all files (destructive)
```

## Pre-flight

1. Confirm we are in a git repo with PowerShell content. Walk for `*.ps1`, `*.psm1`, `*.psd1` files. If none, exit with an explanation.
2. Detect existing `.pwsh-review/`. If present and not `--force` or `--refresh`, exit with "Profile already exists. Use --refresh to update or --force to overwrite."

## Phase 1: discovery

Walk the repo. For each PowerShell file, compute:

- File role: script, module, manifest, test, config.
- Module manifest contents: `RootModule`, `FunctionsToExport`, `RequiredModules`, `PowerShellVersion`, `CompatiblePSEditions`.
- Public function inventory (functions in `Public/` directories or listed in `FunctionsToExport`).
- Internal function inventory.
- Pester test inventory.
- Top-level directories and their roles.
- External dependencies (modules required, native commands invoked).
- Cross-platform signals: usage of `$IsWindows`/`$IsLinux`/`$IsMacOS`, `Get-CimInstance`, registry calls, hard-coded path separators, `powershell.exe` invocations.
- Build/CI artefacts: `.github/workflows/`, `azure-pipelines.yml`, `build.ps1`, `psake.ps1`, etc.

Produce an internal report covering:

- Project name (from primary `.psd1` or repo name)
- Architecture pattern detected (single module, multi-module, monorepo, script-only)
- Public surface (count of exported functions, list of public function names)
- Test framework + coverage
- Target pwsh version (lowest required)
- Target platforms (inferred from `CompatiblePSEditions` + cross-platform signals)
- Existing standards detected (from `.editorconfig`, existing `PSScriptAnalyzerSettings.psd1`, `CONTRIBUTING.md`, `STYLE.md`)

## Phase 2: draft profile files

Generate these files. Each is a draft the user is expected to edit and commit.

### `.pwsh-review/architecture.md`

Use the discovery report. Render in this shape:

```markdown
# Architecture

## Project shape

<one paragraph: monolith, multi-module, script collection, etc.>

## Module map

| Module | Path | Public functions | Internal functions | Tests |
| ------ | ---- | ---------------- | ------------------ | ----- |

## Dependency direction

<which modules depend on which, what the dependency rules are>

## Public surface

<list of exported functions, the contract they fulfil>

## Side-effect boundary

<where I/O happens, what is supposed to be pure>

## External dependencies

<modules from PSGallery, native commands assumed on PATH>

## Target platform

- pwsh: <version>
- editions: Core / Desktop / both
- OS: Windows / Linux / macOS

## Build and test

<how to build, how to run tests, what the CI does>
```

If detection is uncertain, mark sections `<!-- TODO: <agent uncertain, please confirm> -->`.

### `.pwsh-review/standards.md`

Copy `templates/standards.md` and fill in detected specifics. Honour any existing `STYLE.md`, `CONTRIBUTING.md`, or `.editorconfig` content already in the repo (incorporate, do not overwrite).

### `.pwsh-review/glossary.md`

Look for domain terms that appear repeatedly in function names, parameter names, comments, and READMEs. Draft entries for the top 10-20. Mark all entries as `<!-- TODO: confirm -->`. Do not invent definitions; if the term is opaque, mark it for the user to fill in.

### `.pwsh-review/patterns/`

Copy `templates/patterns/*.ps1` as starting points. Then look for the actual canonical examples in the codebase:

- `pattern-pipeline-cmdlet.ps1`: pick the cleanest existing advanced function with `process` block, `ValueFromPipeline`, and `[OutputType()]`. Copy it verbatim with a header comment naming the source.
- `pattern-error-handling.ps1`: pick the cleanest existing function with proper try/catch and `Write-Error -ErrorAction Stop`.
- `pattern-module-init.psm1`: pick the cleanest existing module init file.

If no good candidate exists, leave the template version in place with a header comment: `# This is the default template. Replace with a real example from this codebase when one is written.`

### `.pwsh-review/PSScriptAnalyzerSettings.psd1`

Copy from `templates/PSScriptAnalyzerSettings.psd1`. Detect the target platforms and adjust `Rules.PSUseCompatibleSyntax.TargetVersions` and `Rules.PSUseCompatibleCmdlets.compatibility` accordingly.

### `.pwsh-review/config.psd1`

Generate based on detected platforms:

```powershell
@{
    ConfidenceThreshold = 80
    NitCap              = 3
    Platforms           = @('core-7.4-windows', 'core-7.4-linux', 'core-7.4-macos')
    SkipAgents          = @()
    StaticAnalysisOnly  = $false
}
```

### `.pwsh-review/profile.lock.json`

Compute and write hashes for:

- Each public function name + signature
- Each module manifest
- Each top-level directory listing
- The ruleset version

Used by the freshness check on every review.

## Phase 3: AST index

Run `scripts/Get-AstIndex.ps1 -Cold`. This walks every PowerShell file, parses the AST, and writes the initial index to `.pwsh-review/cache/ast-index.json`. Expect 5-30s on a typical repo.

## Phase 4: static layer dry run

Run `scripts/Invoke-StaticAnalysis.ps1 -All -DryRun` to verify the linter settings work and the required modules are installed. Report any setup issues to the user.

## Phase 5: hand-off to user

Print a concise summary:

```
pwsh-code-review profile created at .pwsh-review/

Detected:
  Project:        <name>
  Shape:          <monolith / multi-module / etc>
  Public funcs:   <count>
  Tests:          <count> Pester files, <%> coverage
  Platforms:      <list>
  pwsh version:   <version>+

Drafted (please review and edit):
  architecture.md         (<n> sections marked TODO)
  standards.md            (filled from templates + your existing files)
  glossary.md             (<n> terms drafted, all marked TODO)
  patterns/               (<n> from your codebase, <n> from templates)
  PSScriptAnalyzerSettings.psd1
  config.psd1

Next steps:
  1. Review the drafted files. Especially glossary.md and architecture.md.
  2. Commit .pwsh-review/ to the repo.
  3. Run /pwsh-review on a real change to test.
```

## Refresh mode

`--refresh` regenerates without losing hand edits:

1. Re-run discovery.
2. For each file in `.pwsh-review/`, compute a diff between the current content and a freshly generated version.
3. Show the user the diff and ask which sections to apply.
4. Always update `profile.lock.json` and `cache/ast-index.json` automatically.
5. Never touch `glossary.md` content (it is hand-curated).
6. Never touch `patterns/*.ps1` content (it is hand-picked).

## Force mode

`--force` overwrites everything. Confirms with a single prompt before doing so. Useful when starting over.
