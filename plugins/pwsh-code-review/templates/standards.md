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
