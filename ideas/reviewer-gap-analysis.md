# Prompt: pwsh-code-review reviewer gap analysis

## Loop status

`loop status: round 1 in flight (PRs A-F draining the initial 12-entry queue) -- observe before queueing round 2`

## Recently observed gaps

Format: `[YYYY-MM-DD] PR #N -- <one-sentence gap> -- <agent or scanner that should have caught it>`

(empty -- populated by external reviewers between rounds)

## Why this exists

We ran `pwsh-code-review v0.19.0` end-to-end against three real PowerShell PRs in `andresharpe/dotbot` (#385, #386, #387) and against three of our own PRs in this repo (#33, #34, #35) where Copilot also reviewed independently. Several Copilot comments named issues that the plugin's own reviewer agents would have missed. This file captures those known gaps and asks for a deeper sweep so the next batch of agent / scanner improvements lands as a coherent set.

The plugin pipeline this document is talking about:

- `plugins/pwsh-code-review/agents/*.md` — the dispatched reviewer agents (conventions, pwsh-idioms, diff-bug, security, history, markdown-content, js-content, calibrator).
- `plugins/pwsh-code-review/scripts/Test-*.ps1` — the heuristic static scanners (`Test-Brittleness.ps1`, `Test-Coverage.ps1`, `Test-TemplateSubstitution.ps1`).
- `plugins/pwsh-code-review/scripts/Tests-*/Run.ps1` — the self-test fixtures that pin scanner behavior.
- `plugins/pwsh-code-review/scripts/Merge-Findings.ps1` — the post-pass that calibrates, filters, clusters, and renders.

## Known gaps (already identified — do not re-derive these)

### 1. `pwsh-idioms-agent` does not cover here-string escape discipline

PR #35 thread 1: a `@"..."@` here-string in `Initialize-ReviewProfile.ps1` had `\$hash` / `\$key` written instead of `` `$hash `` / `` `$key ``. Backslash is a literal in PowerShell; the escape character is backtick. Under `Set-StrictMode -Version 3.0` the unescaped variables would trip on the bootstrap call.

This is the canonical PowerShell-escape trap. The plugin generates config files via templated here-strings exactly like the one that broke, so the same bug class can land in any user's project profile. The `pwsh-idioms-agent` prompt covers "encoding", "cross-platform", "native commands" but does not enumerate **here-string escape discipline (`` `$ `` vs `\$`)** as a named trap.

**Where to land:** `plugins/pwsh-code-review/agents/pwsh-idioms-agent.md` — add a named rule with examples (correct vs broken). Optionally a heuristic in a new `Test-HereStringEscape.ps1` scanner that flags `\$<varname>` patterns inside `@"..."@` regions.

### 2. `diff-bug-agent` does not cover vocabulary validation at boundary

PR #35 thread 2: `RuleSeverityOverrides` accepted any string from `config.psd1`. A typo like `'minro'` for `'minor'` was applied verbatim, the `$counts` hashtable could not increment an unknown severity key, and the verdict silently dropped a finding that should have been a blocker.

This bug class is "function accepts a value that should be from a fixed vocabulary (enum-like field) without validating it". It shows up wherever a config maps strings to internal classifications: severities, log levels, task states, MCP tool names, agent names, severity-rubric keys, etc. The `diff-bug-agent` prompt lists "regex precision" and "alias / normalisation consistency" but not **vocabulary validation at boundary**.

**Where to land:** `plugins/pwsh-code-review/agents/diff-bug-agent.md` — add a named rule. Concrete signal to look for: a string parameter whose value flows into a `switch`, an indexer (`$dict[$value]`), or a `-in` check, **and** the agent can identify the closed set the string is meant to belong to.

### 3. No agent reviews inline-comment vs code consistency

PR #34 thread 2: a code comment said "Preserve the original encoding by writing through Set-Content -Encoding utf8NoBOM" while the implementation actually normalises rather than preserves byte-exact content. The comment is a contract claim that the implementation violates.

None of our agents check this. The `conventions-agent` covers comment-based help blocks (`<# .SYNOPSIS #>`), not inline `# why this code does X` comments. The `diff-bug-agent` could pick it up if explicitly prompted but its current prompt doesn't direct it to.

**Where to land:** either `conventions-agent.md` or `diff-bug-agent.md`. Concrete signal: a comment containing modal verbs ("preserves", "guarantees", "ensures", "always", "never") followed by code that doesn't deliver that contract. Hard to detect statically — agent-only territory.

### 4. `Test-Brittleness.ps1` does not flag too-permissive assertions

PR #34 thread 1: an assertion was `($r.RestoredCount -ge 7)` with a setup that produces exactly 8. A missed restore would have slipped through. The current scanner has rules for false-positive tests (conditional run that silently passes), incomplete mocks, success-path-only cleanup, and regex-in-assertions. It does not have a rule for **"comparison operator is too loose for the underlying setup math"**.

The signal is brittle to detect mechanically without understanding intent. A reasonable heuristic: when a test's setup builds a fixture from an enumerable known to the test (e.g. an `@(...)` literal nearby), and the assertion uses `-ge`/`-le`/`-gt`/`-lt` against a constant rather than `-eq`/`-ne` against the fixture's `.Count`, flag it.

**Where to land:** `plugins/pwsh-code-review/scripts/Test-Brittleness.ps1` — new rule (PWSH-TEST-NNN). Add a fixture pair under `scripts/Tests-TestBrittleness/`.

### 5. `pwsh-idioms-agent` Write-Host suggestion quality

PR #34 thread 4 (mostly covered by static): `Resolve-Profile.ps1` used `Write-Host` for status output that callers couldn't suppress. PSScriptAnalyzer's `PSAvoidUsingWriteHost` would flag this on the project as a warning, but the agent-side suggestion of "switch to `Write-Information` so callers can opt in via `-InformationAction Continue` or `6>&1`" is nuance the static layer doesn't add.

**Where to land:** `plugins/pwsh-code-review/agents/pwsh-idioms-agent.md` — when raising `PSAvoidUsingWriteHost`, the agent should explicitly point at `Write-Information` / `Write-Verbose` / `Write-Warning` and say which fits which intent (status, debug, problem). Light enhancement, mostly prompt copy.

### 6. Diff-bug agent: semantic-status correctness across return paths

PR #34 thread 3: `Resolve-Profile.ps1` returned a `Reason` field whose value was `'profile already complete'` even when the file was still missing locally because the base ref also lacked it. The function shipped three paths; only two of the three returned an honest status string.

The `diff-bug-agent` prompt mentions "signature / output shape changes" and "idempotency regressions" but not **per-path status-field correctness**. A concrete prompt addition: "for every code path that returns a status string from a fixed enum, verify the string truthfully describes what happened on that path."

**Where to land:** `diff-bug-agent.md` — sharpen the prompt. Bonus: a heuristic that inventories all `return @{ ... }` shapes in a function and flags when a string-typed field has fewer distinct constants than the function has early-return branches.

## Your task

The known gaps above are a starting set, not the whole picture. Compact this conversation, then take the prompt below as your standing brief.

> Read the full git history of this repo (`pwsh-code-review-marketplace`). For every recent merge or open PR, look at what Copilot, CodeRabbit, or human reviewers caught — and ask whether the plugin's own agents and scanners would have caught it. Treat each "no" as a candidate gap.
>
> Specifically:
>
> 1. Walk `git log --no-merges --oneline` over the last six months. For each commit whose subject mentions `fix`, `bug`, `regress`, `crash`, `strict`, `escape`, or `validate`, read the commit body and the diff. Categorise the bug class. Map the class onto an existing agent or scanner if it fits; flag a new gap if it does not.
>
> 2. Walk merged PRs via `gh pr list --state merged --limit 50 --json number,title,reviews`. For PRs that received Copilot or CodeRabbit reviews, fetch the review threads (`gh api graphql` with `reviewThreads`). Compare each unresolved-then-resolved bot comment against the agent prompts. Any comment whose substance is not in any agent's brief is a gap.
>
> 3. Cross-check against `andresharpe/dotbot/.pwsh-review/standards.md` (if accessible). The dotbot project profile represents the maturity floor we want every reviewer to enforce. Any rule in dotbot's standards that has no corresponding agent prompt or scanner heuristic is a gap.
>
> 4. For the gaps you find, propose **one PR per coherent gap cluster**. Each PR should: name the rule (PWSH-NNN-NNN), update the relevant agent's prompt or add a new scanner with a positive + negative fixture, update `docs/severity-rubric.md` if a new rule namespace is introduced, bump nothing (auto-bump handles version), and ship a self-test that fails on the buggy fixture and passes on the clean one.
>
> 5. Where multiple gaps share infrastructure (e.g. several new heuristics in `Test-Brittleness.ps1`), bundle them. Where they are independent (e.g. an agent prompt edit and a new scanner), keep them separate so reviewers can land them in any order.
>
> 6. Include the six known gaps from this file in your audit so we end up with one prioritised list, not two parallel ones.
>
> Output before opening any PR: a short prioritised list of (gap → proposed PR title → estimated agent vs scanner vs prompt-only). Wait for approval, then open the PRs.

## Dogfooding the plugin against its own repo

We have not yet run `pwsh-code-review` against `pwsh-code-review-marketplace` itself. That is the obvious blind spot: the project that ships the reviewer is the one most likely to keep tripping the gaps the reviewer hasn't grown to cover yet. Set this up as a standing process.

> 7. **Bootstrap a `.pwsh-review/` profile for this repo.** Run `/pwsh-review-bootstrap` from the repo root. Curate the drafted `architecture.md`, `standards.md`, and `glossary.md` so they describe the plugin's own conventions (single-module shape, test fixture conventions under `Tests-*/`, severity rubric vocabulary, agent-prompt formatting, the auto-bump workflow contract). Add `pattern-*.ps1` files that point at the cleanest existing examples in the codebase. Commit the profile to `main` so future reviews have something to load.
>
> 8. **Wire `/pwsh-review` into the local pre-push flow.** Either as a `.githooks/pre-push` step, a documented checklist in `CONTRIBUTING.md`, or a `make review` / `Invoke-LocalReview.ps1` convenience entry point — whichever fits the project's existing surface. The hook should run the full `/pwsh-review` against staged + unpushed commits, refuse to push if the verdict is `needs rework`, and warn but allow on `fix majors first`. The point is that no commit reaches GitHub without the project's own reviewer having a say.
>
> 9. **Wire `/pwsh-review` into CI.** A new GitHub Actions job that runs `Invoke-StaticAnalysis.ps1 -All` plus `/pwsh-review --branch main --static-only` against every PR. Static-only is the right scope for CI — the agent dispatch belongs in pre-push (where the operator has API budget) or as a `--comment` step the operator opts into manually. The CI job's job is to catch what static can catch and to fail loudly when the project's own scanners regress.

## Self-improvement loop

The previous two sections fit together as a closed loop:

1. **Dogfood at every push** (step 8 above). Each push surfaces the plugin's current ceiling in real time.
2. **Compare against external reviewers** (Copilot / CodeRabbit / human owner reviews on the same PR). Any comment they make that the plugin missed is a candidate gap.
3. **Add new gaps to this file** under a "Recently observed gaps" section that the next iteration of step 4 (the prioritised list) consumes.
4. **Close gaps via PRs** (step 4 above). Each PR adds an agent prompt clause, a scanner heuristic, or a fixture that pins the new behavior. After merge, the auto-bump workflow tags a new minor version automatically, and the next dogfood run runs against the now-improved plugin.
5. **Stop conditions:** the loop stops when (a) three consecutive PRs land with zero gaps observed, OR (b) only style-class nits remain. Track this state at the top of this file (e.g. `loop status: 2 consecutive clean reviews — stop after 1 more`).

> 10. Maintain a "Recently observed gaps" section at the top of this file. Each entry is one line: `[YYYY-MM-DD] PR #N — <one-sentence gap> — <agent or scanner that should have caught it>`. New entries get added when external reviewers catch what the plugin missed. Entries get cleared when the corresponding fix-PR merges. The list of entries is the queue the loop drains.
>
> 11. Make this file self-aware. Each PR opened to close a gap should also remove the corresponding line(s) from "Recently observed gaps" and append to a "Closed gaps" log at the bottom. The loop's halting state lives in the file alongside the queue.

## Closed gaps

| Date | PR | Gap | Owner |
|------|----|----|-------|
| 2026-04-30 | PR-A (#37) | Here-string escape discipline (`\$x` vs backtick-`$x`) | pwsh-idioms-agent |
| 2026-04-30 | PR-A (#37) | `$Matches` clobber on nested regex | pwsh-idioms-agent |
| 2026-04-30 | PR-A (#37) | `ConvertFrom-Json -AsHashtable` single-element unwrap under StrictMode 3.0 | pwsh-idioms-agent |
| 2026-04-30 | PR-A (#37) | `Write-Host` replacement guidance (Information / Verbose / Warning / Error) | pwsh-idioms-agent |
| 2026-04-30 | PR-B (#38) | Vocabulary validation at boundary (PWSH-DIFF-307) | diff-bug-agent |
| 2026-04-30 | PR-B (#38) | Comment-as-contract mismatch (PWSH-DIFF-308) | diff-bug-agent |
| 2026-04-30 | PR-B (#38) | Per-path status-field correctness (PWSH-DIFF-309) | diff-bug-agent |
| 2026-04-30 | PR-C (#39) | `-ErrorAction SilentlyContinue` / `Ignore` without inline justification | conventions-agent |
| 2026-04-30 | PR-D | Loose `-ge`/`-le`/`-gt`/`-lt` against `*Count` / `*Length` properties (PWSH-TEST-010) | Test-Brittleness.ps1 |

---

_Created during the v0.19.0 e2e shakedown against `andresharpe/dotbot` and the three resulting marketplace PRs (#33 merged, #34 and #35 in flight at time of writing)._
