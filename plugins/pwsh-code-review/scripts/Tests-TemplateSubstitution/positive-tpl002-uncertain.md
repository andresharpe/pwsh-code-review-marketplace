# Positive PWSH-TPL-002 (uncertain / conf 60) fixture

The token `{{KNOWN_MAYBE_EMPTY}}` may legitimately be empty - source.ps1
binds it to `$Caller` whose default is the empty string. The prose
conditional is not provably dead, but still suspicious.

If `{{KNOWN_MAYBE_EMPTY}}` is missing, fall back to defaults.

Should fire PWSH-TPL-002 at confidence 60.
