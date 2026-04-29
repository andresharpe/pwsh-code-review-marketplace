#requires -Version 7.4
<#
.SYNOPSIS
    Detects misuse of `{{TOKEN}}` template-substitution placeholders.

.DESCRIPTION
    Scans markdown files (configurable via .pwsh-review/template-rules.json
    or default `**/*.md`) for `{{TOKEN}}` references and emits findings:

      PWSH-TPL-001 (major / 90)
        Token `{{X}}` is referenced in prose but no `-replace` rule exists
        for it anywhere in the repository's PowerShell sources. The runtime
        will leave the literal `{{X}}` in the rendered prompt.

      PWSH-TPL-002 (major / 80 or 60)
        Prose conditional that the substitution will never satisfy. Pattern:
        text near a `{{X}}` reference says "if {{X}} is empty / missing /
        blank / absent / not set". When `X` is provably always non-empty
        (the `-replace` source declares an explicit fallback), confidence
        is 80 — mechanical bug. When `X` is uncertain, confidence is 60 —
        hedged.

    Discovery of token names and their always-non-empty property is shared
    with `Initialize-ReviewProfile.ps1` via `Get-TemplateTokens.ps1`.

    Suppression via `# pwsh-review:disable-next-line PWSH-TPL-NNN` is
    documented in `docs/severity-rubric.md` but not yet implemented in the
    static layer; tracked for a follow-up PR.

.PARAMETER RepoRoot
    Repository root.

.OUTPUTS
    Array of PSSA-shape hashtables with an additional `confidence` field.
#>
[CmdletBinding()]
[OutputType([object[]])]
param(
    [string]$RepoRoot = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# Words that indicate "the substitution didn't render to a value" — the
# whole class of dead-conditional bug. Each fires unless preceded by
# "non-", "not ", or "no longer " (which inverts the check). Implemented
# as a chain of fixed-length negative lookbehinds because .NET regex
# only allowed fixed-length lookbehinds historically; this form is
# portable across runtimes.
$script:EmptyWordRegex = [regex]::new('(?i)(?<!non-)(?<!not\s)(?<!no\slonger\s)\b(?:empty|missing|blank|absent|unset|undefined)\b')

# --- Scanner ---------------------------------------------------------------

function New-Finding {
    param(
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][int]$Line,
        [int]$Column = 0,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][int]$Confidence,
        [Parameter(Mandatory)][string]$Severity
    )
    [ordered]@{
        rule_name  = $Rule
        severity   = $Severity
        file       = $File
        line       = $Line
        column     = $Column
        message    = $Message
        confidence = $Confidence
    }
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    try {
        $resolved     = [IO.Path]::GetFullPath($Path)
        $rootResolved = [IO.Path]::GetFullPath($Root)
        if ($resolved.StartsWith($rootResolved, [StringComparison]::OrdinalIgnoreCase)) {
            return ($resolved.Substring($rootResolved.Length).TrimStart('\', '/') -replace '\\', '/')
        }
        return $Path -replace '\\', '/'
    } catch {
        return $Path -replace '\\', '/'
    }
}

function Find-TokenReferencesInFile {
    <#
    Returns a list of @{ Token; Line; Column; LineText } for every
    `{{TOKEN}}` reference inside an .md file.
    #>
    param([Parameter(Mandatory)][string]$FilePath)
    $tokenRegex = [regex]::new('\{\{([A-Z][A-Z0-9_]*)\}\}')
    $results = @()
    try {
        $lines = Get-Content -LiteralPath $FilePath -ErrorAction Stop
    } catch {
        return @()
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        foreach ($m in $tokenRegex.Matches($line)) {
            $results += [pscustomobject]@{
                Token    = $m.Groups[1].Value
                Line     = $i + 1
                Column   = $m.Index + 1
                LineText = $line
            }
        }
    }
    return $results
}

function Test-LineHasDeadConditional {
    <#
    Returns $true when the line contains the literal `{{Token}}` and ALSO,
    within ~100 characters of that token, an "empty"-class word (empty /
    missing / blank / absent / unset / undefined) NOT preceded by "non-",
    "not ", or "no longer ". This catches conditional prose like
        "if `{{X}}` is empty"
        "`{{X}}` above is empty, or contains no IDs"
        "when `{{X}}` is missing"
    while ignoring "if `{{X}}` is non-empty" and similar inverse checks.
    #>
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][string]$Token,
        [int]$Proximity = 100
    )
    $needle = '{{' + $Token + '}}'
    $tokenIdx = $Line.IndexOf($needle, [StringComparison]::Ordinal)
    if ($tokenIdx -lt 0) { return $false }

    foreach ($m in $script:EmptyWordRegex.Matches($Line)) {
        $distance = [Math]::Min(
            [Math]::Abs($m.Index - ($tokenIdx + $needle.Length)),
            [Math]::Abs($tokenIdx - ($m.Index + $m.Length))
        )
        if ($distance -le $Proximity) { return $true }
    }
    return $false
}

# --- Token catalog ---------------------------------------------------------

