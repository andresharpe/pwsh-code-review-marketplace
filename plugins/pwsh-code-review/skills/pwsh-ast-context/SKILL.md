---
name: pwsh-ast-context
description: How pwsh-code-review computes diff context using PowerShell's AST. Defines the Ring 0/Ring 1 context model, the AST index format, the call graph algorithm, and the diff-context.json schema. Use when computing diff context for a review or when explaining how the reviewer reasons about staged changes.
---

# pwsh-ast-context skill

The reviewer's job is to reason about *the diff* with enough surrounding context to be correct, and not one line more. This skill defines the context-loading algorithm that makes that work.

## The ring model

**Ring 0**: the diff itself. Hunks, with full file context cached but not loaded as input until needed. This is what changed. Every comment must trace back to a Ring 0 line. No comments on unchanged code unless the unchanged code is broken *because of* the change.

**Ring 1**: the immediate neighbourhood. For each changed function or script block: the file it lives in, callers within the repo, callees within the repo, type definitions touched, Pester tests that reference it. This is what the agents read to verify the diff is correct.

**Ring 2**: the project profile. `architecture.md`, `standards.md`, `patterns/`, `glossary.md`. Loaded as system context.

Anything beyond Ring 1 requires explicit escalation by an agent. Default depth is one hop.

## The AST index

Single JSON file at `.pwsh-review/cache/ast-index.json`. Keyed by file path, content addressed by SHA256.

```json
{
  "schema_version": "1",
  "generated": "<ISO timestamp>",
  "files": {
    "src/Modules/WidgetCore/Public/New-Widget.ps1": {
      "hash": "<sha256>",
      "functions": [
        {
          "name": "New-Widget",
          "line_start": 1,
          "line_end": 87,
          "parameters": [
            {
              "name": "Path",
              "type": "string",
              "mandatory": true,
              "validations": ["ValidateNotNullOrEmpty"],
              "value_from_pipeline": false
            }
          ],
          "output_type_declared": ["Widget"],
          "has_process_block": false,
          "supports_should_process": true,
          "has_cbh": true,
          "calls": ["Test-Path", "Join-Path", "git", "Write-Verbose"],
          "scope_writes": [],
          "platform_signals": ["IsWindows"]
        }
      ],
      "imports": ["Module1"],
      "uses_classes": ["Widget"],
      "is_test": false,
      "manifest": null
    }
  },
  "function_to_file": {
    "New-Widget": "src/Modules/WidgetCore/Public/New-Widget.ps1"
  },
  "callers_of": {
    "New-Widget": [
      {"file": "server.ps1", "line": 120, "context": "function-body"},
      {"file": "tests/New-Widget.Tests.ps1", "line": 55, "context": "test"}
    ]
  },
  "tests_for": {
    "New-Widget": ["tests/New-Widget.Tests.ps1"]
  }
}
```

## Building the index

```powershell
function Build-AstIndex {
    [CmdletBinding()]
    param(
        [string]$RepoRoot = (Get-Location).Path,
        [switch]$Cold
    )

    $indexPath = Join-Path $RepoRoot '.pwsh-review/cache/ast-index.json'
    $index = if ($Cold -or -not (Test-Path $indexPath)) {
        @{ schema_version = '1'; files = @{}; function_to_file = @{}; callers_of = @{}; tests_for = @{} }
    } else {
        Get-Content $indexPath -Raw | ConvertFrom-Json -AsHashtable
    }

    $files = Get-ChildItem -Path $RepoRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
        Where-Object { $_.FullName -notmatch '\.pwsh-review[/\\]cache' }

    foreach ($file in $files) {
        $relPath = [System.IO.Path]::GetRelativePath($RepoRoot, $file.FullName)
        $hash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash

        if ($index.files[$relPath].hash -eq $hash) { continue }   # cached

        $tokens = $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName, [ref]$tokens, [ref]$errors
        )

        $index.files[$relPath] = ConvertTo-FileEntry -Ast $ast -Hash $hash
    }

    # Rebuild cross-references after all files are parsed
    $index.function_to_file = Build-FunctionToFile $index
    $index.callers_of = Build-CallGraph $index
    $index.tests_for = Build-TestMap $index

    $index | ConvertTo-Json -Depth 20 | Set-Content $indexPath -Encoding utf8NoBOM
}
```

The actual implementation is in `scripts/Get-AstIndex.ps1`. Cold builds parse every file. Warm builds re-parse only changed files (file hash differs from cached) and rebuild cross-references.

## Function extraction

For each `FunctionDefinitionAst`, extract:

- Name
- Line range (`Extent.StartLineNumber`, `EndLineNumber`)
- Parameters from `Parameters` or `Body.ParamBlock.Parameters`
- For each parameter:
  - Name from `Name.VariablePath.UserPath`
  - Type from `StaticType.FullName`
  - Mandatory: any `[Parameter()]` attribute with `Mandatory = $true`
  - Validations: list of attribute type names matching `Validate*`
  - `ValueFromPipeline`, `ValueFromPipelineByPropertyName`
