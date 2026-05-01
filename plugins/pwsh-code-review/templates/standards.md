# Standards

The rulebook the reviewer enforces. Every `minor` finding from the conventions agent must point to a section here. If a rule is not in this file, the agent will at most flag it as a `nit`.

This file is the project's. Edit freely. The reviewer reloads it on every run.

## Naming

- Public function names use approved PowerShell verbs (`Get-Verb`).
- Cmdlet nouns are singular.
- Parameter names follow standard pwsh nouns: `Path`, `LiteralPath`, `Name`, `Identity`, `InputObject`, `Force`, `PassThru`, `WhatIf`.
- Variable names describe what the variable holds, not how it was computed. `$users` not `$result`.
- Boolean parameters are `[switch]` not `[bool]`.

## Function shape

### Public functions

- Have `[CmdletBinding()]`.
- Have `[OutputType()]` declaring the actual return type. The declaration must match runtime behaviour.
- Have comment-based help with `.SYNOPSIS`, `.DESCRIPTION`, one `.PARAMETER` per parameter, and at least one `.EXAMPLE`.
- Use `[Parameter()]` attributes for every parameter.
- Use `[ValidateNotNullOrEmpty()]`, `[ValidateSet()]`, or other validation attributes for inputs that have constraints.
- Use `process` blocks if `ValueFromPipeline` is declared on any parameter.
- Use `SupportsShouldProcess` for state-changing functions.
- Live in `Public/` directory of their module.
- Are exported in the module manifest's `FunctionsToExport`.

### Internal functions

- Live in `Private/`.
- Are not exported.
- May skip comment-based help.
- Still declare `[OutputType()]` if the type is non-obvious.

## Error handling

- `$ErrorActionPreference = 'Stop'` at the top of every script and module.
- `try/catch` only where you can do something with the error. Empty `catch` is forbidden.
- Throw via `Write-Error -ErrorAction Stop -Category <Specific> -ErrorId <Stable>`. Avoid `throw "string"` for production errors.
- Do not use `-ErrorAction SilentlyContinue` without a comment explaining why.
- Set `Set-StrictMode -Version 3.0` at script entry.

## Output discipline

- One output type per function. No mixed types across branches.
- Do not write to the success stream from `begin` or `end` blocks unless explicitly intended.
- Do not use `Write-Host` in library code. Use `Write-Information` (with `InformationAction`).
- Use `Write-Verbose` for diagnostic output, gated behind `-Verbose`.
- Use `Write-Warning` for recoverable problems.
- Use `Write-Progress` for long-running visible work.

## Cross-platform

This project targets all three desktop platforms. The following are blockers:

