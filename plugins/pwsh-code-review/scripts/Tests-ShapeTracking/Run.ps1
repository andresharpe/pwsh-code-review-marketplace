#requires -Version 7.4
<#
Self-test runner for shape-tracking helpers in _ShapeHelpers.ps1.

Exits non-zero if any assertion fails. The runner exercises:
  - Get-EmitsShape against pre/post emitter fixtures
  - Get-ConsumesShape against four consumer styles
  - Compare-EmitShapesForDrop on (pre, post) and (pre, pre)
  - Stale-consumer enumeration (the same logic Get-DiffContext.ps1 uses)
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$scripts = Split-Path -Parent $here
. (Join-Path $scripts '_ShapeHelpers.ps1')

$failures = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        Write-Host "  FAIL: $Message" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "  pass: $Message" -ForegroundColor DarkGreen
    }
}

function Get-FuncAst {
    param([string]$Path, [string]$FuncName)
    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors
    )
    if ($errors) {
        throw "Parse errors in ${Path}: $($errors[0].Message)"
    }
    $func = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq $FuncName
    }, $true) | Select-Object -First 1
    if (-not $func) { throw "Function $FuncName not found in $Path" }
    return $func
}

Write-Host "=== Get-EmitsShape ===" -ForegroundColor Cyan

$preFunc = Get-FuncAst -Path (Join-Path $here 'fixture-emitter-pre.ps1') -FuncName 'Get-Widget'
$preEmits = @(Get-EmitsShape -FuncAst $preFunc)
Assert-True ($preEmits.Count -eq 1) "pre emitter has exactly 1 emit-site (got $($preEmits.Count))"
Assert-True ($preEmits[0].kind -eq 'pscustomobject') "pre emit-site kind is pscustomobject"
Assert-True ($preEmits[0].dynamic_keys -eq $false) "pre emit-site has no dynamic keys"
$missing = @(@('Id','Name','Color') | Where-Object { $_ -notin $preEmits[0].properties })
Assert-True ($missing.Count -eq 0) "pre emit-site has Id, Name, Color (missing: $($missing -join ','))"
Assert-True ($preEmits[0].properties.Count -eq 3) "pre emit-site has exactly 3 properties"

$postFunc = Get-FuncAst -Path (Join-Path $here 'fixture-emitter-post.ps1') -FuncName 'Get-Widget'
$postEmits = @(Get-EmitsShape -FuncAst $postFunc)
Assert-True ($postEmits.Count -eq 1) "post emitter has 1 emit-site"
Assert-True ($postEmits[0].properties.Count -eq 2) "post emit-site has 2 properties"
Assert-True ('Color' -notin $postEmits[0].properties) "post emit-site does not include Color"

Write-Host ""
Write-Host "=== Get-ConsumesShape ===" -ForegroundColor Cyan

$consumerFunc = Get-FuncAst -Path (Join-Path $here 'fixture-consumer.ps1') -FuncName 'Use-Widget'
$cs = @(Get-ConsumesShape -FuncAst $consumerFunc)
Assert-True ($cs.Count -eq 1) "Use-Widget has 1 consume-site (got $($cs.Count))"
if ($cs.Count -ge 1) {
    Assert-True ($cs[0].via_call -eq 'Get-Widget') "consume via_call = Get-Widget"
    Assert-True ($cs[0].property -eq 'Color') "consume property = Color"
    Assert-True ($cs[0].dynamic -eq $false) "consume is literal"
}

$inlineFunc = Get-FuncAst -Path (Join-Path $here 'fixture-consumer-inline.ps1') -FuncName 'Use-WidgetInline'
$cs = @(Get-ConsumesShape -FuncAst $inlineFunc)
Assert-True ($cs.Count -eq 1) "Use-WidgetInline has 1 consume-site (got $($cs.Count))"
if ($cs.Count -ge 1) {
    Assert-True ($cs[0].via_call -eq 'Get-Widget') "inline via_call = Get-Widget"
    Assert-True ($cs[0].property -eq 'Color') "inline property = Color"
    Assert-True ($cs[0].dynamic -eq $false) "inline access is literal"
}

$indexFunc = Get-FuncAst -Path (Join-Path $here 'fixture-consumer-index.ps1') -FuncName 'Use-WidgetIndex'
$cs = @(Get-ConsumesShape -FuncAst $indexFunc)
Assert-True ($cs.Count -eq 1) "Use-WidgetIndex has 1 consume-site (got $($cs.Count))"
if ($cs.Count -ge 1) {
    Assert-True ($cs[0].via_call -eq 'Get-Widget') "index via_call = Get-Widget"
    Assert-True ($cs[0].property -eq 'Color') "index property = Color"
    Assert-True ($cs[0].dynamic -eq $false) "index access (literal key) is non-dynamic"
}

