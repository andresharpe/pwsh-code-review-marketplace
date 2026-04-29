# Fixture for PWSH-TEST-005 (Should -Match / -match on a Windows-only path
# regex, inside an assertion).

Describe 'R5' {
    It 'Should -Match form' {
        $p = 'C:\foo\bar'
        # POSITIVE: Should -Match form, literal `\\` and no `/`
        $p | Should -Match 'C:\\foo\\bar'
    }

    It 'Assert-True with -match' {
        $p = 'C:\foo\bar'
        # POSITIVE: -match operator inside Assert-True
        Assert-True -Condition ($p -match 'C:\\foo\\bar')
    }
}
