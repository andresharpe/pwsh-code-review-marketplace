# Fixture for PWSH-TEST-002 (multi-line regex on cmdlet output).

Describe 'R2' {
    It 'matches a multi-line block' {
        # POSITIVE: Get-Content output, regex contains \n
        (Get-Content 'log.txt') -match 'header\nbody\n'

        # POSITIVE: Should -Match form
        (Get-Content 'log.txt') | Should -Match 'a.*\nb.*\n'
    }
}
