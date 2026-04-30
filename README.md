# pwsh-code-review-marketplace

Local Claude Code marketplace hosting the `pwsh-code-review` plugin.

## Install

From the directory above this one (or anywhere, with an absolute path):

```bash
# 1. Add this folder as a marketplace
/plugin marketplace add ./pwsh-code-review-marketplace

# 2. Install the plugin from it
/plugin install pwsh-code-review@pwsh-code-review-marketplace
```

To verify:

```bash
/plugin list
```

## Layout

```
pwsh-code-review-marketplace/
├── .claude-plugin/
│   └── marketplace.json         # marketplace catalog
├── plugins/
│   └── pwsh-code-review/        # the plugin
│       ├── .claude-plugin/plugin.json
│       ├── commands/            # /pwsh-review, /pwsh-review-bootstrap
│       ├── agents/              # 5 reviewers + calibrator
│       ├── skills/              # bootstrap, static-analysis, ast-context
│       ├── scripts/             # the deterministic pwsh 7+ scripts
│       ├── templates/           # bootstrap output templates
│       ├── docs/                # principles + severity rubric
│       └── README.md            # full plugin docs
└── README.md                    # this file
```

## Updating the plugin

One command from a shell:

```bash
pwsh ./scripts/Update-LocalPluginInstall.ps1
```

What it does:

- Pulls the latest `main` (skip with `-NoPull`).
- Repoints Claude Code's marketplace registration at this repo's path (handles the case where the registration is stale or pointing at a different folder).
- **Always** clears the plugin cache (`~/.claude/plugins/cache/pwsh-code-review-marketplace/`).
- Drops the installed-plugin entry so Claude Code re-extracts the plugin from the fresh marketplace source.

After it finishes, restart Claude Code, **or** run this in any session:

```
/plugin install pwsh-code-review@pwsh-code-review-marketplace
```

Pass `-DryRun` to preview the changes without writing anything. Pass `-RepoRoot` and `-PluginsRoot` to override the default paths (the latter is useful on macOS/Linux or when `$env:CLAUDE_PLUGINS_ROOT` is set).

If you prefer to do it interactively from inside Claude Code (no script run), use:

```
/plugin marketplace update pwsh-code-review-marketplace
```

That works when the marketplace is already registered at the correct path; the script above is the right choice when the registration is stale, missing, or you want a single shell command.

## Removing entirely

```bash
/plugin marketplace remove pwsh-code-review-marketplace
```

## Once installed

```bash
# from inside any pwsh project repo:
/pwsh-review-bootstrap         # one-time profile generation
/pwsh-review                   # review staged + working changes
/pwsh-review --pr 42           # review PR via gh CLI
```

See `plugins/pwsh-code-review/README.md` for full plugin documentation.

## Contributing

After cloning, activate the bundled gitleaks pre-commit hook so secrets cannot land in commits:

```bash
git config core.hooksPath .githooks
```

The hook scans staged changes with `gitleaks protect --staged` and aborts the commit on any finding. Install gitleaks first: https://github.com/gitleaks/gitleaks

## License

MIT. See [LICENSE](LICENSE).
