# Fixture for PWSH-TEST-001 (`.Count -ge|-eq <int>` with int > 5 inside an
# assertion). Two positive cases: dotbot `Assert-True -Condition (...)` and
# `... | Should -BeTrue` pipe form.

$items = 1..20

Describe 'R1' {
    It 'has many items - dotbot style' {
        # POSITIVE: int > 5 inside Assert-True
        Assert-True -Condition ($items.Count -ge 12)
    }

    It 'has many items - pester pipe' {
        # POSITIVE: int > 5 piped into Should
        ($items.Count -ge 8) | Should -BeTrue
    }
}

# NEGATIVE: int <= 5 (below threshold)
Assert-True -Condition ($items.Count -ge 3)
