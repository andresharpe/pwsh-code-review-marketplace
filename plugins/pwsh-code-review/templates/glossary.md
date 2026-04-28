# Glossary

Domain terms used in this codebase. The reviewer uses this file to **avoid** flagging deliberate naming as misnamings. If a term appears here, the agent treats it as authoritative.

Bootstrap drafts entries by mining repeated identifiers and comments. Every drafted entry is marked `<!-- TODO: confirm -->`. Edit definitions, remove entries, add new ones.

## Format

Use this shape per entry:

```markdown
### TermName

One-sentence definition. Plain language.

Used in: `path/to/file.ps1:line`, `path/to/another.ps1:line`
Related: TermB, TermC
```

If a term is an abbreviation or initialism, expand it.

## Entries

<!-- TODO: confirm or replace all entries below. Bootstrap inferred these from repeated usage. -->

### Example

A placeholder entry. Replace with a real domain term.

Used in: (none yet)
Related: (none yet)

---

<!--
Tips when curating this file:

- The reviewer will not "fix" any term listed here. So if you have a name
  that diverges from PowerShell convention deliberately (e.g. domain noun
  not in Get-Verb), document it here to suppress nags.

- Conversely, if a term is *misused* in the codebase, leave it out of the
  glossary. The conventions agent will flag misuses as findings.

- Definitions should be functional, not prose. "X is the unit of work
  scheduled by the dispatcher" beats "X represents the conceptual notion
  of...".

- Cross-link related terms so the reviewer understands the term cluster.
-->
