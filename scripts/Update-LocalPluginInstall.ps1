#requires -Version 7.4
<#
.SYNOPSIS
    Upgrades a local pwsh-code-review-marketplace install to the current
    repo state.

.DESCRIPTION
    Repoints Claude Code's marketplace registration at the canonical repo
    path, clears the plugin cache, and drops the installed-plugin entry
    so Claude Code re-extracts the plugin from the fresh marketplace
    source on next startup.

    The script is idempotent. Running it on a never-installed machine
    produces the same end state as running it on a previously-installed
    machine.

    Slash commands like `/plugin marketplace update` cannot be invoked
    from a shell, so this script edits the JSON config files directly
    (the same files those slash commands write).

.PARAMETER RepoRoot
    Path to the marketplace repo. Defaults to the parent of this script.

.PARAMETER PluginsRoot
    Claude Code's plugin config directory. Defaults to
    $env:USERPROFILE\.claude\plugins on Windows, $HOME/.claude/plugins
    on macOS/Linux. Honour $env:CLAUDE_PLUGINS_ROOT if set.

.PARAMETER NoPull
    Skip `git pull`. Use when the repo is on a non-main branch
    (e.g. running from a feature branch during development).

.PARAMETER DryRun
    Print what each step would do without writing anything.

.EXAMPLE
    pwsh ./scripts/Update-LocalPluginInstall.ps1

    Standard upgrade. Pulls main, repoints the marketplace, clears the
    cache, drops the installed-plugin entry.

.EXAMPLE
    pwsh ./scripts/Update-LocalPluginInstall.ps1 -DryRun

    Print what would happen without writing anything.

.EXAMPLE
    pwsh ./scripts/Update-LocalPluginInstall.ps1 -NoPull

    Refresh the local install from the working tree without pulling.
    Useful while iterating on a feature branch.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$PluginsRoot,
    [switch]$NoPull,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$marketplaceName = 'pwsh-code-review-marketplace'
$pluginKey = 'pwsh-code-review@pwsh-code-review-marketplace'

# --- Resolve paths ---

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
$RepoRoot = (Resolve-Path $RepoRoot).Path

if (-not $PluginsRoot) {
    if ($env:CLAUDE_PLUGINS_ROOT) {
        $PluginsRoot = $env:CLAUDE_PLUGINS_ROOT
    } elseif ($IsWindows -or $env:USERPROFILE) {
        $PluginsRoot = Join-Path $env:USERPROFILE '.claude' 'plugins'
    } else {
        $PluginsRoot = Join-Path $HOME '.claude' 'plugins'
    }
}

$marketplaceFile = Join-Path $RepoRoot '.claude-plugin' 'marketplace.json'
$pluginManifest  = Join-Path $RepoRoot 'plugins' 'pwsh-code-review' '.claude-plugin' 'plugin.json'

if (-not (Test-Path $marketplaceFile)) {
    throw "Marketplace catalog not found at $marketplaceFile. Pass -RepoRoot to point at a real marketplace repo."
}
if (-not (Test-Path $pluginManifest)) {
    throw "Plugin manifest not found at $pluginManifest."
}

$pluginInfo = Get-Content $pluginManifest -Raw | ConvertFrom-Json
$pluginVersion = $pluginInfo.version

$prefix = if ($DryRun) { 'DRY-RUN: ' } else { '' }
Write-Host "${prefix}pwsh-code-review-marketplace upgrader" -ForegroundColor Cyan
Write-Host "  RepoRoot:     $RepoRoot"
Write-Host "  PluginsRoot:  $PluginsRoot"
Write-Host "  Plugin ver:   $pluginVersion (from plugin.json)"
Write-Host ""

# --- 1. git pull (optional) ---

if ($NoPull) {
    Write-Host "Skipping git pull (-NoPull)." -ForegroundColor DarkYellow
} else {
    Push-Location $RepoRoot
    try {
        $branch = (git rev-parse --abbrev-ref HEAD).Trim()
        if ($branch -ne 'main') {
            Write-Host "Repo is on '$branch', not 'main'. Skipping git pull." -ForegroundColor Yellow
            Write-Host "  (use -NoPull to silence this, or check out main and re-run)" -ForegroundColor DarkGray
        } else {
            if ($DryRun) {
                Write-Host "${prefix}Would: git fetch && git pull --ff-only on main"
            } else {
                Write-Host "Pulling latest main..." -ForegroundColor Cyan
                git fetch | Out-Host
                git pull --ff-only | Out-Host
                # Refresh the version after the pull.
                $pluginInfo = Get-Content $pluginManifest -Raw | ConvertFrom-Json
                $pluginVersion = $pluginInfo.version
                Write-Host "  Plugin ver after pull: $pluginVersion" -ForegroundColor DarkGray
            }
        }
    } finally {
        Pop-Location
    }
}

