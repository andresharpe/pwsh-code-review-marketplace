#requires -Version 7.4
<#
.SYNOPSIS
    Posts the merged review as a single GitHub PR review with per-finding
    inline comments (each gets its own GitHub Resolve button).

.DESCRIPTION
    Reads `.pwsh-review/cache/merged-findings.json` (produced by
    Merge-Findings.ps1) and `.pwsh-review/cache/diff-context.json`, builds a
    `POST /repos/.../pulls/.../reviews` payload, and submits it via
    `gh api --input <tempfile>`.

    Why per-finding comments instead of one big comment:
      - Each finding gets its own GitHub Resolve button.
      - Suggested fixes render as a clickable Apply button.
      - The review `body` stays summary-only (counts + verdict + optional
        prior-review table + an optional Praise section) so the human
        reviewer can scan the PR view.

    Praise findings are an exception to the per-finding-inline rule: they
    are rendered as bullets in the body's "Praise" section, not as
    inline review comments, so they do not create resolvable threads the
    author has to dismiss (praise has nothing for the author to act on).

    The review body and every comment body is filtered to ASCII before
    posting. UTF-8 dashes, arrows, smart quotes, etc. get mangled when
    piped through bash on Windows; the legacy review skill learned this the
    hard way. Conversion is handled in `ConvertTo-Ascii`.

    Verdict-to-event mapping (built in Merge-Findings.ps1, consumed here):
      - `ship`              -> APPROVE
      - `fix majors first`  -> REQUEST_CHANGES
      - `needs rework`      -> REQUEST_CHANGES

    Hunk-line constraints: GitHub rejects review comments whose `line` does
    not fall inside an actual diff hunk for the file. For each finding, the
    builder picks the closest in-hunk line. If no hunk for the file exists,
    the comment attaches to the file itself (no `line`); GitHub renders it
    as a file-level comment.

.PARAMETER RepoRoot
    Repository root.

.PARAMETER Pr
    GitHub PR number.

.PARAMETER MergedFindingsPath
    Override the input path. Defaults to `.pwsh-review/cache/merged-findings.json`.

.PARAMETER DiffContextPath
    Override the diff-context input. Defaults to
    `.pwsh-review/cache/diff-context.json`.

.PARAMETER PriorReviewsPath
    Override the prior-reviews input (used to render the prior-review
    summary table inside the review body). Defaults to
    `.pwsh-review/cache/prior-reviews.json`.

.PARAMETER DryRunPath
    Write the payload JSON to this path instead of posting. Used by the
    self-test under `scripts/Tests-PostReview/`.

.PARAMETER Owner
    GitHub owner. Defaults to the value `gh repo view --json owner` returns.

.PARAMETER Repo
    GitHub repo name. Defaults to the value `gh repo view --json name` returns.

.OUTPUTS
    [pscustomobject] with the payload path, comment count, event, and
    (in live mode) the response from `gh api`.
