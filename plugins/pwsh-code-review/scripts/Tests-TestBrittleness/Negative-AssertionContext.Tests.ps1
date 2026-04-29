# Negative fixture: brittle-looking expressions OUTSIDE any assertion context.
# Basename matches *.Tests.ps1 so the file is parsed, but every candidate
# expression sits outside Should/Assert-*/It/Describe.

$things = 1..200

# Top-level — NOT in test context
if ($things.Count -ge 100) {
    Write-Output 'plenty of things'
}

function Get-Things {
    # Function body, NOT a test assertion
    $h = @{ a = 1; b = 2 }
    ($h.Keys)[0]
    1..10 | Sort-Object | Get-Unique | Select-Object -First 1
}