# --- 2. Ensure the plugins config root exists ---

$knownPath     = Join-Path $PluginsRoot 'known_marketplaces.json'
$installedPath = Join-Path $PluginsRoot 'installed_plugins.json'
$cacheDir      = Join-Path $PluginsRoot 'cache' $marketplaceName

if (-not (Test-Path $PluginsRoot)) {
    if ($DryRun) {
        Write-Host "${prefix}Would: create $PluginsRoot"
    } else {
        Write-Host "Creating $PluginsRoot ..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $PluginsRoot -Force | Out-Null
    }
}

# --- 3. Repoint the marketplace registration ---

Write-Host ""
Write-Host "Step: repoint marketplace registration" -ForegroundColor Cyan

$known = if (Test-Path $knownPath) {
    Get-Content $knownPath -Raw | ConvertFrom-Json -AsHashtable
} else {
    @{}
}

$nowUtc = (Get-Date).ToUniversalTime().ToString('o')
$newEntry = [ordered]@{
    source = [ordered]@{
        source = 'directory'
        path   = $RepoRoot
    }
    installLocation = $RepoRoot
    lastUpdated     = $nowUtc
}

$existing = if ($known.ContainsKey($marketplaceName)) { $known[$marketplaceName] } else { $null }
$wasStale = $false
if ($existing) {
    $oldPath = if ($existing.installLocation) { $existing.installLocation } else { '<unknown>' }
    if ($oldPath -ne $RepoRoot) {
        $wasStale = $true
        Write-Host "  Re-pointing $marketplaceName from '$oldPath' to '$RepoRoot'." -ForegroundColor Yellow
    } else {
        Write-Host "  $marketplaceName already points at '$RepoRoot'; refreshing lastUpdated." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  Adding $marketplaceName -> '$RepoRoot' (was not registered)." -ForegroundColor DarkGray
}

if (-not $DryRun) {
    $known[$marketplaceName] = $newEntry
    # Use -Depth high enough for nested source object; ConvertTo-Json on hashtables preserves insertion order in pwsh 7+.
    $json = ($known | ConvertTo-Json -Depth 10)
    Set-Content -Path $knownPath -Value $json -Encoding utf8NoBOM
    Write-Host "  known_marketplaces.json written." -ForegroundColor Green
} else {
    Write-Host "${prefix}Would: write $knownPath with the updated entry."
}

# --- 4. Always clear the plugin cache ---

Write-Host ""
Write-Host "Step: clear plugin cache (always)" -ForegroundColor Cyan

if (Test-Path $cacheDir) {
    if ($DryRun) {
        Write-Host "${prefix}Would: Remove-Item -Recurse -Force $cacheDir"
    } else {
        Remove-Item -Recurse -Force $cacheDir
        Write-Host "  Removed $cacheDir." -ForegroundColor Green
    }
} else {
    Write-Host "  $cacheDir not present (first run); nothing to clear." -ForegroundColor DarkGray
}

# --- 5. Drop the plugin entry from installed_plugins.json ---

Write-Host ""
Write-Host "Step: drop plugin entry from installed_plugins.json" -ForegroundColor Cyan

if (Test-Path $installedPath) {
    $installed = Get-Content $installedPath -Raw | ConvertFrom-Json -AsHashtable
    if ($installed.ContainsKey('plugins') -and $installed.plugins.ContainsKey($pluginKey)) {
        if ($DryRun) {
            Write-Host "${prefix}Would: remove '$pluginKey' from installed_plugins.json (Claude Code will reinstall on next startup or on /plugin install)."
        } else {
            $installed.plugins.Remove($pluginKey) | Out-Null
            $json = ($installed | ConvertTo-Json -Depth 20)
            Set-Content -Path $installedPath -Value $json -Encoding utf8NoBOM
            Write-Host "  Removed '$pluginKey' from installed_plugins.json." -ForegroundColor Green
        }
    } else {
        Write-Host "  '$pluginKey' not in installed_plugins.json; nothing to remove." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  installed_plugins.json not present; Claude Code will create it on first install." -ForegroundColor DarkGray
}

# --- 6. Done ---

Write-Host ""
Write-Host "${prefix}Upgrade prepared." -ForegroundColor Green
Write-Host "  Marketplace path: $RepoRoot"
Write-Host "  Plugin version:   $pluginVersion"
if ($wasStale) {
    Write-Host "  Note: the previous registration pointed at a stale folder; it has been replaced." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Next: restart Claude Code, OR run this in any session:" -ForegroundColor Cyan
Write-Host "  /plugin install $pluginKey"
Write-Host ""
if ($DryRun) {
    Write-Host "DRY-RUN: no files were written." -ForegroundColor Yellow
}
