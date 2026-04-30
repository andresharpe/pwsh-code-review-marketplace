# Fixture for PWSH-TEST-007 (a script-scope `function <KnownCmdlet> { ... }`
# inside a test file with no parameters declared — production-code calls that
# pass arguments will silently feed a no-op).

# POSITIVE: Start-Process shadowed with no params; production callers
# passing -FilePath / -ArgumentList / -NoNewWindow will be ignored.
function Start-Process {
    return $null
}

# POSITIVE: Invoke-WebRequest shadowed with empty body, no params declared.
function Invoke-WebRequest {
    @{ StatusCode = 200; Content = '{}' }
}

Describe 'R7' {
    It 'launches' {
        Start-Process notepad.exe -ArgumentList '/foo' -NoNewWindow
        Assert-True -Condition $true
    }

    It 'fetches' {
        $r = Invoke-WebRequest -Uri 'http://x' -Method 'POST' -Body 'b'
        $r.StatusCode | Should -Be 200
    }
}
