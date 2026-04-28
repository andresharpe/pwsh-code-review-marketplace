# Severity and confidence rubric

Every finding has two scores: severity (how much the reader should care) and confidence (how sure the agent is). They are independent. A high-severity finding at low confidence still gets posted, hedged. A low-severity finding at high confidence might still get suppressed.

## Severity levels

### `blocker`

The PR should not merge as-is. Correctness bugs in the diff, security regressions, breaking changes to public surface without a deprecation path, secrets in the diff, anything that fails the build or breaks callers.

**Test the agent must pass to use `blocker`:** name a concrete consequence in one sentence. "Caller `X` at `path:line` will receive `$null` instead of `[Result]` and crash on the property access at `path:line`." Vague "this could break things" is not a blocker.

If every PR has blockers, the threshold is too low.

### `major`

Real problem, fix before merge unless there is a deliberate decision to defer. Wrong error handling, missing test for a new branch, scope leak, cross-platform regression, idempotency violation, concurrency hazard, untested public surface change.

**Test:** name a future failure mode. "This leaks file handles, will exhaust on long-running sessions." "This is not idempotent, will duplicate on retry." Vague "this is not great" is not a major.

This is where most of the reviewer's value lives. Optimise the agents for surfacing majors.

### `minor`

Real but not urgent. Suboptimal pattern, missing comment-based help on internal function, output type declaration missing, mild performance issue (`+=` in a non-hot loop), small inconsistency with `patterns/`. Author should fix in this PR if cheap, follow-up otherwise.

**Test:** point to `standards.md` or `patterns/` for the canonical version. If the rule is not written down, it is a `nit`, not a `minor`.

### `nit`

Style, taste, micro-preference. Variable naming, parameter ordering, comment wording, choice between two equivalent idioms. The author can take it or leave it.

**Test:** phrase as suggestion not instruction. "Consider X" not "use X". Mark nits explicitly so the author knows they are optional.

`nit` findings are capped per review (default 3). They are exactly the kind of pedantic noise that makes reviewers feel like nags.

### `question`

Not a finding, a request for clarification. "Is this intentional?" "Why this approach over X?" "Did you mean to remove this guard?"

**Test:** does not pair with a suggested change. The whole point is the agent is asking, not telling.

### `praise`

Explicitly call out a particularly clean solution, a good test, a clever fix. Capped at 1 per review so it stays meaningful.

**Test:** would a senior engineer reading this PR also notice this and want to point it out? If not, drop it.

## Confidence levels

The agent assigns 0-100 based on the strength of evidence:

| Score | Meaning |
| ----- | ------- |
| 0-24  | Not confident, probable false positive |
| 25-49 | Somewhat confident, might be real |
| 50-74 | Moderately confident, real but verification incomplete |
| 75-89 | Highly confident, evidence is clear |
| 90-100 | Certain, the consequence is mechanically reproducible |

Confidence is calibrated by the calibrator agent (see `agents/calibrator-agent.md`). Agents tend to over-rate their own findings; the calibrator's job is to challenge anything 80+ that does not have specific evidence attached.

## The filter matrix

Findings are filtered by severity x confidence:

| Severity   | conf < 60 | conf 60-79             | conf 80-100         |
| ---------- | --------- | ---------------------- | ------------------- |
| `blocker`  | drop      | post (hedge wording)   | post                |
| `major`    | drop      | post                   | post                |
| `minor`    | drop      | drop                   | post                |
| `nit`      | drop      | drop                   | post (cap at 3)     |
| `question` | drop      | post                   | post                |
| `praise`   | n/a       | n/a                    | post (cap at 1)     |

The `nit` cap is the key noise-control lever. Without it the agents will find twenty stylistic things per review and bury the major findings.

## Hedging language for low-confidence blockers

When a `blocker` posts at confidence 60-79, the wording shifts from assertive to investigative:

- Assertive (80+): "This breaks the caller at `path:line` because the return type changed from `[string]` to `[pscustomobject]`."
- Hedged (60-79): "This looks like it might break the caller at `path:line` because the return type appears to change. Can you confirm the caller still works?"

Never hedge a high-confidence finding. Hedging high confidence reads as evasive and trains readers to ignore the agent.

## False-positive filters

Findings are dropped before scoring if any of these are true:

- Pre-existing issue, not introduced by this PR.
- Already flagged by the static analysis layer (PSScriptAnalyzer, Gitleaks, etc).
- Inside a block with a `# pwsh-review:disable-next-line <rule>` or `# pwsh-review:disable-block <rule>` comment.
- Inside generated code (matched by `.pwsh-review/generated-paths.json`).
- Pedantic nitpick with no concrete consequence.
- Quality issue that is not in `standards.md`.
- Prose-only typo, grammar, or punctuation issue in markdown, comment-based help, or comments that has no runtime impact. Exceptions: typos in user-facing CLI output or error messages, in function/parameter names, or that break a markdown link target. Per `docs/principles.md` rule 19.

## Output schema

Findings emit as JSON between agents and the merger:

```json
{
  "agent": "diff-bug",
  "severity": "major",
  "confidence": 85,
  "file": "src/Modules/DotbotCore/Public/New-Worktree.ps1",
  "line_start": 42,
  "line_end": 48,
  "rule": "PWSH-DIFF-002",
  "message": "Removed [ValidateNotNullOrEmpty()] from -Path parameter.",
  "consequence": "Callers in server.ps1:120 and tests/New-Worktree.Tests.ps1:55 rely on the validation; without it, an empty path will reach Join-Path and produce a confusing PathTooLong error.",
  "fix": "Restore the validation attribute on the -Path parameter.",
  "fix_snippet": "[Parameter(Mandatory)]\n[ValidateNotNullOrEmpty()]\n[string]$Path",
  "evidence": [
    "server.ps1:120",
    "tests/New-Worktree.Tests.ps1:55"
  ]
}
```

The merger groups by severity, then by file, deduplicates similar findings into clusters, applies caps, and renders the final review. See `scripts/Merge-Findings.ps1`.

## Calibration loop

The calibrator agent reviews each finding and may:

- **Confirm** - leave severity and confidence as-is.
- **Downgrade severity** - "you marked this `blocker`, but the consequence is recoverable; downgrading to `major`."
- **Downgrade confidence** - "you marked this 90, but the evidence is `evidence[0]` only; the call site might be guarded elsewhere; downgrading to 70."
- **Drop** - "this contradicts a finding from the static layer; dropping."
- **Reword** - "the message asserts but the confidence is 65; rewording as a hedge."

The calibrator never upgrades severity or confidence. Inflation is the failure mode it exists to prevent.
