#requires -Version 7.4
<#
.SYNOPSIS
    Restores any missing pwsh-code-review profile files from a base git ref.

.DESCRIPTION
    The plugin reads its project profile from `.pwsh-review/` in the working
    tree (architecture.md, standards.md, glossary.md, patterns/,
    PSScriptAnalyzerSettings.psd1, config.psd1, profile.lock.json). When a
    PR branched off main BEFORE the profile was added, those files are
    absent on the PR branch and the static layer aborts with
    "PSScriptAnalyzerSettings.psd1 not found ... Run /pwsh-review-bootstrap
    first." That guidance is wrong on a PR review — the profile already
    exists on the base ref, the branch is just behind.

    This helper checks each canonical profile path. Missing files get
    restored from `git show <BaseRef>:.pwsh-review/<path>` into the local
    working tree (untracked). Files already present locally are left
    alone, so a deliberate change to standards.md on the PR branch is
    never overwritten.

    The restored files appear as untracked in `git status` and would not
    accidentally land in a commit unless the author explicitly stages
    them. The script emits an `Information` stream record naming each
    file it restored so the author can spot what is happening; callers
    that want silence can pass `-InformationAction SilentlyContinue` or
    set `$InformationPreference`.

.PARAMETER RepoRoot
    Repository root.

.PARAMETER BaseRef
    Git ref to fall back to. Defaults to 'origin/main'. Pass a PR's actual
    base when running in PR mode (`Get-DiffContext.ps1 -Mode Pr` already
    resolves it via `gh pr view --json baseRefName`).

.OUTPUTS
    [pscustomobject] with the restored file count, the list of paths, a
    machine-readable `Reason`, and `LocallyMissing` (the count of
    canonical files absent locally — distinct from `RestoredCount` so
    callers can tell "fully complete" from "partially recovered").

.EXAMPLE
    Resolve-Profile.ps1 -BaseRef origin/main
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$BaseRef  = 'origin/main'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

# Files the plugin expects under .pwsh-review/. The patterns directory is
# enumerated dynamically below so any pattern-*.ps1 file present on the base
# ref gets restored.
$canonicalFiles = @(
    'PSScriptAnalyzerSettings.psd1'
    'config.psd1'
    'architecture.md'
    'standards.md'
    'glossary.md'
    'profile.lock.json'
)

$restored        = @()
$locallyMissing  = 0

# Run from the repo root so `git show` resolves <ref>:<path> against the
# correct work tree.
Push-Location $RepoRoot
try {
    # Bail early if the working tree is not a git repo (caller is responsible
    # for that — but be helpful).
    $null = git rev-parse --git-dir 2>$null
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{
            RestoredCount   = 0
            Restored        = @()
            LocallyMissing  = 0
            Reason          = 'not a git repo'
        }
    }

    # Confirm the base ref resolves. If not, no restoration is possible — we
    # still return cleanly so the caller can decide whether that is fatal.
    $null = git rev-parse --verify "${BaseRef}^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{
            RestoredCount   = 0
            Restored        = @()
            LocallyMissing  = 0
            Reason          = "base ref '$BaseRef' did not resolve"
        }
    }

    # Restore canonical profile files. Track files that are missing locally
    # separately from files we successfully restored — they're not the same
    # number when the base ref also lacks the file.
    foreach ($rel in $canonicalFiles) {
        $localPath = Join-Path $RepoRoot ".pwsh-review/$rel"
        if (Test-Path -LiteralPath $localPath) { continue }
        $locallyMissing++
        $content = git show "${BaseRef}:.pwsh-review/$rel" 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        $dir = Split-Path -Parent $localPath
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # Write as utf8NoBOM to match the project's canonical encoding
        # (bootstrap and editor saves produce the same). This normalises
        # rather than preserves the byte-exact original — fine because the
        # profile files are text we control and the encoding contract is
        # "no BOM, UTF-8" across the board.
        $content | Set-Content -LiteralPath $localPath -Encoding utf8NoBOM
        $restored += ".pwsh-review/$rel"
    }

    # Restore the patterns/ directory entries enumerated from the base ref.
    $patternsLs = git ls-tree --name-only -r "$BaseRef" -- '.pwsh-review/patterns' 2>$null
    if ($LASTEXITCODE -eq 0 -and $patternsLs) {
        foreach ($rel in ($patternsLs -split "`n")) {
            $rel = $rel.Trim()
            if (-not $rel) { continue }
            $localPath = Join-Path $RepoRoot $rel
            if (Test-Path -LiteralPath $localPath) { continue }
            $locallyMissing++
            $content = git show "${BaseRef}:$rel" 2>$null
            if ($LASTEXITCODE -ne 0) { continue }
            $dir = Split-Path -Parent $localPath
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            $content | Set-Content -LiteralPath $localPath -Encoding utf8NoBOM
            $restored += $rel
        }
    }

    # Emit operator-facing summary on the Information stream so callers can
    # silence it via `-InformationAction SilentlyContinue` or by setting
    # $InformationPreference. Default $InformationPreference is
    # 'SilentlyContinue', so callers must opt in to see the message.
    if ($restored.Count -gt 0) {
        Write-Information "Restored $($restored.Count) profile file(s) from ${BaseRef}:"
        foreach ($p in $restored) { Write-Information "  $p" }
        Write-Information 'These are untracked on this branch; do not commit them.'
    }

    # Compute Reason that distinguishes the three meaningful states:
    #   - profile already complete    : nothing was missing locally
    #   - restored from base          : everything missing was recovered
    #   - missing locally and on base : at least one file missing locally
    #                                   could not be restored from base
    $reason = if ($locallyMissing -eq 0) {
        'profile already complete'
    } elseif ($restored.Count -eq $locallyMissing) {
        'restored from base'
    } else {
        "missing locally and on base ($($locallyMissing - $restored.Count) file(s) still absent)"
    }

    return [pscustomobject]@{
        RestoredCount   = $restored.Count
        Restored        = $restored
        LocallyMissing  = $locallyMissing
        Reason          = $reason
    }
} finally {
    Pop-Location
}
