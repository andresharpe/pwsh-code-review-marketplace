# Negative fixture for the file-scope gate.
# Basename does NOT match `*.Tests.ps1` or `Test-*.ps1`, so this file should
# be skipped entirely. Even though it contains `.Count -ge 100`, the scanner
# must not parse it.

$things = 1..200
if ($things.Count -ge 100) {
    Write-Output 'plenty of things'
}
