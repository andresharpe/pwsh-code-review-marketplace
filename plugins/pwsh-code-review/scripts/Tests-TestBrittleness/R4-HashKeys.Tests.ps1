# Fixture for PWSH-TEST-004 (ordered access on hashtable .Keys).

Describe 'R4' {
    It 'indexes into .Keys' {
        $h = @{ a = 1; b = 2; c = 3 }
        # POSITIVE: ($h.Keys)[0] inside It
        $first = ($h.Keys)[0]
        Assert-True -Condition ($first -eq 'a')
    }

    It 'selects first key via pipeline' {
        $h = @{ x = 1; y = 2 }
        # POSITIVE: $h.Keys | Select-Object -First 1
        $h.Keys | Select-Object -First 1 | Should -Be 'x'
    }
}