#>
[CmdletBinding(DefaultParameterSetName = 'Live')]
[OutputType([pscustomobject])]
param(
    [Parameter(ParameterSetName = 'Live', Mandatory)]
    [int]$Pr,

    [string]$RepoRoot = (Get-Location).Path,
    [string]$MergedFindingsPath,
    [string]$DiffContextPath,
    [string]$PriorReviewsPath,

    [Parameter(ParameterSetName = 'DryRun', Mandatory)]
    [string]$DryRunPath,

    [string]$Owner,
    [string]$Repo
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

. (Join-Path $PSScriptRoot '_PluginVersion.ps1')
$pluginRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pluginVersion = Get-PluginVersion -PluginRoot $pluginRoot

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$cacheDir = Join-Path $RepoRoot '.pwsh-review/cache'

if (-not $MergedFindingsPath) { $MergedFindingsPath = Join-Path $cacheDir 'merged-findings.json' }
if (-not $DiffContextPath)    { $DiffContextPath    = Join-Path $cacheDir 'diff-context.json' }
if (-not $PriorReviewsPath)   { $PriorReviewsPath   = Join-Path $cacheDir 'prior-reviews.json' }

# --- Helpers ----------------------------------------------------------------

function ConvertTo-Ascii {
    <#
    Replace UTF-8 punctuation that mangles when piped through bash on Windows.
    Anything outside ASCII that isn't in the explicit mapping gets dropped.
    Newlines (LF/CRLF) and tabs are preserved.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Text)
    if (-not $Text) { return '' }

    $map = @{
        [char]0x2014 = '--'   # em dash
        [char]0x2013 = '-'    # en dash
        [char]0x2192 = '->'   # right arrow
        [char]0x2190 = '<-'   # left arrow
        [char]0x2194 = '<->'  # left-right arrow
        [char]0x21D2 = '=>'   # right double arrow
        [char]0x2265 = '>='   # greater-or-equal
        [char]0x2264 = '<='   # less-or-equal
        [char]0x2260 = '!='   # not-equal
        [char]0x2713 = '[x]'  # check
        [char]0x2717 = '[!]'  # ballot X
        [char]0x2026 = '...'  # horizontal ellipsis
        [char]0x2018 = "'"    # left single quote
        [char]0x2019 = "'"    # right single quote
        [char]0x201C = '"'    # left double quote
        [char]0x201D = '"'    # right double quote
        [char]0x00A0 = ' '    # non-breaking space
        [char]0x2022 = '*'    # bullet
        [char]0x00B7 = '*'    # middle dot
    }

    $sb = [System.Text.StringBuilder]::new($Text.Length)
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -le 0x7E -and $code -ge 0x20) {
            [void]$sb.Append($ch)
        } elseif ($code -in @(9, 10, 13)) {   # tab, LF, CR
            [void]$sb.Append($ch)
        } elseif ($map.ContainsKey($ch)) {
            [void]$sb.Append($map[$ch])
        }
        # else: drop the character silently
    }
    return $sb.ToString()
}

function Get-VerdictEvent {
    <#
    Maps the verdict produced by Merge-Findings.ps1 to the GitHub review
    event. APPROVE on a self-PR is rejected by the API; in that case, the
    caller should fall back to COMMENT, but we don't try to detect ownership
    here (it's an operator concern).
    #>
    param([string]$Verdict)
    switch ($Verdict) {
        'ship'              { return 'APPROVE' }
        'fix majors first'  { return 'REQUEST_CHANGES' }
        'needs rework'      { return 'REQUEST_CHANGES' }
        default             { return 'COMMENT' }
    }
}

function Get-HunksByFile {
    param($DiffContext)
    $byFile = @{}
    if (-not $DiffContext) { return $byFile }
    $hunks = if ($DiffContext.PSObject.Properties['changed_hunks']) { @($DiffContext.changed_hunks) } else { @() }
    foreach ($h in $hunks) {
        if (-not $h) { continue }
        $f = $h.file
        if (-not $byFile.ContainsKey($f)) { $byFile[$f] = @() }
        $byFile[$f] += [pscustomobject]@{
            start = [int]$h.line_start
            end   = [int]$h.line_end
        }
    }
    return $byFile
}

function Get-PinnableLine {
    <#
    Pick the line GitHub will accept for an inline comment on $File at
    desired $Line. Strategy:
      1. If $Line is inside any hunk for the file: keep it AND return the
         hunk's index so the caller can verify two endpoints fall inside
         the SAME hunk before emitting a multi-line range comment.
      2. Otherwise, pick the first hunk's line_start (closest pinnable
         anchor) and signal that the original line was clamped.
      3. If the file has no hunks at all (extremely rare for findings on
         a changed file): return $null. Caller posts a file-level comment.
    Returns @{ line = <int|null>; clamped = <bool>; hunk_index = <int|null> }.
    The hunk_index is 0-based; -1 means clamped (no exact match).
    #>
    param(
        [hashtable]$HunksByFile,
        [string]$File,
        [int]$Line
    )
    if (-not $HunksByFile.ContainsKey($File)) {
        return @{ line = $null; clamped = $false; hunk_index = $null }
    }
    $hunks = @($HunksByFile[$File])
    if ($hunks.Count -eq 0) {
        return @{ line = $null; clamped = $false; hunk_index = $null }
    }
    for ($i = 0; $i -lt $hunks.Count; $i++) {
        $h = $hunks[$i]
        if ($Line -ge $h.start -and $Line -le $h.end) {
            return @{ line = $Line; clamped = $false; hunk_index = $i }
        }
    }
    # Outside every hunk. Anchor to the first hunk's start.
    return @{ line = $hunks[0].start; clamped = $true; hunk_index = -1 }
}

