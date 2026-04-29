# Negative fixture - known token, no dead conditional

This prompt references `{{KNOWN_NONEMPTY}}` and `{{KNOWN_MAYBE_EMPTY}}`
without any "if empty" prose. Should produce zero findings.

Pre-specified items:
{{KNOWN_NONEMPTY}}

Caller context: {{KNOWN_MAYBE_EMPTY}}
