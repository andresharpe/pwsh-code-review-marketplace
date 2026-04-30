#requires -Version 7.4
<#
Bot-detection primitives shared between Get-PriorReviews.ps1 and the
self-test under scripts/Tests-PriorReviews/. Dot-source from both so the
test exercises the production logic instead of a re-implementation.
#>

# Bot logins ending in `[bot]` are the canonical GitHub signal. The known-list
# catches edge cases (some bots run as regular accounts — historically
# CodeRabbit, SonarCloud, self-hosted Renovate, etc.). Match lower-case.
$script:KnownBotLogins = @(
    'coderabbitai'
    'sonarcloud'
    'sonarqubecloud'
    'snyk-bot'
    'sentry-io'
    'deepsource-io'
    'codeclimate'
    # Names called out in issue #25. Modern incarnations all use a `[bot]`
    # suffix (so they're already caught by the regex), but adding them
    # explicitly keeps self-hosted / legacy variants covered.
    'dependabot'
    'dependabot-preview'
    'renovate'
    'renovate-bot'
    'codecov'
    'codecov-commenter'
)

function Test-IsBotAuthor {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Login)
    if (-not $Login) { return $false }
    if ($Login -like '*[[]bot[]]') { return $true }
    $lower = $Login.ToLowerInvariant()
    if ($lower -in $script:KnownBotLogins) { return $true }
    return $false
}
