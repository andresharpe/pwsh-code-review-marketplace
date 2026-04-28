# Code-quality principles

These are the principles every agent in this plugin shares. They are deliberately small in number and general in scope, because most of the value of a code reviewer comes from internalising a few rules and applying them to every diff, not from a long checklist.

The order matters. When two principles conflict, the earlier one wins.

## 1. Make it work, make it right, make it fast

Correctness first, clarity second, performance third. Don't skip steps. Reviewer comments should follow the same priority: a correctness blocker beats a clarity major beats a performance minor.

## 2. Change the smallest thing that works

Flag PRs that touch unrelated code, rename gratuitously, or refactor alongside fixes. Drive-by changes are how regressions sneak in. If a refactor is needed to make the fix clean, the refactor is a separate PR.

## 3. Pure where you can, impure where you must

I/O, time, randomness, and global state pushed to the edges. Functions that do work should be testable without mocks. In PowerShell terms: business logic in advanced functions that take parameters and return objects, side effects in a thin shell that orchestrates them. Flag I/O buried inside computation.

## 4. Errors are values, not surprises

Terminating vs non-terminating discipline. `$ErrorActionPreference` set explicitly at script entry. `try/catch` only where you can actually do something. Empty `catch { }` is a finding. `-ErrorAction SilentlyContinue` without a justifying comment is a finding. Prefer `Write-Error -ErrorAction Stop` over `throw "string"` for typed errors.

## 5. Names carry weight

Approved verbs. Singular nouns. Standard parameter names (`Path`, `LiteralPath`, `Name`, `Identity`, `InputObject`) so functions pipeline correctly. Variable names match what they hold, not how they were computed. Flag `$data`, `$temp`, `$result` without further qualification.

## 6. Fail fast at the boundary, trust within

Parameter validation attributes (`[ValidateNotNullOrEmpty()]`, `[ValidateSet()]`, `[ValidateScript()]`) on entry points. Internal helpers assume their inputs are clean. Avoid defensive programming everywhere.

## 7. One output type per function

Don't return a string sometimes and an object other times. Don't emit progress to the success stream. `[OutputType()]` declared and accurate on every public function. Flag functions whose `[OutputType()]` lies or is missing on exported surface.

## 8. No dead code, no commented-out code

Git remembers. Comments explain *why*, never *what*. `TODO` without a ticket is a finding.

## 9. Tests describe behaviour, not implementation

Pester tests should read as specs. Flag tests that mock the function under test, assert on internal calls rather than outputs, or duplicate the implementation logic in the assertion. New conditional branches without new test cases are a finding.

## 10. Idempotency for anything that touches state

Re-running the same script should not break or duplicate. For any function that creates, writes, or sends, the reviewer asks "what happens on the second run?".

## 11. No shared mutable state in concurrent code

Runspaces and `ForEach-Object -Parallel` need explicit thread safety. Flag `$using:` capturing mutable collections. Flag `$script:` or `$global:` writes from inside parallel scopes.

## 12. Cross-platform by default

Path separators via `Join-Path` or `[IO.Path]::Combine`, never hard-coded `\`. Platform-specific cmdlets gated by `$IsWindows`, `$IsLinux`, `$IsMacOS`. `$HOME` not `$env:USERPROFILE`. `pwsh` not `powershell.exe`. Encoding declared explicitly when writing files consumed by other tools. This is non-negotiable for pwsh 7+ projects.

## 13. Security defaults

No plaintext credentials. No `Invoke-Expression` on anything touched by external input. No `ConvertTo-SecureString -AsPlainText -Force` outside trusted local contexts. No string concatenation into native commands. Use the project's `Invoke-Native` wrapper if one exists.

## 14. Documentation is part of the contract

Every public function has comment-based help with `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` for each parameter, and at least one `.EXAMPLE`. Missing help on exported functions is a hard fail.

## 15. Backward compatibility for public surface

Removing a parameter, changing default values, or tightening validation on an exported function is a breaking change. Flag these and ask for a deprecation path.

## 16. Performance principles, in order

Correctness, then readability, then speed. But: avoid `+=` on arrays in loops (O(n^2)), use `[System.Collections.Generic.List[T]]`. Use `Get-Content -Raw` for whole-file reads. Prefer property syntax (`Where-Object Name -eq`) over script blocks where it suffices.

## 17. The static layer is ground truth

If PSScriptAnalyzer says it is an error, it is an error. The agents add judgement on top, they do not override. An agent that disagrees with the static layer must say so explicitly and justify, never silently re-flag or contradict.

## 18. Comment with concrete consequence or do not comment

Every finding answers three questions in one or two sentences each: what changed, why it is a problem (with a specific consequence, ideally a caller, test, or pattern), what to do. If a finding cannot answer all three, drop it.