$dynamicFunc = Get-FuncAst -Path (Join-Path $here 'fixture-consumer-dynamic.ps1') -FuncName 'Use-WidgetDynamic'
$cs = @(Get-ConsumesShape -FuncAst $dynamicFunc)
Assert-True ($cs.Count -eq 1) "Use-WidgetDynamic has 1 consume-site (got $($cs.Count))"
if ($cs.Count -ge 1) {
    Assert-True ($cs[0].via_call -eq 'Get-Widget') "dynamic via_call = Get-Widget"
    Assert-True ($cs[0].dynamic -eq $true) "dynamic access flagged"
    Assert-True ($cs[0].property -eq '*') "dynamic property is *"
}

Write-Host ""
Write-Host "=== Compare-EmitShapesForDrop ===" -ForegroundColor Cyan

$diff = Compare-EmitShapesForDrop -PreEmits $preEmits -PostEmits $postEmits
Assert-True (@($diff.properties_dropped).Count -eq 1) "exactly 1 property dropped (got $(@($diff.properties_dropped).Count))"
Assert-True ($diff.properties_dropped[0] -eq 'Color') "dropped property = Color"
Assert-True (@($diff.properties_added).Count -eq 0) "no properties added"

$noopDiff = Compare-EmitShapesForDrop -PreEmits $preEmits -PostEmits $preEmits
Assert-True (@($noopDiff.properties_dropped).Count -eq 0) "no-op diff: no drops"
Assert-True (@($noopDiff.properties_added).Count -eq 0) "no-op diff: no adds"

Write-Host ""
Write-Host "=== Stale-consumer enumeration ===" -ForegroundColor Cyan

# Build a synthetic mini-index that mirrors what Get-AstIndex.ps1 produces.
$consumerEntries = @(
    @{ name = 'Use-Widget';        consumes_shape = @(Get-ConsumesShape -FuncAst $consumerFunc) }
    @{ name = 'Use-WidgetInline';  consumes_shape = @(Get-ConsumesShape -FuncAst $inlineFunc) }
    @{ name = 'Use-WidgetIndex';   consumes_shape = @(Get-ConsumesShape -FuncAst $indexFunc) }
    @{ name = 'Use-WidgetDynamic'; consumes_shape = @(Get-ConsumesShape -FuncAst $dynamicFunc) }
)

$miniIndex = @{
    files = @{
        'consumers.ps1' = @{ functions = $consumerEntries }
    }
    callers_of = @{
        'Get-Widget' = @(
            @{ file = 'consumers.ps1'; caller = 'Use-Widget';        line = 1 }
            @{ file = 'consumers.ps1'; caller = 'Use-WidgetInline';  line = 1 }
            @{ file = 'consumers.ps1'; caller = 'Use-WidgetIndex';   line = 1 }
            @{ file = 'consumers.ps1'; caller = 'Use-WidgetDynamic'; line = 1 }
        )
    }
}

# Mimic the stale-consumer walk in Get-DiffContext.ps1.
$dropped = $diff.properties_dropped
$droppedLower = @($dropped | ForEach-Object { $_.ToLowerInvariant() })
$staleConsumers = @()
foreach ($callerRec in $miniIndex.callers_of['Get-Widget']) {
    $callerFile = $callerRec.file
    $callerName = $callerRec.caller
    $callerFunc = $miniIndex.files[$callerFile].functions |
        Where-Object { $_.name -eq $callerName } |
        Select-Object -First 1
    if (-not $callerFunc) { continue }
    foreach ($consumerSite in @($callerFunc.consumes_shape)) {
        if ($consumerSite.via_call -ne 'Get-Widget') { continue }
        if ($consumerSite.dynamic) { continue }
        if ($consumerSite.property.ToLowerInvariant() -notin $droppedLower) { continue }
        $staleConsumers += @{
            caller_function = $callerName
            caller_file     = $callerFile
            consumer_line   = $consumerSite.line
            property        = $consumerSite.property
            dynamic         = $consumerSite.dynamic
        }
    }
}

Assert-True ($staleConsumers.Count -eq 3) "3 stale consumers (assignment, inline, index); got $($staleConsumers.Count)"
$names = @($staleConsumers | ForEach-Object { $_.caller_function })
Assert-True ('Use-Widget' -in $names) "Use-Widget caught"
Assert-True ('Use-WidgetInline' -in $names) "Use-WidgetInline caught"
Assert-True ('Use-WidgetIndex' -in $names) "Use-WidgetIndex caught"
Assert-True ('Use-WidgetDynamic' -notin $names) "Use-WidgetDynamic excluded (dynamic access)"

Write-Host ""
if ($failures -eq 0) {
    Write-Host "All shape-tracking self-tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failures assertion(s) failed." -ForegroundColor Red
    exit 1
}
