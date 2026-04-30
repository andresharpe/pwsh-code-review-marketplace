# Fixture for PWSH-TEST-008 (`Remove-Item` runs after a Should/Assert-*
# but is not inside a `finally` clause; if the assertion throws the
# cleanup is skipped and test state leaks).

Describe 'R8' {
    It 'creates and cleans up' {
        $tmp = Join-Path $TestDrive 'fixture.txt'
        New-Item -ItemType File -Path $tmp | Out-Null
        $tmp | Should -Exist
        # POSITIVE: cleanup follows the assertion, not in a finally block.
        Remove-Item -LiteralPath $tmp -Force
    }

    It 'asserts then deletes' {
        $tmp = Join-Path $TestDrive 'other.txt'
        Set-Content -LiteralPath $tmp -Value 'x'
        Assert-True -Condition (Test-Path $tmp)
        # POSITIVE: cleanup follows an Assert-* call, not in a finally block.
        Remove-Item -LiteralPath $tmp -Force
    }
}