function ConvertTo-CommentBody {
    <#
    Turn a finding into the inline comment body. Includes severity,
    confidence, rule, message, optional consequence + fix + suggestion
    block. ASCII-folded.
    #>
    param($Finding)

    $sev  = ConvertTo-Ascii ($Finding.severity ?? 'minor')
    $rule = if ($Finding.PSObject.Properties['rule'] -and $Finding.rule) {
        " [$(ConvertTo-Ascii $Finding.rule)]"
    } else { '' }

    $confDisplay = if ($Finding.PSObject.Properties['static'] -and [bool]$Finding.static) { 'static' }
                   else { "$([int]$Finding.confidence)" }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("**[$sev] ($confDisplay)**$rule")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine((ConvertTo-Ascii $Finding.message))

    if ($Finding.PSObject.Properties['consequence'] -and $Finding.consequence) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine((ConvertTo-Ascii $Finding.consequence))
    }
    if ($Finding.PSObject.Properties['fix'] -and $Finding.fix) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("Fix: " + (ConvertTo-Ascii $Finding.fix))
    }
    if ($Finding.PSObject.Properties['fix_snippet'] -and $Finding.fix_snippet) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('```suggestion')
        [void]$sb.AppendLine((ConvertTo-Ascii $Finding.fix_snippet))
        [void]$sb.AppendLine('```')
    }
    return $sb.ToString().TrimEnd()
}

