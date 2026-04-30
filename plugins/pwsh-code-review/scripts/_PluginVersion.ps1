#requires -Version 7.4
<#
Single source of truth for reading the pwsh-code-review plugin version.

Dot-source this file from any review-time script that wants to emit the
version into a JSON metadata block, a terminal banner, or rendered
review markdown. Returns 'unknown' on any failure (manifest missing,
JSON corrupted) — never throws, so a missing version cannot block a
review.

Usage:

    . (Join-Path $PSScriptRoot '_PluginVersion.ps1')
    $pluginRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $pluginVersion = Get-PluginVersion -PluginRoot $pluginRoot
#>

function Get-PluginVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot
    )

    $manifestPath = Join-Path $PluginRoot '.claude-plugin' 'plugin.json'
    if (-not (Test-Path $manifestPath)) {
        return 'unknown'
    }

    try {
        $info = Get-Content $manifestPath -Raw | ConvertFrom-Json
        if ($info.PSObject.Properties.Name -contains 'version' -and $info.version) {
            return [string]$info.version
        }
        return 'unknown'
    } catch {
        return 'unknown'
    }
}
