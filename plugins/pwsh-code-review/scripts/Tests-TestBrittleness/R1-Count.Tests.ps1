# Fixture for PWSH-TEST-001 (`.Count -ge|-eq <int>` with int > 5 in assertion).
# Two positive cases: Pester `Should` and dotbot `Assert-True`.

Describe 'R1-Pester' {
    It 'has many items' {
        $items = 1..20
        ($items.Count) | Should -BeGreaterOrEqual 8     # not a binary -ge expression — does NOT trip R1
        $items.Count -ge 12                              # POSITIVE: standalone but inside It (still tests the rule)
    }
}

# Dotbot-style positive
Assert-True -Condition ($items.Count -ge 8)

# Negative: int <= 5
Assert-True -Condition ($items.Count -ge 3)
