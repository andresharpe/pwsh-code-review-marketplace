#requires -Version 7.4
<#
.SYNOPSIS
    Computes diff context for pwsh-code-review.

.DESCRIPTION
    Reads the AST index, parses the diff, and emits diff-context.json
    with Ring 0 (changed hunks) and Ring 1 (callers, callees, tests)
    information for each changed function.

.PARAMETER RepoRoot
    Repository root.

.PARAMETER Mode
    'Staged' (default), 'Working', 'Branch', 'Pr'

.PARAMETER Base
    Base ref for Branch mode. Defaults to 'origin/main'.

.PARAMETER Pr
    PR number for Pr mode (uses gh CLI).

.EXAMPLE
    Get-DiffContext.ps1 -Mode Staged

.EXAMPLE
    Get-DiffContext.ps1 -Mode Branch -Base origin/main
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,

    [ValidateSet('Staged', 'Working', 'Branch', 'Pr')]
    [string]$Mode = 'Staged',

    [string]$Base = 'origin/main',

    [int]$Pr
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# Shape-extraction helpers shared with Get-AstIndex.ps1.
. (Join-Path $PSScriptRoot '_ShapeHelpers.ps1')

Push-Location $RepoRoot
try {
    $cacheDir = Join-Path $RepoRoot '.pwsh-review/cache'
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    # Read the optional shape-tracking toggle from .pwsh-review/config.psd1.
    # When disabled, the per-function delta still gets the canonical-empty
    # shape keys so downstream readers can rely on the schema.
    $enableShapeTracking = $true
    $configPath = Join-Path $RepoRoot '.pwsh-review/config.psd1'
    if (Test-Path $configPath) {
        try {
            $cfg = Import-PowerShellDataFile $configPath
            if ($cfg.ContainsKey('EnableShapeTracking')) {
                $enableShapeTracking = [bool]$cfg.EnableShapeTracking
            }
        } catch {
            Write-Verbose "Could not read $configPath; defaulting EnableShapeTracking=true: $($_.Exception.Message)"
        }
    }

    $indexPath = Join-Path $cacheDir 'ast-index.json'
    if (-not (Test-Path $indexPath)) {
        throw "AST index not found at $indexPath. Run Get-AstIndex.ps1 first."
    }
    $index = Get-Content $indexPath -Raw | ConvertFrom-Json -AsHashtable

    # Resolve base and head
    $diffArgs = switch ($Mode) {
        'Staged'  { @('diff', '--cached', '--unified=3') }
        'Working' { @('diff', 'HEAD', '--unified=3') }
        'Branch'  { @('diff', "$Base...HEAD", '--unified=3') }
        'Pr'      {
            if (-not $Pr) { throw "Pr mode requires -Pr <number>" }
            $base = (gh pr view $Pr --json baseRefName -q .baseRefName)
            @('diff', "origin/${base}...HEAD", '--unified=3')
        }
    }

    $diffBase = switch ($Mode) {
        'Staged'  { (git rev-parse HEAD).Trim() }
        'Working' { (git rev-parse HEAD).Trim() }
        'Branch'  { (git merge-base HEAD $Base).Trim() }
        'Pr'      { $base = (gh pr view $Pr --json baseRefName -q .baseRefName)
                    (git merge-base HEAD "origin/$base").Trim() }
    }

    $diffHead = switch ($Mode) {
        'Staged'  { 'STAGED' }
        'Working' { 'WORKING' }
        default   { (git rev-parse HEAD).Trim() }
    }

    # Get the unified diff
    $diffText = git @diffArgs 2>$null
    if (-not $diffText) {
        $emptyContext = [ordered]@{
            schema_version           = '1'
            diff_base                = $diffBase
            diff_head                = $diffHead
            mode                     = $Mode
            changed_files            = @()
            changed_hunks            = @()
            changed_functions        = @()
            static_findings_summary  = $null
        }
        $emptyContext | ConvertTo-Json -Depth 20 |
            Set-Content (Join-Path $cacheDir 'diff-context.json') -Encoding utf8NoBOM
        Write-Verbose "No diff for mode $Mode"
        return [pscustomobject]@{ ChangedFiles = 0; ChangedFunctions = 0 }
    }

    # Parse the diff into hunks
    $hunks = @()
    $changedFiles = @()
    $currentFile = $null

    foreach ($line in ($diffText -split "`n")) {
        if ($line -match '^diff --git a/(.+?) b/(.+?)$') {
            $currentFile = $Matches[2]
            if ($currentFile -match '\.(ps1|psm1|psd1)$' -and $currentFile -notin $changedFiles) {
                $changedFiles += $currentFile
            }
        } elseif ($line -match '^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@') {
            # Capture from $Matches BEFORE any subsequent -match runs. The
            # inner extension check below would otherwise overwrite $Matches
            # and turn $Matches[1] into the captured extension ('ps1') —
            # which then crashes the [int] cast.
            $startLine = [int]$Matches[1]
            $count = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
            if ($currentFile -and $currentFile -match '\.(ps1|psm1|psd1)$') {
                $hunks += [ordered]@{
                    file       = $currentFile
                    line_start = $startLine
                    line_end   = $startLine + [Math]::Max(0, $count - 1)
                }
            }
        }
    }

    # For each changed pwsh file, identify changed functions
    $changedFunctions = @()

    foreach ($file in $changedFiles) {
        if (-not $index.files.Contains($file)) {
            # File not in index (perhaps newly added). Trigger an index refresh on the next run.
            continue
        }

        $fileEntry = $index.files[$file]
        $fileHunks = @($hunks | Where-Object { $_.file -eq $file })

        foreach ($func in $fileEntry.functions) {
            $intersects = $false
            foreach ($hunk in $fileHunks) {
                if ($hunk.line_start -le $func.line_end -and $hunk.line_end -ge $func.line_start) {
                    $intersects = $true
                    break
                }
            }
            if (-not $intersects) { continue }

            # Compute delta against pre-change file (best effort)
            $delta = [ordered]@{
                signature_changed       = $null  # filled by Compare-FunctionAst, omitted if pre-state unavailable
                output_type_changed     = $null
                process_block_changed   = $null
                should_process_changed  = $null
                calls_added             = @()
                calls_removed           = @()
                scope_writes_added      = @()
                emits_shape_changed     = $false
                properties_dropped      = @()
                properties_added        = @()
                stale_consumers         = @()
            }
            # Lookup table: dropped property name (lowercase) -> array of
            # pre-version emit-site lines. Populated inside the shape-diff
            # try block; consumed by the stale-consumer walk below.
            $emitSiteLinesByProp = @{}

            try {
                $preContent = git show "${diffBase}:${file}" 2>$null
                if ($preContent) {
                    $tokens = $errors = $null
                    $preAst = [System.Management.Automation.Language.Parser]::ParseInput(
                        ($preContent -join "`n"), [ref]$tokens, [ref]$errors
                    )
                    $preFunc = $preAst.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $n.Name -eq $func.name
                    }, $true) | Select-Object -First 1

                    if ($preFunc) {
                        # Cross-module data-shape diff (PWSH-DIFF-201).
                        # Run this first and in its own try/catch so it does
                        # not get short-circuited by errors in unrelated
                        # delta computations below.
                        if ($enableShapeTracking) {
                            try {
                                $preEmits = @(Get-EmitsShape -FuncAst $preFunc)
                                $postEmits = @($func.emits_shape)
                                $shapeDiff = Compare-EmitShapesForDrop -PreEmits $preEmits -PostEmits $postEmits
                                $delta.properties_dropped = @($shapeDiff.properties_dropped)
                                $delta.properties_added = @($shapeDiff.properties_added)
                                $delta.emits_shape_changed = (
                                    $delta.properties_dropped.Count -gt 0 -or
                                    $delta.properties_added.Count -gt 0
                                )
                                # Index pre-version emit sites by property
                                # name so the stale-consumer walk below can
                                # cite the line(s) that emitted each dropped
                                # property. The agent uses this for evidence[].
                                foreach ($site in $preEmits) {
                                    foreach ($p in @($site.properties)) {
                                        $key = $p.ToLowerInvariant()
                                        if (-not $emitSiteLinesByProp.ContainsKey($key)) {
                                            $emitSiteLinesByProp[$key] = @()
                                        }
                                        $emitSiteLinesByProp[$key] += $site.line
                                    }
                                }
                            } catch {
                                Write-Verbose "Shape-diff failed for $($func.name): $($_.Exception.Message)"
                            }
                        }

                        # Pre-existing delta fields (signature, calls). The
                        # ?? + Compare-Object pair errors when both sides are
                        # null/empty (no parameters), so it lives in its own
                        # try so a failure does not invalidate other deltas.
                        try {
                            $preParams = @(if ($preFunc.Parameters) {
                                $preFunc.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
                            } elseif ($preFunc.Body.ParamBlock -and $preFunc.Body.ParamBlock.Parameters) {
                                $preFunc.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
                            })
                            $postParams = @($func.parameters | ForEach-Object { $_.name })
                            $delta.signature_changed = if ($preParams.Count -eq 0 -and $postParams.Count -eq 0) {
                                $false
                            } elseif ($preParams.Count -eq 0 -or $postParams.Count -eq 0) {
                                $true
                            } else {
                                (Compare-Object $preParams $postParams) -ne $null
                            }

                            $delta.process_block_changed = ($null -ne $preFunc.Body.ProcessBlock) -ne $func.has_process_block

                            $preCalls = @($preFunc.FindAll({
                                param($n) $n -is [System.Management.Automation.Language.CommandAst]
                            }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Select-Object -Unique)
                            $delta.calls_added = @($func.calls | Where-Object { $_ -notin $preCalls })
                            $delta.calls_removed = @($preCalls | Where-Object { $_ -notin $func.calls })
                        } catch {
                            Write-Verbose "Signature-diff failed for $($func.name): $($_.Exception.Message)"
                        }
                    }
                }
            } catch {
                Write-Verbose "Could not compute delta for $($func.name): $($_.Exception.Message)"
            }

            # Resolve callers and tests
            $callers = @()
            if ($index.callers_of.Contains($func.name)) {
                $callers = $index.callers_of[$func.name]
            }

            # Resolve stale consumers: callers that still access a property
            # the function dropped. Pivots through callers_of -> the caller
            # function's consumes_shape entries.
            if ($enableShapeTracking -and $delta.properties_dropped.Count -gt 0) {
                $staleConsumers = @()
                $droppedLower = @($delta.properties_dropped | ForEach-Object { $_.ToLowerInvariant() })
                foreach ($callerRec in $callers) {
                    $callerFile = $callerRec.file
                    $callerName = $callerRec.caller
                    if (-not $index.files.Contains($callerFile)) { continue }
                    $callerFileEntry = $index.files[$callerFile]
                    $callerFunc = $callerFileEntry.functions |
                        Where-Object { $_.name -eq $callerName } |
                        Select-Object -First 1
                    if (-not $callerFunc) { continue }
                    if (-not $callerFunc.Contains('consumes_shape')) { continue }
                    foreach ($cs in @($callerFunc.consumes_shape)) {
                        if ($cs.via_call -ne $func.name) { continue }
                        if ($cs.dynamic) { continue }
                        $propLower = $cs.property.ToLowerInvariant()
                        if ($propLower -notin $droppedLower) { continue }
                        $emitLines = @()
                        if ($emitSiteLinesByProp.ContainsKey($propLower)) {
                            $emitLines = @($emitSiteLinesByProp[$propLower] | Sort-Object -Unique)
                        }
                        $staleConsumers += [ordered]@{
                            caller_function = $callerName
                            caller_file     = $callerFile
                            consumer_line   = $cs.line
                            property        = $cs.property
                            dynamic         = $cs.dynamic
                            emit_site_lines = $emitLines
                        }
                    }
                }
                $delta.stale_consumers = @($staleConsumers)
            }

            $tests = @()
            if ($index.tests_for.Contains($func.name)) {
                $tests = $index.tests_for[$func.name]
            }

            $changedFunctions += [ordered]@{
                name        = $func.name
                file        = $file
                line_start  = $func.line_start
                line_end    = $func.line_end
                delta       = $delta
                callers     = $callers
                callees     = $func.calls
                tests       = $tests
            }
        }
    }

    # Static findings summary (if static-findings.json exists)
    $staticSummary = $null
    $staticPath = Join-Path $cacheDir 'static-findings.json'
    if (Test-Path $staticPath) {
        $static = Get-Content $staticPath -Raw | ConvertFrom-Json
        $staticSummary = [ordered]@{
            psscriptanalyzer = @($static.psscriptanalyzer ?? @()).Count
            gitleaks         = @($static.gitleaks ?? @()).Count
            pester_failed    = if ($static.pester) { $static.pester.failed } else { 0 }
        }
    }

    $context = [ordered]@{
        schema_version           = '1'
        generated                = (Get-Date).ToUniversalTime().ToString('o')
        diff_base                = $diffBase
        diff_head                = $diffHead
        mode                     = $Mode
        changed_files            = $changedFiles
        changed_hunks            = $hunks
        changed_functions        = $changedFunctions
        static_findings_summary  = $staticSummary
    }

    $contextPath = Join-Path $cacheDir 'diff-context.json'
    $context | ConvertTo-Json -Depth 30 | Set-Content $contextPath -Encoding utf8NoBOM

    [pscustomobject]@{
        Mode             = $Mode
        ChangedFiles     = $changedFiles.Count
        ChangedHunks     = $hunks.Count
        ChangedFunctions = $changedFunctions.Count
        ContextPath      = $contextPath
    }
} finally {
    Pop-Location
}
