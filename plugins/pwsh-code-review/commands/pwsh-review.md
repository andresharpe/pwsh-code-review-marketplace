---
name: pwsh-review
description: Multi-agent code review for PowerShell 7+ changes. Runs a deterministic static-analysis pre-pass, computes diff context via AST, dispatches five specialised agents in parallel (conventions, pwsh idioms, diff bugs, security, history), calibrates findings, and emits a single review with severity and confidence scores. Use this whenever the user asks to review PowerShell code, review a PR, check staged changes, or audit a pwsh script. Always use this for any PowerShell review task even if the user does not explicitly say "review".
---

# /pwsh-review

Performs automated code review on PowerShell 7+ changes using multiple specialised agents with confidence and severity scoring.

## Usage

```
/pwsh-review                     # review staged + uncommitted changes
/pwsh-review --staged            # review staged changes only
/pwsh-review --pr <number>       # review PR via gh CLI
/pwsh-review --branch <name>     # review branch vs main
/pwsh-review --comment           # post review as PR comment (requires --pr)
/pwsh-review --static-only       # skip agents, just run static analysis
/pwsh-review --threshold <n>     # confidence threshold (default 80)
/pwsh-review --skip <agent>      # skip a specific agent
```

## Pre-flight checks

Before doing any work, verify:

1. The repo is a git repo. If not, exit with a message.
2. There are actual changes to review (`git diff` non-empty for the chosen mode). If empty, exit cleanly with "No changes to review."
3. The PR (if `--pr`) is not closed, draft, or already reviewed by this plugin in its current SHA. Skip with explanation.
4. The project profile exists at `.pwsh-review/`. If not, prompt the user to run `/pwsh-review-bootstrap` first. Do not silently fall back to defaults.
5. Required pwsh modules are installed (`PSScriptAnalyzer`, `Pester`). If missing, install them silently (Scope: CurrentUser) before continuing.

## Phase 1: deterministic pre-pass

Run `scripts/Invoke-StaticAnalysis.ps1` against the diff scope. This runs in parallel:

- PSScriptAnalyzer with `.pwsh-review/PSScriptAnalyzerSettings.psd1`
- PSScriptAnalyzer compatibility rules for the platforms in `config.psd1`
- InjectionHunter custom rules
- Gitleaks (if available on `$PATH`)
- Pester (only if test files are touched, or run lightweight test discovery)
- markdownlint, actionlint, editorconfig-checker (if available, only on relevant file types)

The output is a JSON document at `.pwsh-review/cache/static-findings.json`:

```json
{
  "psscriptanalyzer": [...],
  "injection_hunter": [...],
  "gitleaks": [...],
  "pester": { "passed": 142, "failed": 0, "coverage_delta": -0.4 },
  "markdownlint": [...],
  "actionlint": [...]
}
```

Static-pass findings are added directly to the final review at the end. Agents do not re-evaluate them.

If `--static-only`, skip to Phase 5.

## Phase 2: diff context

Run `scripts/Get-DiffContext.ps1`. This:

1. Parses the diff into changed files, hunks, and line ranges.
2. Loads or refreshes the AST index at `.pwsh-review/cache/ast-index.json` (only re-parses files whose hash changed since last run).
3. For each changed function, computes Ring 1: callers, callees, referenced types, related Pester tests.
4. Emits `.pwsh-review/cache/diff-context.json`.

See `skills/pwsh-ast-context/SKILL.md` for the schema and walking algorithm.

If the AST index does not exist, this is a cold start; expect 5-30 seconds depending on repo size. Subsequent runs are near-instant for the unchanged portion.

## Phase 3: load project profile

Read these into context:

