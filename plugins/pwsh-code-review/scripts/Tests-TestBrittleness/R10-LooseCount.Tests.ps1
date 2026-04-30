# Fixture for PWSH-TEST-010 (loose `-ge|-le|-gt|-lt <int>` against a compound
# Count/Length-shaped property). Disjoint from PWSH-TEST-001 by name pattern:
# R001 owns bare `.Count`; R010 owns the compound *Count / *Length names.

$result = [pscustomobject]@{
    RestoredCount = 8
    MessageLength = 12
    PrintedCount  = 5
}

Describe 'R10' {
    It 'restores at least 7 of 8 - dotbot Assert' {
        # POSITIVE: -ge against a compound *Count name; setup makes 8 the
        # right value, but -ge 7 also passes when one restore goes missing.
        Assert-True -Condition ($result.RestoredCount -ge 7)
    }

    It 'message length under cap - pester pipe' {
        # POSITIVE: -le against a compound *Length name.
        ($result.MessageLength -le 20) | Should -BeTrue
    }

    It 'too many printed warnings - pester pipe' {
        # POSITIVE: -gt against a compound *Count name.
        ($result.PrintedCount -gt 3) | Should -BeTrue
    }
}

# NEGATIVE: value <= 1 is filtered out (trivial threshold).
Assert-True -Condition ($result.RestoredCount -gt 1)

# NEGATIVE: -eq is not in R010's operator set.
Assert-True -Condition ($result.RestoredCount -eq 8)
