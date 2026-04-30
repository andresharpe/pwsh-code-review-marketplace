#requires -Version 7.4
<#
.SYNOPSIS
    Pattern: static-analysis scanner script.

.DESCRIPTION
    The canonical shape for plugins/pwsh-code-review/scripts/Test-<Subject>.ps1.
    Reference example: plugins/pwsh-code-review/scripts/Test-Brittleness.ps1
    (the most complete scanner; 10 rules, full AST walk, fixture suite).

    Required structure:
      1. #requires -Version 7.4 first line
      2. Comment-based help (.SYNOPSIS, .DESCRIPTION, .PARAMETER, .OUTPUTS)
      3. [CmdletBinding()] and [OutputType([object[]])]
      4. param() with -RepoRoot, -Path, -All
      5. $ErrorActionPreference = 'Stop' and Set-StrictMode -Version 3.0
      6. $script:Rules table mapping RuleID -> @{ Severity; Confidence }
      7. Per-rule predicate functions Test-RuleNNN -Node $n -RelativePath $rel
      8. Invoke-FileScan walks the AST and dispatches each predicate
      9. New-Finding helper builds the result hashtable
     10. Push-Location / try / Pop-Location entry block

    Severity mapping (matches PSScriptAnalyzer-shape used by other static
    producers):
      Error       -> blocker
      Warning     -> major
      Information -> minor

    The output is an array of hashtables, each shaped like:
      @{ rule_name; severity; file; line; column; message; confidence }

    Wrap the final output in `, $allFindings` so a single-finding result
    is still emitted as an array (PowerShell's pipeline unwrapping
    otherwise hands the merger one bare hashtable).
#>
[CmdletBinding()]
[OutputType([object[]])]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string[]]$Path,
    [switch]$All
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# --- Rule table -------------------------------------------------------------

$script:Rules = @{
    'PWSH-EXAMPLE-001' = @{ Severity = 'Warning'; Confidence = 80 }  # major
}

# --- Helpers ----------------------------------------------------------------

function Get-RuleSeverity { param([Parameter(Mandatory)][string]$Rule) $script:Rules[$Rule].Severity }
function Get-RuleConfidence { param([Parameter(Mandatory)][string]$Rule) $script:Rules[$Rule].Confidence }

function New-Finding {
    param(
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][int]$Line,
        [int]$Column = 0,
        [Parameter(Mandatory)][string]$Message
    )
    [ordered]@{
        rule_name  = $Rule
        severity   = Get-RuleSeverity $Rule
        file       = $File
        line       = $Line
        column     = $Column
        message    = $Message
        confidence = Get-RuleConfidence $Rule
    }
}

# --- Per-rule predicates ----------------------------------------------------

function Test-RuleExample001 {
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$RelativePath
    )
    # ... AST checks. Return $null when the rule does not fire; otherwise
    # return (New-Finding -Rule 'PWSH-EXAMPLE-001' ...).
    return $null
}

# --- Driver -----------------------------------------------------------------

function Invoke-FileScan {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    # Parse, walk, dispatch each Test-RuleNNN. Catch per-rule exceptions
    # so one buggy predicate does not nuke the whole scan.
    return @()
}

# --- Entry ------------------------------------------------------------------

Push-Location $RepoRoot
try {
    $allFindings = @()
    # ... iterate $files, accumulate $allFindings
    , $allFindings
} finally {
    Pop-Location
}
