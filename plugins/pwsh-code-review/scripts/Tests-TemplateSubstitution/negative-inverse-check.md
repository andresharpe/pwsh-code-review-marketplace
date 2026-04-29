# Negative fixture - inverse check ("non-empty" / "not empty")

These prose conditionals check the inverse and should NOT fire PWSH-TPL-002:

If `{{KNOWN_NONEMPTY}}` is non-empty, read each item.

If `{{KNOWN_MAYBE_EMPTY}}` is not empty, use it as a label.