- `.pwsh-review/architecture.md`
- `.pwsh-review/standards.md`
- `.pwsh-review/glossary.md`
- All files in `.pwsh-review/patterns/`
- `docs/principles.md` (this plugin's universal rules)
- `docs/severity-rubric.md`

Run a freshness check: compare the hashes in `.pwsh-review/profile.lock.json` against current repo state. If the public surface, top-level modules, or module manifests have changed materially, surface a `question` finding at the end of the review: "Project profile may be stale. Consider re-running `/pwsh-review-bootstrap` to refresh." Do not block the review.

## Phase 4: dispatch agents

Launch the following agents **in parallel**. Each receives:

- The full diff
- `.pwsh-review/cache/diff-context.json`
- `.pwsh-review/cache/static-findings.json`
- The project profile from Phase 3
- The principles and severity rubric

Agents (always dispatched):

1. **`agents/conventions-agent.md`** - checks against `standards.md`, `patterns/`, comment-based help, naming.
2. **`agents/pwsh-idioms-agent.md`** - language-specific traps (null comparison, pipeline correctness, output type, cross-platform, encoding, native commands).
3. **`agents/diff-bug-agent.md`** - bugs introduced by the change, signature/contract changes, scope leaks, idempotency, concurrency.
4. **`agents/security-agent.md`** - injection, credentials, dangerous cmdlets, MOTW, untrusted input.
5. **`agents/history-agent.md`** - git blame and history, regressions, reverts, churn hotspots.

Conditional agents (dispatched only when the trigger applies):

6. **`agents/markdown-content-agent.md`** - cross-file documentation integrity (reference drift, broken refs, glossary contradictions, claim drift, fence/prose mismatches). **Dispatch only when the diff touches at least one `*.md` or `*.markdown` file.** When the diff has no markdown changes, skip this agent entirely (zero cost).

Each agent emits findings as JSON conforming to the schema in `docs/severity-rubric.md`. Agents do not see each other's findings during the dispatch phase.

If `--skip <agent>` is used, omit that agent.

## Phase 5: calibration

Pass all agent findings to the calibrator (`agents/calibrator-agent.md`). The calibrator:

- Confirms, downgrades, or drops findings.
- Never upgrades.
- Outputs a calibrated finding list.

Static-pass findings are not calibrated. They are ground truth.

## Phase 6: merge and emit

Run `scripts/Merge-Findings.ps1`:

1. Combine static + calibrated agent findings.
2. Apply the filter matrix from `docs/severity-rubric.md`.
3. Cluster similar findings (same rule, same file, contiguous lines).
4. Cap nits at the configured limit (default 3).
5. Sort: blocker, major, minor, nit, question, praise.
6. Within severity, sort by file path then line number.
7. Render to Markdown.

Emit to terminal by default. With `--comment` and `--pr`, post as a single review comment via `gh pr comment`.

If no findings remain after filtering, emit a single line: "No high-confidence findings. Static analysis: <summary>." Do not post empty PR comments.

## Output template

```markdown
## Code review: <branch> -> <base>

<one-line summary>: <n> blocker, <n> major, <n> minor, <n> nit, <n> question

### Static analysis

- PSScriptAnalyzer: <count> findings (see static-findings.json)
- Gitleaks: <count> findings
- Pester: <pass>/<total> passed, coverage delta: <%>

### blocker (<n>)

**[blocker] (<conf>) `<file>:<line-range>`**
<message>

<consequence>

Fix: <fix>
```suggested
<fix_snippet>
```

### major (<n>)
...

### minor (<n>)
...

### nit (<n>)
...

### question (<n>)
...

### praise (<n>)
...

---

_Reviewed by pwsh-code-review. Use `# pwsh-review:disable-next-line <rule>` to suppress._
```

## When to skip the review

Skip with a clean exit message in these cases:

- Diff is empty.
- Diff contains only `.txt` or asset files (still run markdownlint via static layer if applicable, but no agents).
- PR is closed or draft.
- PR has been reviewed at the current SHA already (check via `gh pr view --json reviews`).

Markdown-only diffs are **not** a skip case anymore: dispatch only `markdown-content-agent` (the other five agents have nothing to say about pure-markdown changes). The static layer's `markdownlint` still runs.

## Performance and caching

- AST index cached at `.pwsh-review/cache/ast-index.json`, keyed by file hash.
- Static-pass results cached per file hash.
- Both caches survive across invocations and across PR pushes.
- Cold start on a fresh repo: 30-60s for AST index. Warm: under 5s.

## Notes for implementers

- Agents are independent. Never let one agent see another's output during dispatch. The calibrator is the only place findings get reconciled.
- The static layer is ground truth. Agents must not contradict it. If the static layer says "no error" and the agent finds one in the same line, the agent must justify the divergence in `evidence[]`.
- Be ruthless about confidence. The default threshold of 80 is the point of the design.
- Be ruthless about nit caps. A noisy reviewer is a useless reviewer.
