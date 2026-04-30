# Pattern: agent prompt file

The canonical shape for `plugins/pwsh-code-review/agents/<name>-agent.md`. Reference example: `plugins/pwsh-code-review/agents/markdown-content-agent.md` (one of the cleanest existing prompts).

Sections appear in this order:

1. Frontmatter -- `name` and `description` keys only.
2. `# <Title> agent` heading, followed by one paragraph describing the agent's purpose.
3. `## Inputs` -- list of files the agent must read, with the static-layer cache files called out.
4. `## Scope` -- two sub-bullets: "You own:" listing the rule clusters in scope, and "You do **not** own:" listing the surfaces other agents handle.
5. Named rule sections (`### <RuleClusterName>`), one per group. Inside each section, bullet rules in this shape:
   - `New <pattern>: flag (\`severity\`, conf NN). <One-sentence why and what to recommend.>`
6. `## Output` -- declares the rule namespace (`PWSH-<AGENT>-NNN`).
7. `## Calibration discipline` -- the agent's anti-inflation guidance.

Exemplar skeleton:

```markdown
---
name: <agent-name>
description: <one-line summary suitable for the dispatcher>
---

# <Title> agent

<One paragraph: what this agent reviews and against what.>

## Inputs

Same as other agents. Pay particular attention to:

- `config.psd1` for `<key>`
- `.pwsh-review/cache/static-findings.json` (do not re-flag)

## Scope

You own:

- <bullet>

You do **not** own:

- <bullet>

## High-value rules

### <Rule cluster name>

- New <pattern>: flag (`severity`, conf NN). <fix>.

## Output

Emit per `docs/severity-rubric.md`. Use stable rule IDs in the `PWSH-<AGENT>-NNN` namespace.

## Calibration discipline

You will be tempted to flag every minor <X>. Resist:

- <discipline rule>
```

The agent prompt MUST NOT contain executable code. It is a markdown file consumed by Claude Code's agent runtime, not a script. References to PowerShell APIs are illustrative, not invoked.
