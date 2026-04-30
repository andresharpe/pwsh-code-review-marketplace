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

    It 'is misled by a literal backslash before `$Name`' {
        $source = '\$Name = "value"'
        # POSITIVE: pattern has `\\$Name` — the first `\` escapes the second,
        # so `$` is NOT regex-escaped. Edge case caught by counting the run
        # of consecutive backslashes (odd = escaped, even = not). The leading
        # `/` avoids tripping PWSH-TEST-005 (Windows-only path heuristic).
        $source | Should -Match '/x \\$Name'
    }
}
