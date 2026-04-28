#requires -Version 7.4
<#
.SYNOPSIS
    Builds or refreshes the AST index used by pwsh-code-review.

.DESCRIPTION
    Walks the repository, parses every PowerShell file, and writes
    .pwsh-review/cache/ast-index.json containing function definitions,
    call graph, and test associations.

    The index is content-addressed by SHA256 so subsequent runs only
    re-parse files whose hash changed.

.PARAMETER RepoRoot
    The repository root. Defaults to the current directory.

.PARAMETER Cold
    Force a full rebuild even if the cache exists.

.EXAMPLE
    Get-AstIndex.ps1
    Refreshes the index for the current repo.

.EXAMPLE
    Get-AstIndex.ps1 -Cold
    Forces a full rebuild.

.OUTPUTS
    [pscustomobject] with Files, FunctionToFile, CallersOf, TestsFor properties
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [switch]$Cold
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$cacheDir = Join-Path $RepoRoot '.pwsh-review/cache'
$indexPath = Join-Path $cacheDir 'ast-index.json'

if (-not (Test-Path $cacheDir)) {
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
}

# Load existing index, or start fresh
$index = if ($Cold -or -not (Test-Path $indexPath)) {
    [ordered]@{
        schema_version   = '1'
        generated        = (Get-Date).ToUniversalTime().ToString('o')
        files            = [ordered]@{}
        function_to_file = [ordered]@{}
        callers_of       = [ordered]@{}
        tests_for        = [ordered]@{}
    }
} else {
    $loaded = Get-Content $indexPath -Raw | ConvertFrom-Json -AsHashtable
    [ordered]@{
        schema_version   = $loaded.schema_version
        generated        = (Get-Date).ToUniversalTime().ToString('o')
        files            = [ordered]@{} + $loaded.files
        function_to_file = [ordered]@{}
        callers_of       = [ordered]@{}
        tests_for        = [ordered]@{}
    }
}

function ConvertTo-FunctionEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.FunctionDefinitionAst]$FuncAst
    )

    $params = @()
    $paramAsts = if ($FuncAst.Parameters) {
        $FuncAst.Parameters
    } elseif ($FuncAst.Body.ParamBlock) {
        $FuncAst.Body.ParamBlock.Parameters
    } else {
        @()
    }

    foreach ($p in $paramAsts) {
        $name = $p.Name.VariablePath.UserPath
        $type = if ($p.StaticType) { $p.StaticType.FullName } else { 'object' }

        $mandatory = $false
        $valueFromPipeline = $false
        $valueFromPipelineByPropertyName = $false
        $validations = @()

        foreach ($attr in $p.Attributes) {
            $attrTypeName = $attr.TypeName.Name

            if ($attrTypeName -eq 'Parameter' -and $attr.NamedArguments) {
                foreach ($na in $attr.NamedArguments) {
                    switch ($na.ArgumentName) {
                        'Mandatory' {
                            $mandatory = -not $na.ExpressionOmitted -or $na.Argument.Value -eq $true
                        }
                        'ValueFromPipeline' {
                            $valueFromPipeline = -not $na.ExpressionOmitted -or $na.Argument.Value -eq $true
                        }
                        'ValueFromPipelineByPropertyName' {
                            $valueFromPipelineByPropertyName = -not $na.ExpressionOmitted -or $na.Argument.Value -eq $true
                        }
                    }
                }
            } elseif ($attrTypeName -like 'Validate*') {
                $validations += $attrTypeName
            }
        }

        $params += [ordered]@{
            name                                = $name
            type                                = $type
            mandatory                           = $mandatory
            value_from_pipeline                 = $valueFromPipeline
            value_from_pipeline_by_property_name = $valueFromPipelineByPropertyName
            validations                         = $validations
        }
    }

    # OutputType attribute
    $outputTypes = @()
    if ($FuncAst.Body.ParamBlock -and $FuncAst.Body.ParamBlock.Attributes) {
        foreach ($attr in $FuncAst.Body.ParamBlock.Attributes) {
            if ($attr.TypeName.Name -eq 'OutputType') {
                foreach ($arg in $attr.PositionalArguments) {
                    $outputTypes += $arg.Extent.Text.Trim('[', ']', '"', "'")
                }
            }
        }
    }

    # CmdletBinding flags
    $supportsShouldProcess = $false
    if ($FuncAst.Body.ParamBlock -and $FuncAst.Body.ParamBlock.Attributes) {
        $cmdletBinding = $FuncAst.Body.ParamBlock.Attributes |
            Where-Object { $_.TypeName.Name -eq 'CmdletBinding' } |
            Select-Object -First 1
        if ($cmdletBinding -and $cmdletBinding.NamedArguments) {
            foreach ($na in $cmdletBinding.NamedArguments) {
                if ($na.ArgumentName -eq 'SupportsShouldProcess') {
                    $supportsShouldProcess = -not $na.ExpressionOmitted -or $na.Argument.Value -eq $true
                }
            }
        }
    }

    # Process block presence
    $hasProcessBlock = $null -ne $FuncAst.Body.ProcessBlock

    # Calls inside the function
    $calls = @($FuncAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true) | ForEach-Object {
        $cmdName = $_.GetCommandName()
        if ($cmdName) { $cmdName }
    } | Where-Object { $_ } | Select-Object -Unique)

    # Scope writes
    $scopeWrites = @($FuncAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        ($node.Left.VariablePath.IsScript -or $node.Left.VariablePath.IsGlobal)
    }, $true) | ForEach-Object {
        if ($_.Left.VariablePath.IsScript) { 'script:' + $_.Left.VariablePath.UserPath }
        elseif ($_.Left.VariablePath.IsGlobal) { 'global:' + $_.Left.VariablePath.UserPath }
    } | Select-Object -Unique)

    # Platform signals
    $platformSignals = @()
    $funcText = $FuncAst.Extent.Text
    if ($funcText -match '\$IsWindows|\$IsLinux|\$IsMacOS') {
        $platformSignals += 'platform_check'
    }
    if ($funcText -match 'Get-CimInstance|Get-WmiObject|HKLM:|HKCU:') {
        $platformSignals += 'windows_only_cmdlet'
    }
    if ($funcText -match '\\\\|"\\\\') {
        $platformSignals += 'hardcoded_separator'
    }
    if ($funcText -match 'powershell\.exe') {
        $platformSignals += 'windows_powershell_invocation'
    }
    if ($funcText -match 'New-Object\s+-ComObject|\[System\.__ComObject\]') {
        $platformSignals += 'com_object'
    }

    # CBH detection
    $hasCbh = $false
    if ($FuncAst.GetHelpContent()) {
        $help = $FuncAst.GetHelpContent()
        $hasCbh = $null -ne $help.Synopsis -or $null -ne $help.Description
    }

    return [ordered]@{
        name                    = $FuncAst.Name
        line_start              = $FuncAst.Extent.StartLineNumber
        line_end                = $FuncAst.Extent.EndLineNumber
        parameters              = $params
        output_type_declared    = $outputTypes
        has_process_block       = $hasProcessBlock
        supports_should_process = $supportsShouldProcess
        has_cbh                 = $hasCbh
        calls                   = $calls
        scope_writes            = $scopeWrites
        platform_signals        = $platformSignals
    }
}

