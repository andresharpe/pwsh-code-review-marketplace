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

```bash
/plugin uninstall pwsh-code-review@pwsh-code-review-marketplace
# pull / overwrite the marketplace contents
/plugin install pwsh-code-review@pwsh-code-review-marketplace
```

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
