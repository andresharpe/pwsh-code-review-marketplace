#requires -Version 7.4
<#
.SYNOPSIS
    Fetches prior automated-bot review activity on a GitHub PR and writes it
    to .pwsh-review/cache/prior-reviews.json so dispatched agents can avoid
    duplicating findings raised by Copilot, CodeRabbit, Dependabot, etc.

.DESCRIPTION
    Two execution modes:

      Live mode (`-Pr <number>`)
        Resolves the current repo's owner/name via `gh repo view --json
        owner,name`, then runs a GraphQL query against `gh api graphql`
        fetching reviewThreads(first:100) and reviews(first:50).

      Replay mode (`-InputPath <path>`)
        Reads a previously-saved GraphQL response from disk. Used by the
        self-test under scripts/Tests-PriorReviews/ — exercises the parser
        without requiring network access or a real PR.

    The parser identifies bot authors by login pattern (login ending in
    `[bot]` or matching a known-bot list) and partitions review-thread
    comments into resolved/unresolved. The output schema is consumed by:

      - Phase 4 agent dispatch (each agent sees `unresolved_threads` and
        `top_level_reviews` so it doesn't duplicate prior findings).
      - Merge-Findings.ps1, which renders a "Prior Agent Review Summary"
        section above the per-severity blocks.

.PARAMETER Pr
    GitHub PR number. Required for live mode.

.PARAMETER InputPath
    Path to a JSON file containing a captured GraphQL response. Used in
    place of a live `gh api graphql` call (testing).

.PARAMETER RepoRoot
    Repository root. Output is written under `<RepoRoot>/.pwsh-review/cache/`.

.PARAMETER OutputPath
    Override the default output path.

.PARAMETER Owner
    GitHub owner. Defaults to the value `gh repo view --json owner` returns.
    Useful for replay-mode fixtures that don't carry owner/name in the JSON.

.PARAMETER Repo
    GitHub repo name. Defaults to the value `gh repo view --json name` returns.

.OUTPUTS
    [pscustomobject] with OutputPath, BotsFound, UnresolvedCount,
    ResolvedCount, TopLevelReviewsCount.
#>
[CmdletBinding(DefaultParameterSetName = 'Live')]
[OutputType([pscustomobject])]
param(
    [Parameter(ParameterSetName = 'Live', Mandatory)]
    [int]$Pr,

    [Parameter(ParameterSetName = 'Replay', Mandatory)]
    [string]$InputPath,

    [string]$RepoRoot = (Get-Location).Path,
    [string]$OutputPath,
    [string]$Owner,
    [string]$Repo
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# Plugin version is emitted into the cache for traceability. Resolved lazily
# via dot-source so this script can be exercised in isolation by the self-test.
. (Join-Path $PSScriptRoot '_PluginVersion.ps1')
$pluginRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pluginVersion = Get-PluginVersion -PluginRoot $pluginRoot

# Bot logins ending in `[bot]` are the canonical GitHub signal. The known-list
# catches edge cases (some bots run as regular accounts — e.g. SonarCloud
# previously, CodeRabbit historically). Match lower-case.
$script:KnownBotLogins = @(
    'coderabbitai'
    'sonarcloud'
    'sonarqubecloud'
    'snyk-bot'
    'sentry-io'
    'deepsource-io'
    'codeclimate'
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

function ConvertFrom-PriorReviewsResponse {
    <#
    Parses a GraphQL response object (already deserialised into a hashtable)
    and returns the cache shape we write to disk. Pure function — no I/O.
    Exposed at script scope so the self-test can call it directly.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        $Response
    )

    $unresolved = [System.Collections.Generic.List[object]]::new()
    $resolvedCount = 0
    $topLevel  = [System.Collections.Generic.List[object]]::new()
    $botsSeen  = [System.Collections.Generic.HashSet[string]]::new()

    # The GraphQL response can come back as either a hashtable (when read
    # via -AsHashtable) or a PSCustomObject (when read without). Normalise
    # to indexer-style access by walking through both shapes.
    function Get-Path {
        param($obj, [string[]]$Keys)
        $cur = $obj
        foreach ($k in $Keys) {
            if ($null -eq $cur) { return $null }
            if ($cur -is [hashtable] -or $cur -is [System.Collections.IDictionary]) {
                if ($cur.Contains($k)) { $cur = $cur[$k] } else { return $null }
            } elseif ($cur.PSObject.Properties[$k]) {
                $cur = $cur.$k
            } else {
                return $null
            }
        }
        return $cur
    }

    $pr = Get-Path $Response @('data', 'repository', 'pullRequest')
    if (-not $pr) { return @{
        unresolved_threads     = @()
        resolved_threads_count = 0
        top_level_reviews      = @()
        bots                   = @()
    } }

    $threadNodes = @(Get-Path $pr @('reviewThreads', 'nodes'))
    foreach ($t in $threadNodes) {
        if (-not $t) { continue }
        $isResolved = [bool](Get-Path $t @('isResolved'))
        $commentNodes = @(Get-Path $t @('comments', 'nodes'))
        foreach ($c in $commentNodes) {
            if (-not $c) { continue }
            $login = Get-Path $c @('author', 'login')
            if (-not (Test-IsBotAuthor -Login $login)) { continue }
            [void]$botsSeen.Add($login)

            if ($isResolved) {
                $resolvedCount++
                continue
            }

            [void]$unresolved.Add([ordered]@{
                bot        = $login
                path       = Get-Path $c @('path')
                line       = Get-Path $c @('line')
                body       = Get-Path $c @('body')
                created_at = Get-Path $c @('createdAt')
            })
        }
    }

    $reviewNodes = @(Get-Path $pr @('reviews', 'nodes'))
    foreach ($r in $reviewNodes) {
        if (-not $r) { continue }
        $login = Get-Path $r @('author', 'login')
        if (-not (Test-IsBotAuthor -Login $login)) { continue }
        $body = Get-Path $r @('body')
        if (-not $body) { continue }   # bots often post empty reviews alongside line comments
        [void]$botsSeen.Add($login)

        [void]$topLevel.Add([ordered]@{
            bot        = $login
            state      = Get-Path $r @('state')
            body       = $body
            created_at = Get-Path $r @('createdAt')
        })
    }

    return @{
        unresolved_threads     = @($unresolved)
        resolved_threads_count = $resolvedCount
        top_level_reviews      = @($topLevel)
        bots                   = @($botsSeen | Sort-Object)
    }
}

# --- Driver -----------------------------------------------------------------

if (-not $OutputPath) {
    $cacheDir = Join-Path $RepoRoot '.pwsh-review/cache'
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
    $OutputPath = Join-Path $cacheDir 'prior-reviews.json'
}

$response = $null

if ($PSCmdlet.ParameterSetName -eq 'Replay') {
    if (-not (Test-Path -LiteralPath $InputPath)) {
        throw "Input fixture not found: $InputPath"
    }
    $response = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json -AsHashtable
} else {
    # Live mode. Resolve owner/repo if not supplied.
    if (-not $Owner -or -not $Repo) {
        try {
            $ghJson = gh repo view --json owner,name 2>$null | ConvertFrom-Json
            if (-not $Owner) { $Owner = $ghJson.owner.login }
            if (-not $Repo)  { $Repo  = $ghJson.name }
        } catch {
            Write-Warning "gh repo view failed: $($_.Exception.Message). Writing empty prior-reviews cache."
        }
    }

    if (-not $Owner -or -not $Repo) {
        # Empty cache so downstream readers don't choke.
        $empty = [ordered]@{
            schema_version         = '1'
            plugin_version         = $pluginVersion
            fetched                = (Get-Date).ToUniversalTime().ToString('o')
            pr                     = $Pr
            owner                  = $Owner
            repo                   = $Repo
            bots                   = @()
            unresolved_threads     = @()
            resolved_threads_count = 0
            top_level_reviews      = @()
            note                   = 'Owner/repo could not be resolved; live fetch skipped.'
        }
        $empty | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
        return [pscustomobject]@{
            OutputPath            = $OutputPath
            BotsFound             = @()
            UnresolvedCount       = 0
            ResolvedCount         = 0
            TopLevelReviewsCount  = 0
        }
    }

    $query = @'
query($owner:String!, $name:String!, $number:Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          isResolved
          comments(first: 1) {
            nodes {
              path
              line
              body
              createdAt
              author { login }
            }
          }
        }
      }
      reviews(first: 50) {
        nodes {
          state
          body
          createdAt
          author { login }
        }
      }
    }
  }
}
'@

    try {
        $rawJson = gh api graphql `
            -f "query=$query" `
            -F "owner=$Owner" `
            -F "name=$Repo" `
            -F "number=$Pr" 2>$null
        if (-not $rawJson) { throw "Empty response from gh api graphql." }
        $response = $rawJson | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Warning "Failed to fetch prior reviews via gh api graphql: $($_.Exception.Message). Writing empty cache."
        $empty = [ordered]@{
            schema_version         = '1'
            plugin_version         = $pluginVersion
            fetched                = (Get-Date).ToUniversalTime().ToString('o')
            pr                     = $Pr
            owner                  = $Owner
            repo                   = $Repo
            bots                   = @()
            unresolved_threads     = @()
            resolved_threads_count = 0
            top_level_reviews      = @()
            note                   = "GraphQL fetch failed: $($_.Exception.Message)"
        }
        $empty | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
        return [pscustomobject]@{
            OutputPath            = $OutputPath
            BotsFound             = @()
            UnresolvedCount       = 0
            ResolvedCount         = 0
            TopLevelReviewsCount  = 0
        }
    }
}

$parsed = ConvertFrom-PriorReviewsResponse -Response $response

$out = [ordered]@{
    schema_version         = '1'
    plugin_version         = $pluginVersion
    fetched                = (Get-Date).ToUniversalTime().ToString('o')
    pr                     = $Pr
    owner                  = $Owner
    repo                   = $Repo
    bots                   = $parsed.bots
    unresolved_threads     = $parsed.unresolved_threads
    resolved_threads_count = $parsed.resolved_threads_count
    top_level_reviews      = $parsed.top_level_reviews
}
$out | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM

[pscustomobject]@{
    OutputPath            = $OutputPath
    BotsFound             = $parsed.bots
    UnresolvedCount       = $parsed.unresolved_threads.Count
    ResolvedCount         = $parsed.resolved_threads_count
    TopLevelReviewsCount  = $parsed.top_level_reviews.Count
}
