# Architecture

This file documents the high-level shape of the codebase. It is loaded by every reviewer agent so they can check changes against project intent. Keep it accurate.

## Project shape

<!-- TODO: confirm or replace -->
<one paragraph: what kind of project is this? Library, CLI tool, build script collection, multi-module suite, internal automation? Auto-detected as: ?>

## Module map

<!-- TODO: regenerate with /pwsh-review-bootstrap --refresh after structural changes -->

| Module | Path | Public functions | Internal functions | Tests |
| ------ | ---- | ---------------- | ------------------ | ----- |
| _example_ | `src/Modules/Example` | 12 | 5 | `tests/Example/` |

## Dependency direction

<!-- TODO -->
Which module is allowed to depend on which. State this explicitly. Reviewers will flag dependency reversals.

Example:
- `Example.Core` depends on nothing project-internal
- `Example.Api` depends on `Example.Core`
- `Example.Cli` depends on `Example.Api`
- Reverse dependencies are blockers

## Public surface

<!-- TODO: regenerate with /pwsh-review-bootstrap --refresh -->

The functions exported by the project. Changing any of these is a breaking change that requires a deprecation path.

| Function | Module | OutputType | SupportsShouldProcess |
| -------- | ------ | ---------- | --------------------- |

## Side-effect boundary

<!-- TODO -->
Where does I/O happen in this codebase? The reviewer will flag pure functions that newly acquire side effects.

Common pattern:
- `Public/*.ps1` orchestrates, may do I/O
- `Private/Compute-*.ps1` is pure
- `Private/IO-*.ps1` is the I/O shell
- Filesystem writes only via `Private/IO-Write*.ps1`

## External dependencies

<!-- TODO -->

### PowerShell modules

From `RequiredModules` and detected `Import-Module` calls:

| Module | Min version | Purpose |
| ------ | ----------- | ------- |

### Native commands assumed on PATH

| Command | Purpose | Platforms |
| ------- | ------- | --------- |

## Target platform

<!-- TODO -->

- pwsh: 7.4+
- editions: Core (Desktop edition not supported)
- OS: <Windows / Linux / macOS / all>

## Build and test

<!-- TODO -->

- Build: `<script or command>`
- Test: `Invoke-Pester`
- CI: `.github/workflows/<file>.yml`

## Conventions specific to this project

<!-- TODO -->
List anything that is non-default for pwsh and that the reviewer should respect:

- Logging via `Write-Information` only (no Write-Host)
- All public functions take `-LogContext` for correlation
- Errors raised via `Write-Error -Category <typed>` not bare `throw`
- (etc.)