- Hard-coded `\` in path strings. Use `Join-Path` or `[IO.Path]::Combine`.
- Hard-coded `/` in path strings, except for URLs.
- Use of `$env:USERPROFILE`, `$env:APPDATA`, `$env:LOCALAPPDATA` without an `$IsWindows` guard. Prefer `$HOME`.
- Use of `Get-CimInstance`, `Get-WmiObject`, registry cmdlets without `if ($IsWindows)` guard.
- Invocation of `powershell.exe` instead of `pwsh`.
- COM object creation outside `$IsWindows` blocks.

## Pipeline correctness

- Functions accepting pipeline input have a `process` block.
- Functions emitting one or many objects use the comma trick to force array context where the consumer expects an array.
- Singleton vs collection ambiguity is resolved at the function boundary, not at every consumer.

## Concurrency

- No `$global:` or `$script:` writes from inside `ForEach-Object -Parallel`, runspace pools, or `Start-ThreadJob`.
- Shared state across threads uses `[System.Collections.Concurrent.*]` types.
- `$using:` captures must be immutable.

## Security defaults

- No plaintext credentials in code, parameters, or config files.
- No `Invoke-Expression` on data from a parameter, file, network, or environment.
- No `ConvertTo-SecureString -AsPlainText -Force` outside trusted local-only paths.
- Native command arguments passed in array form: `& $exe $arg1 $arg2`, never `& $exe "$concatenated"`.
- TLS 1.2+ only. Never disable certificate validation.

## Testing

- Pester 5+.
- One test file per source file, named `<SourceName>.Tests.ps1`.
- Tests describe behaviour. Do not mock the function under test.
- Every public function has at least one test.
- Every conditional branch has at least one test.
- Tests use `Should` assertions; tests without assertions are forbidden.
- Code coverage minimum: <set your number, e.g. 80%>.

### Test brittleness

Tests should assert behaviour, not coincidences of the current data. A test that breaks every time an unrelated example is added has negative value: it trains authors to update assertions to match outputs rather than to think about what the production code is supposed to do. The reviewer flags the following patterns under the `PWSH-TEST-NNN` rule namespace.

A finding fires only when the candidate expression sits inside an assertion call (`Should` or `Assert-*`) — either as an argument (`Assert-True -Condition (...)`) or via pipeline (`$x | Should -Be 1`). Rules `PWSH-TEST-003` and `PWSH-TEST-004` use a wider scope (any `Describe`/`Context`/`It`/`Before*`/`After*` block) because the brittle production-code pattern they catch is a bug regardless of where the assertion sits.

- `PWSH-TEST-001` - `.Count -ge N` or `.Count -eq N` with `N > 5` inside an assertion. Assert on a property of the data, not its size.
- `PWSH-TEST-002` - order-dependent regex against multi-line output from `Get-Content`/`Get-ChildItem`/`Get-Process`/`Format-*` inside an assertion. Filter to the line of interest before matching, or assert structurally.
- `PWSH-TEST-003` - `Sort-Object | Get-Unique` inside a test scriptblock followed by an indexed or ordered comparison. The sort destroys the original order; the assertion tests the sort, not the production code.
- `PWSH-TEST-004` - ordered access on a hashtable's `.Keys` (`($h.Keys)[N]` or `$h.Keys | Select-Object -First/-Last/-Index`) inside a test scriptblock. Hashtable key enumeration order is unspecified.
- `PWSH-TEST-005` - `Should -Match` / `-match` against a regex literal containing literal `\\` and no forward slash, inside an assertion. Will fail on Linux/macOS CI.

### Template substitution

When the project renders prompts (or any text) by `-replace`-ing `{{token-name}}` placeholders in markdown, the reviewer flags two failure classes under `PWSH-TPL-NNN`. The token catalog is auto-discovered from `-replace '\{\{TOKEN_NAME\}\}', $rhs` patterns and snapshotted to `.pwsh-review/template-rules.json` at bootstrap. The rule itself only fires on uppercase placeholders (regex `\{\{[A-Z][A-Z0-9_]*\}\}`); lowercase placeholders such as the `{{token-name}}` examples in this paragraph are out of scope by design.

- `PWSH-TPL-001` - the markdown references a `{{token-name}}` that has no `-replace` rule anywhere in the repo. The runtime will leave the literal placeholder in the rendered output. Either fix the typo or add a substitution rule.
- `PWSH-TPL-002` - prose conditional that the substitution will never satisfy: text near a `{{token-name}}` reference says "if `{{token-name}}` is empty / missing / blank / absent / not set". When the token is provably always non-empty (the `-replace` source declares an explicit fallback), the conditional is dead code (confidence 80). When the token's emptiness is uncertain, the finding is hedged (confidence 60).

### Cross-module data shapes

When a function changes the shape of an object it emits (`[pscustomobject]@{...}`, a returned hashtable, or `New-Object -Property @{...}`), callers in other files that still access the dropped property keep type-checking and parsing fine but break at runtime. The reviewer pre-computes pre/post emit shapes and walks the AST index for stale consumers; the diff-bug agent emits these as `PWSH-DIFF-201`.

- `PWSH-DIFF-201` - the function consistently emitted property `X` before this change, never emits it now, and at least one caller in the index still reads `$result.X` (or `$result['X']`) by literal name. Severity `major`, confidence 80. In v1 the rule fires only on mechanically robust cases (literal consumer accesses against non-dynamic-key emit sites); dynamic property accesses and dynamic-key emit sites are not surfaced.

Set `EnableShapeTracking = $false` in `.pwsh-review/config.psd1` to disable the check. Defaults to on.

### Markdown content

When a diff touches at least one `*.md` or `*.markdown` file, the reviewer dispatches a sixth agent that reads the changed files alongside the rest of the markdown corpus, the glossary, and the architecture doc. Five rule classes under `PWSH-MD-NNN`:

- `PWSH-MD-001` — reference drift: a backtick-quoted path uses a non-canonical form versus the rest of the corpus. Minor, confidence 80 when the canonical form is ≥2× more common, 60 otherwise.
- `PWSH-MD-002` — broken reference: a backtick-quoted relative path does not resolve to an existing file. Major, confidence 90.
- `PWSH-MD-003` — glossary contradiction: prose makes a factual claim that contradicts a definition in `glossary.md`. Minor, confidence cap 70.
- `PWSH-MD-004` — cross-file claim drift: the same concept is described differently across two corpus files, with one of them touched by the diff. Minor, confidence cap 70.
- `PWSH-MD-005` — code-fence example mismatch: the JSON / YAML / pwsh inside a code fence has a shape that contradicts what the surrounding prose says it shows. Major, confidence 80 when mechanically provable.

Configure `MarkdownAllowedReferenceForms = @('README.md', 'docs/README.md')` in `.pwsh-review/config.psd1` for path forms that legitimately appear in multiple shapes across the corpus. Defaults to empty.

## Module manifests

- `FunctionsToExport` lists the actual exports (no `'*'`).
- `RequiredModules` specifies a minimum version for every entry.
- `PowerShellVersion` is set explicitly.
- `CompatiblePSEditions` is set explicitly.
- Manifest version bumped on every change to public surface.

## File hygiene

- UTF-8 with BOM for Windows PowerShell compatibility, or UTF-8 no-BOM for Core-only.
- LF line endings (configured via `.gitattributes`).
- `.editorconfig` honoured.
- No tabs in pwsh files.
- Trailing whitespace stripped.

## Documentation

- READMEs are kept current.
- Public function changes propagate to `architecture.md`'s public surface table.
- Breaking changes get a `BREAKING:` prefix in the commit message.

## Deviations

Document any project-specific deviation from this standard here, with rationale. The reviewer will respect documented deviations.

<!-- TODO: list project-specific exceptions -->
