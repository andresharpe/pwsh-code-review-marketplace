# Glossary

Domain terms used in `pwsh-code-review-marketplace`. The reviewer uses this file to **avoid** flagging deliberate naming as misnamings. If a term appears here, the agent treats it as authoritative.

## Format

```markdown
### TermName

One-sentence definition.

Used in: `path/to/file.ps1:line`
Related: TermB
```

## Entries

### Agent

A markdown file under `plugins/pwsh-code-review/agents/*.md` containing the prompt for one specialised reviewer (e.g. `conventions-agent`, `diff-bug-agent`). Agents are dispatched in parallel during a review and emit findings as JSON.

Used in: `plugins/pwsh-code-review/agents/*.md`, `commands/pwsh-review.md`
Related: Calibrator, Finding

### Scanner

A PowerShell script under `plugins/pwsh-code-review/scripts/Test-*.ps1` (currently `Test-Brittleness.ps1`, `Test-Coverage.ps1`, `Test-TemplateSubstitution.ps1`) that performs deterministic static analysis as part of the pre-pass. Scanners are ground truth -- agents must not contradict them.

Used in: `plugins/pwsh-code-review/scripts/Test-*.ps1`
Related: Static layer, Pre-pass, Finding

### Calibrator

The agent (`agents/calibrator-agent.md`) that runs after agent dispatch and confirms, downgrades, or drops findings. Never upgrades. The calibrator is the only place findings get reconciled.

Used in: `agents/calibrator-agent.md`, `commands/pwsh-review.md`
Related: Agent, Finding

### Profile

The `.pwsh-review/` directory in a target repo, containing `architecture.md`, `standards.md`, `glossary.md`, `patterns/`, `config.psd1`, `PSScriptAnalyzerSettings.psd1`, and the runtime cache. Created via `/pwsh-review-bootstrap`. Loaded by every reviewer agent on every run.

Used in: `commands/pwsh-review-bootstrap.md`, `scripts/Initialize-ReviewProfile.ps1`, `scripts/Resolve-Profile.ps1`
Related: Bootstrap, Cache

### Prior reviews

Existing review activity from automated bots (Copilot, CodeRabbit, Dependabot) on a PR. Fetched by `Get-PriorReviews.ps1` and surfaced to every dispatched agent so they don't duplicate findings already raised. Cached at `.pwsh-review/cache/prior-reviews.json`.

Used in: `scripts/Get-PriorReviews.ps1`
Related: Agent, Finding

### Hunk-scope

The set of `(file, line range)` tuples defined by the actual diff hunks. Findings whose location is outside the hunks are clamped or filtered before posting. The merger uses this to keep PR review comments inside the visible diff (GitHub rejects out-of-hunk inline comments).

Used in: `scripts/Merge-Findings.ps1`, `scripts/Post-PrReview.ps1`
Related: Finding, Posting

### Severity

One of `blocker`, `major`, `minor`, `nit`, `question`, `praise`. Defined in `docs/severity-rubric.md`. The vocabulary is fixed; new severities are a breaking change.

Used in: `docs/severity-rubric.md`, agent prompts
Related: Confidence, Filter matrix

### Confidence

Integer 0-100 describing how sure the agent is of a finding, independent of severity. The filter matrix in `docs/severity-rubric.md` decides whether to post each finding.

Used in: `docs/severity-rubric.md`, `scripts/Merge-Findings.ps1`
Related: Severity, Filter matrix

### Finding cluster

A group of findings with the same `rule_name`, the same `file`, and contiguous `line` ranges. The merger collapses them into a single comment to reduce noise.

Used in: `scripts/Merge-Findings.ps1`
Related: Finding, Hunk-scope

### Suppression marker

The inline comment `# pwsh-review:disable-next-line <rule>` (or `disable-block`) that suppresses a finding for the next line or enclosing block. Documented in `docs/severity-rubric.md`.

Used in: `docs/severity-rubric.md`
Related: Finding

### Rubric

`docs/severity-rubric.md`. The authoritative document defining severity, confidence, the filter matrix, false-positive filters, the output schema, and the suppression markers. Loaded by every agent.

Used in: `docs/severity-rubric.md`, agent prompts
Related: Severity, Confidence, Filter matrix

### Auto-bump

`.github/workflows/version-bump.yml`. Tags a new minor version `v(N+1).0.0` on every push to `main` (except release commits). PRs do not modify version fields; the workflow owns versioning.

Used in: `.github/workflows/version-bump.yml`
Related: Release

### Self-improvement loop

The standing process in `ideas/reviewer-gap-analysis.md` where external reviewer comments (Copilot, CodeRabbit) that the plugin missed are recorded under "Recently observed gaps", drained as fix-PRs ship, and logged under "Closed gaps". Stop conditions: three consecutive PRs land with zero gaps observed, or only style-class nits remain.

Used in: `ideas/reviewer-gap-analysis.md`
Related: Profile

### Round (loop round)

A discrete iteration of the self-improvement loop: a batch of PRs that drain the current "Recently observed gaps" queue. Each round ends when all queued gaps are closed, after which the loop status updates to wait for the next batch of external observations.

Used in: `ideas/reviewer-gap-analysis.md`
Related: Self-improvement loop
