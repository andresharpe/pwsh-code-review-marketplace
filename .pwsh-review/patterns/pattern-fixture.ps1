# Pattern: scanner self-test fixture.
#
# The canonical shape for plugins/pwsh-code-review/scripts/Tests-<Name>/R<n>-<RuleName>.Tests.ps1.
# Reference: plugins/pwsh-code-review/scripts/Tests-TestBrittleness/R1-Count.Tests.ps1
#
# Each fixture file:
#  - has a leading block comment naming the rule the fixture covers
#  - sets up minimal scaffolding (@(...), [pscustomobject]@{}, etc.)
#  - has at least two POSITIVE cases inside Pester `It` blocks (or top-level
#    Assert-True calls) that the predicate should flag
#  - optionally has explicit NEGATIVE cases at the bottom that the predicate
#    must NOT flag (e.g. value below threshold, op outside the rule's set,
#    member name disjoint from the rule's pattern)
#
# The Run.ps1 script in the same directory asserts:
#  (a) every R<n>-*.Tests.ps1 fires its expected rule at least once
#  (b) Negative-*.Tests.ps1 / Negative-*.ps1 stay clean
#  (c) no cross-rule leak: a finding's rule_name must match the fixture's
#      expected rule (each fixture is scoped to one rule)
#
# Fixtures use Pester scaffolding only as a host for the AST patterns
# under test; they don't need to be valid Pester tests. Assert-True
# (a dotbot-style assertion helper) and Should -BeTrue are both
# recognised by the scanner's Test-IsInAssertion helper.

# Fixture for PWSH-EXAMPLE-001 (loose comparison against a count-shaped
# property). Two positive cases plus negative cases at the end.

$result = [pscustomobject]@{
    SomeCount = 8
}

Describe 'RExample' {
    It 'positive case 1 - dotbot Assert' {
        # POSITIVE: rule should fire here.
        Assert-True -Condition ($result.SomeCount -ge 7)
    }

    It 'positive case 2 - pester pipe' {
        # POSITIVE: rule should also fire.
        ($result.SomeCount -le 9) | Should -BeTrue
    }
}

# NEGATIVE: not in scope for this rule (operator outside the predicate's set,
# threshold below minimum, etc.). The rule must NOT fire here.
Assert-True -Condition ($result.SomeCount -eq 8)
