# Synthetic source for the template-substitution self-tests. Defines two
# tokens via PowerShell's `-replace` operator:
#   {{KNOWN_NONEMPTY}} — has an explicit if/else fallback (always non-empty)
#   {{KNOWN_MAYBE_EMPTY}} — RHS is just a parameter, can be empty

function Build-Prompt {
    param(
        [string]$Template,
        [object]$Task,
        [string]$Caller = ""
    )

    $known = ""
    if ($Task.items -and $Task.items.Count -gt 0) {
        $known = ($Task.items | ForEach-Object { "- $_" }) -join "`n"
    } else {
        $known = "No items listed."
    }

    $prompt = $Template
    $prompt = $prompt -replace '\{\{KNOWN_NONEMPTY\}\}', $known
    $prompt = $prompt -replace '\{\{KNOWN_MAYBE_EMPTY\}\}', $Caller
    return $prompt
}
