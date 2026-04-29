# Fixture for PWSH-TEST-003 (`Sort-Object | Get-Unique` with ordered consumer).

Describe 'R3' {
    It 'inline form' {
        # POSITIVE: inline indexed
        $first = (1..10 | Sort-Object | Get-Unique)[0]
        Assert-True -Condition ($first -eq 1)
    }

    It 'assigned form' {
        # POSITIVE: assigned, then [0]
        $u = 1..10 | Sort-Object | Get-Unique
        $u[0] | Should -Be 1
    }
}