function ConvertTo-FileEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory)]
        [string]$Hash,
        [Parameter(Mandatory)]
        [string]$Path
    )

    $functionAsts = $Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)

    $functions = @($functionAsts | ForEach-Object { ConvertTo-FunctionEntry -FuncAst $_ })

    $isTest = $Path -match '\.Tests\.ps1$' -or $Path -match '[/\\]tests?[/\\]'
    $isManifest = $Path -match '\.psd1$'
    $isModule = $Path -match '\.psm1$'

    return [ordered]@{
        hash         = $Hash
        functions    = $functions
        is_test      = $isTest
        is_manifest  = $isManifest
        is_module    = $isModule
    }
}

# Walk and parse
$pwshFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FullName -notmatch '[/\\]\.pwsh-review[/\\]cache[/\\]' -and
        $_.FullName -notmatch '[/\\]\.git[/\\]'
    }

$parsed = 0
$cached = 0

foreach ($file in $pwshFiles) {
    $relPath = [System.IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
    $hash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash

    if ($index.files.Contains($relPath) -and $index.files[$relPath].hash -eq $hash) {
        $cached++
        continue
    }

    $tokens = $errors = $null
    $ast = $null
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName, [ref]$tokens, [ref]$errors
        )
    } catch {
        Write-Warning "Failed to parse ${relPath}: $($_.Exception.Message)"
        continue
    }

    try {
        $index.files[$relPath] = ConvertTo-FileEntry -Ast $ast -Hash $hash -Path $relPath
        $parsed++
    } catch {
        Write-Warning "Failed to index ${relPath}: $($_.Exception.Message)"
    }
}

# Remove deleted files
$liveFiles = @($pwshFiles | ForEach-Object {
    [System.IO.Path]::GetRelativePath($RepoRoot, $_.FullName).Replace('\', '/')
})
$deleted = @($index.files.Keys | Where-Object { $_ -notin $liveFiles })
foreach ($d in $deleted) {
    $index.files.Remove($d)
}

# Build cross-references
$index.function_to_file = [ordered]@{}
foreach ($filePath in $index.files.Keys) {
    foreach ($func in $index.files[$filePath].functions) {
        $index.function_to_file[$func.name] = $filePath
    }
}

$index.callers_of = [ordered]@{}
foreach ($filePath in $index.files.Keys) {
    foreach ($func in $index.files[$filePath].functions) {
        foreach ($call in $func.calls) {
            if ($index.function_to_file.Contains($call)) {
                if (-not $index.callers_of.Contains($call)) {
                    $index.callers_of[$call] = @()
                }
                $context = if ($index.files[$filePath].is_test) { 'test' }
                           elseif ($index.files[$filePath].is_module) { 'init' }
                           else { 'function-body' }
                $index.callers_of[$call] += [ordered]@{
                    file    = $filePath
                    line    = $func.line_start
                    context = $context
                    caller  = $func.name
                }
            }
        }
    }
}

$index.tests_for = [ordered]@{}
foreach ($funcName in $index.function_to_file.Keys) {
    $tests = @()

    # Direct match: tests/<FunctionName>.Tests.ps1 or sibling
    foreach ($filePath in $index.files.Keys) {
        if (-not $index.files[$filePath].is_test) { continue }

        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
        if ($fileName -match "^$([regex]::Escape($funcName))(\.|$)") {
            $tests += $filePath
            continue
        }

        # Indirect match: test file calls the function
        foreach ($func in $index.files[$filePath].functions) {
            if ($funcName -in $func.calls) {
                $tests += $filePath
                break
            }
        }
    }

    if ($tests) {
        $index.tests_for[$funcName] = @($tests | Select-Object -Unique)
    }
}

# Write
$json = $index | ConvertTo-Json -Depth 30
$json | Set-Content $indexPath -Encoding utf8NoBOM

Write-Verbose "AST index updated: $parsed parsed, $cached cached, $($deleted.Count) removed"

[pscustomobject]@{
    Files          = $index.files.Count
    Parsed         = $parsed
    Cached         = $cached
    Deleted        = $deleted.Count
    Functions      = $index.function_to_file.Count
    IndexPath      = $indexPath
}