function Get-TokenCatalog {
    <#
    Returns a hashtable keyed by token name, value @{ AlwaysNonEmpty; DefinedAt }.
    Loads from .pwsh-review/template-rules.json when present, else runs the
    discovery script directly.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    $catalog = @{}
    $rulesPath = Join-Path $RepoRoot '.pwsh-review/template-rules.json'
    if (Test-Path $rulesPath) {
        try {
            $data = Get-Content $rulesPath -Raw | ConvertFrom-Json
            if ($data -and $data.tokens) {
                foreach ($t in $data.tokens) {
                    if (-not $t.name) { continue }
                    $catalog[$t.name] = @{
                        AlwaysNonEmpty = [bool]$t.always_nonempty
                        DefinedAt      = @($t.defined_at)
                    }
                }
            }
            return $catalog
        } catch {
            Write-Warning "Test-TemplateSubstitution: failed to read $rulesPath - $($_.Exception.Message). Falling back to live discovery."
        }
    }

    $discoveryScript = Join-Path $PSScriptRoot 'Get-TemplateTokens.ps1'
    if (-not (Test-Path $discoveryScript)) {
        return $catalog
    }
    $tokens = & $discoveryScript -RepoRoot $RepoRoot
    foreach ($t in $tokens) {
        $catalog[$t.Name] = @{
            AlwaysNonEmpty = [bool]$t.AlwaysNonEmpty
            DefinedAt      = @($t.DefinedAt)
        }
    }
    return $catalog
}

# --- Driver ----------------------------------------------------------------

Push-Location $RepoRoot
try {
    $catalog = Get-TokenCatalog -RepoRoot $RepoRoot
    if ($catalog.Count -eq 0) {
        # No tokens discovered → no template substitution in this repo.
        # Emit empty findings array.
        , @()
        return
    }

    $rulesPath = Join-Path $RepoRoot '.pwsh-review/template-rules.json'
    $globs = @('**/*.md', '**/*.markdown')
    if (Test-Path $rulesPath) {
        try {
            $data = Get-Content $rulesPath -Raw | ConvertFrom-Json
            if ($data.scan_globs) { $globs = @($data.scan_globs) }
        } catch { }
    }

    function Convert-ScanGlobToRegex {
        # Converts a glob pattern (e.g. `core/prompts/**/*.md`) to a regex
        # anchored to a relative path. Honours `**/` (any depth), `*` (any
        # chars within a segment), and `?` (single char). Forward slashes.
        param([Parameter(Mandatory)][string]$Glob)
        $pattern = ($Glob -replace '\\', '/').TrimStart('./')
        $pattern = [regex]::Escape($pattern)
        $pattern = $pattern -replace '\\\*\\\*/', '(?:.*/)?'
        $pattern = $pattern -replace '\\\*\\\*',   '.*'
        $pattern = $pattern -replace '\\\*',       '[^/]*'
        $pattern = $pattern -replace '\\\?',       '[^/]'
        return '^' + $pattern + '$'
    }

    $repoRootPrefix = ((Resolve-Path $RepoRoot).Path -replace '\\', '/').TrimEnd('/') + '/'
    $globMatchers = @($globs | ForEach-Object {
        [regex]::new((Convert-ScanGlobToRegex -Glob $_), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    })

    $files = Get-ChildItem -Path $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $full = $_.FullName -replace '\\', '/'
            if ($full -match '/\.pwsh-review/' -or
                $full -match '/\.git/' -or
                $full -match '/node_modules/') { return $false }
            $relative = $full
            if ($relative.StartsWith($repoRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                $relative = $relative.Substring($repoRootPrefix.Length)
            }
            foreach ($m in $globMatchers) {
                if ($m.IsMatch($relative)) { return $true }
            }
            return $false
        } |
        Sort-Object FullName -Unique

    $findings = @()
    foreach ($f in $files) {
        $rel = Get-RelativePath -Path $f.FullName -Root $RepoRoot
        $refs = Find-TokenReferencesInFile -FilePath $f.FullName
        foreach ($ref in $refs) {
            $known = $catalog.ContainsKey($ref.Token)
            if (-not $known) {
                $findings += New-Finding `
                    -Rule 'PWSH-TPL-001' `
                    -Severity 'Warning' `
                    -Confidence 90 `
                    -File $rel -Line $ref.Line -Column $ref.Column `
                    -Message "Unknown template token ``{{$($ref.Token)}}``. No ``-replace '\{\{$($ref.Token)\}\}', ...`` rule exists in the repository's PowerShell sources, so the runtime will emit the literal placeholder. Either fix the typo or add a substitution rule."
                continue
            }

            if (Test-LineHasDeadConditional -Line $ref.LineText -Token $ref.Token) {
                $info = $catalog[$ref.Token]
                if ($info.AlwaysNonEmpty) {
                    $defined = if (@($info.DefinedAt).Count -gt 0) { @($info.DefinedAt)[0] } else { '<unknown>' }
                    $findings += New-Finding `
                        -Rule 'PWSH-TPL-002' `
                        -Severity 'Warning' `
                        -Confidence 80 `
                        -File $rel -Line $ref.Line -Column $ref.Column `
                        -Message "Conditional on ``{{$($ref.Token)}}`` being empty is dead code. The runtime substitutes a non-empty fallback at ``$defined`` — the token's rendered value is never literally empty."
                } else {
                    $findings += New-Finding `
                        -Rule 'PWSH-TPL-002' `
                        -Severity 'Warning' `
                        -Confidence 60 `
                        -File $rel -Line $ref.Line -Column $ref.Column `
                        -Message "This conditional on ``{{$($ref.Token)}}`` being empty may be dead code. The token's runtime value depends on the caller; verify whether the fallback path can actually fire."
                }
            }
        }
    }

    , $findings
} finally {
    Pop-Location
}
