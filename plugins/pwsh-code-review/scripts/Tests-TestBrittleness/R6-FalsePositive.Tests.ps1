# Fixture for PWSH-TEST-006 (an `if (Test-Path ...) { ...assertions... }`
# wrapper inside an `It` body with no `else` clause; if the probe returns
# false the test silently passes).

Describe 'R6' {
    It 'asserts only when config exists' {
        # POSITIVE: Test-Path gates the assertion, no `else` branch.
        if (Test-Path 'config.json') {
            $cfg = Get-Content 'config.json' -Raw
            $cfg | Should -Not -BeNullOrEmpty
        }
    }

    It 'asserts only when module is loaded' {
        # POSITIVE: Get-Command gates the assertion, no `else` branch.
        if (Get-Command Get-Foo -ErrorAction SilentlyContinue) {
            (Get-Foo) | Should -Be 'bar'
        }
    }
}
