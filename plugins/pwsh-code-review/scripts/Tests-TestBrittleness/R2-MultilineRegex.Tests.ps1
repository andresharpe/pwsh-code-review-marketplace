# Fixture for PWSH-TEST-002 (multi-line regex against cmdlet output, in an
# assertion).

Describe 'R2' {
    It 'matches a multi-line block - Should -Match' {
        # POSITIVE: Get-Content piped to Should -Match with `\n` regex
        (Get-Content 'log.txt') | Should -Match 'a.*\nb.*\n'
    }

    It 'matches via Assert-True - dotbot style' {
        # POSITIVE: -match operator inside Assert-True
        Assert-True -Condition ((Get-Content 'log.txt') -match 'header\nbody\n')
    }
}
