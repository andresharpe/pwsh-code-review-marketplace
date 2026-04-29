# Fixture for PWSH-TEST-005 (Should -Match / -match on a Windows-only path regex).

Describe 'R5' {
    It 'matches a Windows path' {
        $p = 'C:\foo\bar'
        # POSITIVE: Should -Match form, literal `\\` and no `/`
        $p | Should -Match 'C:\\foo\\bar'

        # POSITIVE: -match operator form
        $p -match 'C:\\foo\\bar'
    }
}