- Declared `[OutputType()]`: from attributes on the function
- `has_process_block`: whether `Body.ProcessBlock` is non-null
- `supports_should_process`: from `[CmdletBinding(SupportsShouldProcess)]`
- `has_cbh`: whether the comment immediately preceding the function contains `.SYNOPSIS`
- `calls`: distinct command names invoked inside (from `Find` over `CommandAst`)
- `scope_writes`: variables written with `$script:` or `$global:` prefix (from `AssignmentStatementAst`)
- `platform_signals`: flag if function references `$IsWindows`/`$IsLinux`/`$IsMacOS`, hard-coded `\` paths, registry, COM, etc.

## Building the call graph

For each function in the index, scan every other file's `calls` array. If function `Foo` appears in file `Bar.ps1` line 42, then:

```json
"callers_of": {
  "Foo": [
    {"file": "Bar.ps1", "line": 42, "context": "function-body"}
  ]
}
```

`context` is one of:
- `function-body`: the call is inside another function definition
- `script`: top-level call in a script
- `test`: file is a Pester test (suffix `.Tests.ps1` or under `tests/`)
- `init`: file is a `.psm1` module init
- `unknown`

This context lets agents weight findings: a breaking change with only test callers may be less severe than one with script callers.

## Building the test map

For each function `Foo`, identify Pester tests by:

1. Test file with matching name: `tests/<FunctionName>.Tests.ps1`, `<FunctionName>.Tests.ps1` next to source
2. Test files where `Describe` or `Context` block titles contain the function name
3. Test files that import the module containing the function and call it

Result:

```json
"tests_for": {
  "New-Widget": [
    "tests/New-Widget.Tests.ps1",
    "tests/integration/Widget.Integration.Tests.ps1"
  ]
}
```

## Computing diff context

Given a diff and the AST index:

1. Parse the diff into `(file, line_start, line_end)` hunks.
2. For each hunk, intersect with `index.files[file].functions[*]` line ranges. Result: list of changed functions per file.
3. For each changed function, look up:
   - `index.callers_of[functionName]` -> Ring 1 callers
   - `index.tests_for[functionName]` -> Ring 1 tests
   - `index.files[file].functions.calls` -> Ring 1 callees (functions called by the changed function)
4. For each Ring 1 entry, also load the file content (just the surrounding 30 lines for callers, full file for callees if small).
5. Compute "what changed about the function": new vs old signature, new vs old output type, new vs old `process` block presence, etc. This needs the pre-change file too:

```powershell
$preContent = git show HEAD:$file
$preAst = [Parser]::ParseInput($preContent, ...)
$postAst = [Parser]::ParseInput($postContent, ...)
$delta = Compare-FunctionAst $preAst $postAst
```

## Diff context schema

`.pwsh-review/cache/diff-context.json`:

```json
{
  "schema_version": "1",
  "diff_base": "<sha>",
  "diff_head": "<sha>",
  "changed_files": [
    "src/Modules/WidgetCore/Public/New-Widget.ps1",
    "tests/New-Widget.Tests.ps1"
  ],
  "changed_hunks": [
    {
      "file": "src/Modules/WidgetCore/Public/New-Widget.ps1",
      "line_start": 42,
      "line_end": 48,
      "added": ["..."],
      "removed": ["..."]
    }
  ],
  "changed_functions": [
    {
      "name": "New-Widget",
      "file": "src/Modules/WidgetCore/Public/New-Widget.ps1",
      "line_start": 1,
      "line_end": 87,
      "delta": {
        "signature_changed": true,
        "signature_diff": [
          {"parameter": "Path", "change": "validation_removed", "old": ["ValidateNotNullOrEmpty"], "new": []}
        ],
        "output_type_changed": false,
        "process_block_changed": false,
        "should_process_changed": false,
        "calls_added": [],
        "calls_removed": [],
        "scope_writes_added": []
      },
      "callers": [
        {"file": "server.ps1", "line": 120, "context": "function-body", "snippet": "..."},
        {"file": "tests/New-Widget.Tests.ps1", "line": 55, "context": "test", "snippet": "..."}
      ],
      "callees": ["Test-Path", "Join-Path"],
      "tests": ["tests/New-Widget.Tests.ps1"]
    }
  ],
  "static_findings_summary": {
    "psscriptanalyzer": 3,
    "gitleaks": 0,
    "pester_failed": 0
  }
}
```

The agents consume this file. They never re-derive context themselves.

## Performance characteristics

| Repo size       | Cold build | Warm build (5 changed files) |
| --------------- | ---------- | ---------------------------- |
| 5k pwsh lines   | ~2s        | <1s                          |
| 25k pwsh lines  | ~8s        | <2s                          |
| 100k pwsh lines | ~30s       | ~5s                          |

The bulk of cold-build time is `[Parser]::ParseFile` (which is fast). Cross-reference building is O(n^2) over functions but cheap because the constants are small.

## When to refresh the index

- Bootstrap: cold build.
- Every review: warm build, recompute only changed files.
- Manual `--rebuild-index`: cold build, useful after large branch merges.
- File deletion: warm build detects missing entries and removes them.

## What this enables for agents

The diff-bug agent reads `delta.signature_diff` and immediately knows what contracts changed. It iterates `callers` to verify each call site. It iterates `tests` to verify coverage.

The conventions agent reads `output_type_changed` and `should_process_changed` to check pattern conformance.

The history agent uses `changed_hunks` to drive `git blame` queries scoped exactly to the lines that changed.

The pwsh-idioms agent uses `calls_added` to detect new platform-specific cmdlets.

The security agent uses `calls_added` to detect new dangerous cmdlets.

This is the structural foundation that lets the agents be fast and precise.