function Build-ReviewBody {
    <#
    Summary-only review body: counts, verdict, optional prior-review table,
    and an optional praise block. Per-finding details for actionable
    severities (blocker/major/minor/nit/question) live in the inline
    comments. Praise is rendered here instead of as an inline comment so
    it does not create a resolvable thread the author has to dismiss.
    #>
    param($Counts, [string]$Verdict, $PriorReviews, [string]$Version, $Praises)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("## Code review summary")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("_pwsh-code-review v$($Version)_")
    [void]$sb.AppendLine()

    $line = "{0} blocker, {1} major, {2} minor, {3} nit, {4} question" -f `
        $Counts.blocker, $Counts.major, $Counts.minor, $Counts.nit, $Counts.question
    [void]$sb.AppendLine($line)
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("Verdict: **$Verdict**")
    [void]$sb.AppendLine()

    # Prior automated reviews (if cache present and non-empty).
    if ($PriorReviews) {
        $unresolved = @()
        $resolved   = 0
        $bots       = @()
        if ($PriorReviews.PSObject.Properties['unresolved_threads']) { $unresolved = @($PriorReviews.unresolved_threads) }
        if ($PriorReviews.PSObject.Properties['resolved_threads_count']) { $resolved = [int]$PriorReviews.resolved_threads_count }
        if ($PriorReviews.PSObject.Properties['bots']) { $bots = @($PriorReviews.bots) }

        if ($unresolved.Count -gt 0 -or $resolved -gt 0) {
            [void]$sb.AppendLine("### Prior agent review summary")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("Bots seen: " + ((($bots | ForEach-Object { ConvertTo-Ascii $_ }) -join ', ') ?? '(none)'))
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("- Unresolved bot threads: $($unresolved.Count)")
            [void]$sb.AppendLine("- Resolved bot threads: $resolved")
            [void]$sb.AppendLine()
        }
    }

    if ($Praises -and @($Praises).Count -gt 0) {
        [void]$sb.AppendLine("### Praise")
        [void]$sb.AppendLine()
        foreach ($p in @($Praises)) {
            $rule = if ($p.PSObject.Properties['rule'] -and $p.rule) {
                " [$(ConvertTo-Ascii $p.rule)]"
            } else { '' }
            $loc = if ($p.PSObject.Properties['file'] -and $p.file) {
                $lineStr = if ($p.PSObject.Properties['line_start'] -and $p.line_start) { ":$([int]$p.line_start)" } else { '' }
                " ($(ConvertTo-Ascii $p.file)$lineStr)"
            } else { '' }
            $msg = ConvertTo-Ascii ($p.message ?? '')
            [void]$sb.AppendLine("- **praise**$rule$loc - $msg")
        }
        [void]$sb.AppendLine()
    }

    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("Per-finding details are inline. Each has its own Resolve button.")
    return ConvertTo-Ascii $sb.ToString().TrimEnd()
}

# --- Driver -----------------------------------------------------------------

if (-not (Test-Path -LiteralPath $MergedFindingsPath)) {
    throw "merged-findings.json not found at $MergedFindingsPath. Run Merge-Findings.ps1 first."
}
$merged = Get-Content -LiteralPath $MergedFindingsPath -Raw | ConvertFrom-Json

$diffContext = $null
if (Test-Path -LiteralPath $DiffContextPath) {
    $diffContext = Get-Content -LiteralPath $DiffContextPath -Raw | ConvertFrom-Json
}
$priorReviews = $null
if (Test-Path -LiteralPath $PriorReviewsPath) {
    $priorReviews = Get-Content -LiteralPath $PriorReviewsPath -Raw | ConvertFrom-Json
}

$counts  = $merged.counts
$verdict = $merged.verdict
$event   = Get-VerdictEvent -Verdict $verdict

# Praise is rendered in the review body, not as inline review comments,
# so it doesn't create a resolvable thread the author has to dismiss
# (it has nothing for them to act on).
$praises = @(@($merged.findings) | Where-Object { $_ -and $_.severity -eq 'praise' })

$body    = Build-ReviewBody -Counts $counts -Verdict $verdict -PriorReviews $priorReviews -Version $pluginVersion -Praises $praises

# Per-finding inline comments.
$hunksByFile = Get-HunksByFile -DiffContext $diffContext
$comments = [System.Collections.Generic.List[object]]::new()
$skipped  = 0
$clamped  = 0

foreach ($f in @($merged.findings)) {
    if (-not $f) { continue }
    if ($f.severity -eq 'praise') { continue }
    if (-not $f.PSObject.Properties['file'] -or -not $f.file) { $skipped++; continue }

    $desiredLine = if ($f.PSObject.Properties['line_start'] -and $f.line_start) { [int]$f.line_start }
                   elseif ($f.PSObject.Properties['line'] -and $f.line) { [int]$f.line }
                   else { 0 }

    $pin = Get-PinnableLine -HunksByFile $hunksByFile -File $f.file -Line $desiredLine
    $commentBody = ConvertTo-CommentBody -Finding $f

    $entry = [ordered]@{
        path = $f.file
        body = $commentBody
        side = 'RIGHT'
    }

    if ($pin.line) {
        $entry['line'] = [int]$pin.line
        if ($f.PSObject.Properties['line_end'] -and $f.line_end -and `
            [int]$f.line_end -ne [int]$pin.line -and `
            -not $pin.clamped) {
            # Multi-line range. GitHub requires both endpoints to fall
            # inside the SAME diff hunk — emit start_line/start_side only
            # when both pins are exact AND share a hunk index. Anything
            # else collapses to a single-line comment on the start pin.
            $endLine = [int]$f.line_end
            $endPin  = Get-PinnableLine -HunksByFile $hunksByFile -File $f.file -Line $endLine
            $bothExact = $endPin.line -and -not $endPin.clamped
            $sameHunk  = $bothExact -and ($pin.hunk_index -eq $endPin.hunk_index)
            if ($sameHunk -and $endPin.line -ne $pin.line) {
                $entry['start_line'] = [Math]::Min([int]$pin.line, [int]$endPin.line)
                $entry['line']       = [Math]::Max([int]$pin.line, [int]$endPin.line)
                $entry['start_side'] = 'RIGHT'
            }
            # Else: stay single-line on $pin.line. Two-hunk ranges would
            # produce an invalid review payload that GitHub rejects.
        }
        if ($pin.clamped) { $clamped++ }
    }
    # No `line` -> file-level comment (rare; finding's line isn't anywhere
    # in the diff). GitHub still accepts {path, body} without a line.

    [void]$comments.Add($entry)
}

# Build the full payload.
$payload = [ordered]@{
    event    = $event
    body     = $body
    comments = @($comments)
}

# Write to UTF8NoBOM tempfile (or DryRunPath) before invoking gh api. The
# legacy review skill learned that piping JSON through bash on Windows
# produces mangled UTF-8 — using a tempfile and `--input` sidesteps it.
$payloadJson = $payload | ConvertTo-Json -Depth 30

if ($PSCmdlet.ParameterSetName -eq 'DryRun') {
    $dryDir = Split-Path -Parent $DryRunPath
    if ($dryDir -and -not (Test-Path -LiteralPath $dryDir)) {
        New-Item -ItemType Directory -Path $dryDir -Force | Out-Null
    }
    $payloadJson | Set-Content -LiteralPath $DryRunPath -Encoding utf8NoBOM

    return [pscustomobject]@{
        Mode          = 'DryRun'
        PayloadPath   = $DryRunPath
        Event         = $event
        Verdict       = $verdict
        CommentCount  = $comments.Count
        ClampedLines  = $clamped
        SkippedCount  = $skipped
    }
}

# Live mode: resolve owner/repo if not supplied.
if (-not $Owner -or -not $Repo) {
    try {
        $ghJson = gh repo view --json owner,name 2>$null | ConvertFrom-Json
        if (-not $Owner) { $Owner = $ghJson.owner.login }
        if (-not $Repo)  { $Repo  = $ghJson.name }
    } catch {
        throw "Could not resolve owner/repo via gh: $($_.Exception.Message)"
    }
}
if (-not $Owner -or -not $Repo) {
    throw "Owner/repo could not be resolved. Pass -Owner and -Repo explicitly."
}

# Persist the payload at a stable, predictable path under the cache dir so
# the returned PayloadPath is meaningful for debugging/forensics. Overwritten
# on each run; the cache dir is gitignored so this isn't committed.
$payloadPath = Join-Path $cacheDir 'last-review-payload.json'
$payloadJson | Set-Content -LiteralPath $payloadPath -Encoding utf8NoBOM

$apiPath = "/repos/$Owner/$Repo/pulls/$Pr/reviews"
$response = gh api --method POST --input $payloadPath $apiPath 2>&1
$exit = $LASTEXITCODE

# Throw on non-zero exit so callers running under ErrorActionPreference='Stop'
# don't think the review posted when it didn't. The payload stays on disk so
# the user can inspect it after the failure.
if ($exit -ne 0) {
    $responseText = if ($response -is [array]) { ($response | ForEach-Object { $_.ToString() }) -join "`n" }
                    else { "$response" }
    throw "gh api POST $apiPath failed (exit $exit). Payload preserved at $payloadPath. Response: $responseText"
}

[pscustomobject]@{
    Mode          = 'Live'
    PayloadPath   = $payloadPath
    Event         = $event
    Verdict       = $verdict
    CommentCount  = $comments.Count
    ClampedLines  = $clamped
    SkippedCount  = $skipped
    ApiPath       = $apiPath
    Response      = $response
    ExitCode      = $exit
}
