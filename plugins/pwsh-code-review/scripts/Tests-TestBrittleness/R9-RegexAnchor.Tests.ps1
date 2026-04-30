# Fixture for PWSH-TEST-009 (regex literal in `-match` or `Should -Match`
# containing an unescaped `$word` sequence — `$` is the regex end-of-line
# anchor, so the assertion does not match a literal PowerShell `$variable`
# in the input string).

Describe 'R9' {
    It 'matches a literal $variable token' {
        $source = 'function Get-Foo { param($Name) }'
        # POSITIVE: pattern contains `$Name` with `$` unescaped; should be `\$Name`.
        $source | Should -Match 'param\($Name\)'
    }

    It 'matches a `$value` reference inside a where-object' {
        $source = 'Where-Object { $_ -eq 1 }'
        # POSITIVE: pattern contains `$value` with `$` unescaped.
        Assert-True -Condition ($source -match 'Where-Object \{ \$_ -eq $value \}')
    }
}
