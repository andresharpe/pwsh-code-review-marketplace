# Positive PWSH-TPL-002 (provable / conf 80) fixture

The token `{{KNOWN_NONEMPTY}}` always renders to a non-empty string
because source.ps1 declares an explicit if/else fallback. The prose
below assumes the substitution may be empty - that conditional is
dead code.

If `{{KNOWN_NONEMPTY}}` above is empty, do nothing. Otherwise iterate.

Should fire PWSH-TPL-002 at confidence 80.
