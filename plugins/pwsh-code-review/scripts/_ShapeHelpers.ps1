#requires -Version 7.4
<#
Shape extraction helpers shared by Get-AstIndex.ps1 (writes index) and
Get-DiffContext.ps1 (compares pre/post versions of changed functions).

Dot-source this file from a script that already sets ErrorActionPreference
and StrictMode. The helpers do not depend on either.

Returned shapes (canonical-empty contract: callers always get a real array):

  Get-EmitsShape -FuncAst <FunctionDefinitionAst>
    -> @(
         [ordered]@{ kind; line; properties; dynamic_keys },
         ...
       )

  Get-ConsumesShape -FuncAst <FunctionDefinitionAst>
    -> @(
         [ordered]@{ via_call; property; line; dynamic },
         ...
       )
#>

function Get-EmitsShape {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.FunctionDefinitionAst]$FuncAst
    )

    $sites = @()
    $seenHashtables = @{}

    # 1. [pscustomobject]@{...} / [psobject]@{...} / [ordered]@{...}
    $convertHashtables = @($FuncAst.FindAll({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.ConvertExpressionAst]) { return $false }
        if ($null -eq $node.Type -or $null -eq $node.Type.TypeName) { return $false }
        $typeName = $node.Type.TypeName.Name
        if ($typeName -inotin @('pscustomobject', 'psobject', 'ordered')) { return $false }
        $node.Child -is [System.Management.Automation.Language.HashtableAst]
    }, $true))

    foreach ($conv in $convertHashtables) {
        $ht = $conv.Child
        $key = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($ht)
        $seenHashtables[$key] = $true
        $sites += (Convert-HashtableToShapeSite -Ht $ht -Kind 'pscustomobject')
    }

    # 2. Bare hashtable as the trailing value of an explicit `return @{...}`
    $returns = @($FuncAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ReturnStatementAst]
    }, $true))

    foreach ($ret in $returns) {
        if ($null -eq $ret.Pipeline) { continue }
        $ht = Get-TrailingHashtable -Pipeline $ret.Pipeline
        if ($null -ne $ht) {
            $key = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($ht)
            if (-not $seenHashtables.ContainsKey($key)) {
                $seenHashtables[$key] = $true
                $sites += (Convert-HashtableToShapeSite -Ht $ht -Kind 'hashtable')
            }
        }
    }

    # 3. New-Object ... -Property @{...}
    $newObjects = @($FuncAst.FindAll({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
        $node.GetCommandName() -eq 'New-Object'
    }, $true))

    foreach ($cmd in $newObjects) {
        $elements = @($cmd.CommandElements)
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $el = $elements[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                $el.ParameterName -ieq 'Property' -and
                $i + 1 -lt $elements.Count) {
                $next = $elements[$i + 1]
                $ht = if ($next -is [System.Management.Automation.Language.HashtableAst]) {
                    $next
                } elseif ($next -is [System.Management.Automation.Language.ParenExpressionAst] -and
                          $next.Pipeline.PipelineElements.Count -eq 1) {
                    $inner = $next.Pipeline.PipelineElements[0]
                    if ($inner -is [System.Management.Automation.Language.CommandExpressionAst] -and
                        $inner.Expression -is [System.Management.Automation.Language.HashtableAst]) {
                        $inner.Expression
                    } else { $null }
                } else { $null }

                if ($null -ne $ht) {
                    $key = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($ht)
                    if (-not $seenHashtables.ContainsKey($key)) {
                        $seenHashtables[$key] = $true
                        $sites += (Convert-HashtableToShapeSite -Ht $ht -Kind 'newobject_property')
                    }
                }
            }
        }
    }

    return ,@($sites)
}

function Get-TrailingHashtable {
    [CmdletBinding()]
    param(
        [System.Management.Automation.Language.PipelineBaseAst]$Pipeline
    )
    if ($null -eq $Pipeline) { return $null }
    if ($Pipeline -isnot [System.Management.Automation.Language.PipelineAst]) { return $null }
    if ($Pipeline.PipelineElements.Count -ne 1) { return $null }
    $el = $Pipeline.PipelineElements[0]
    if ($el -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $null }
    $expr = $el.Expression
    while ($expr -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $inner = $expr.Pipeline
        if ($inner -isnot [System.Management.Automation.Language.PipelineAst]) { return $null }
        if ($inner.PipelineElements.Count -ne 1) { return $null }
        $cmdEl = $inner.PipelineElements[0]
        if ($cmdEl -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $null }
        $expr = $cmdEl.Expression
    }
    if ($expr -is [System.Management.Automation.Language.HashtableAst]) { return $expr }
    return $null
}

function Convert-HashtableToShapeSite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.HashtableAst]$Ht,
        [Parameter(Mandatory)]
        [string]$Kind
    )
    $properties = @()
    $dynamic = $false
    foreach ($pair in $Ht.KeyValuePairs) {
        $keyAst = $pair.Item1
        $literalKey = $null
        if ($keyAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $literalKey = $keyAst.Value
        } elseif ($keyAst -is [System.Management.Automation.Language.ConstantExpressionAst] -and
                  $keyAst.Value -is [string]) {
            $literalKey = [string]$keyAst.Value
        }
        if ($null -ne $literalKey) {
            $properties += $literalKey
        } else {
            $dynamic = $true
        }
    }
    return [ordered]@{
        kind         = $Kind
        line         = $Ht.Extent.StartLineNumber
        properties   = @($properties | Select-Object -Unique)
        dynamic_keys = $dynamic
    }
}

function Get-ConsumesShape {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.FunctionDefinitionAst]$FuncAst
    )

    $bindings = @{}

    # Pass 1: collect first-binding assignments. Walk in source order.
    $assignments = @($FuncAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true) | Sort-Object { $_.Extent.StartOffset })

    foreach ($asn in $assignments) {
        if ($asn.Operator -ne 'Equals') { continue }
        if ($asn.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }

        $varName = $asn.Left.VariablePath.UserPath
        if ([string]::IsNullOrWhiteSpace($varName)) { continue }
        $key = $varName.ToLowerInvariant()
        if ($bindings.ContainsKey($key)) { continue }

        $calledFunc = Get-CalledFunctionFromRhs -Rhs $asn.Right
        if ($null -ne $calledFunc) {
            $bindings[$key] = $calledFunc
        }
    }

    # Pass 2: collect property accesses on bound variables, plus inline (Func).Prop accesses.
    $sites = @()

    $memberAccesses = @($FuncAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.MemberExpressionAst]
    }, $true))

    foreach ($mem in $memberAccesses) {
        $expr = $mem.Expression
        $viaCall = $null

        if ($expr -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $varName = $expr.VariablePath.UserPath
            if (-not [string]::IsNullOrWhiteSpace($varName)) {
                $key = $varName.ToLowerInvariant()
                if ($bindings.ContainsKey($key)) {
                    $viaCall = $bindings[$key]
                }
            }
        } elseif ($expr -is [System.Management.Automation.Language.ParenExpressionAst]) {
            $viaCall = Get-CalledFunctionFromParen -Paren $expr
        }

        if ($null -eq $viaCall) { continue }

        $isDynamic = -not ($mem.Member -is [System.Management.Automation.Language.StringConstantExpressionAst])
        $propName = if ($isDynamic) { '*' } else { $mem.Member.Value }

        $sites += [ordered]@{
            via_call = $viaCall
            property = $propName
            line     = $mem.Extent.StartLineNumber
            dynamic  = $isDynamic
        }
    }

    # Index-style access: $var['Prop']
    $indexAccesses = @($FuncAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.IndexExpressionAst]
    }, $true))

    foreach ($idx in $indexAccesses) {
        $target = $idx.Target
        $viaCall = $null

        if ($target -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $varName = $target.VariablePath.UserPath
            if (-not [string]::IsNullOrWhiteSpace($varName)) {
                $key = $varName.ToLowerInvariant()
                if ($bindings.ContainsKey($key)) {
                    $viaCall = $bindings[$key]
                }
            }
        }
        if ($null -eq $viaCall) { continue }

        $indexExpr = $idx.Index
        if ($indexExpr -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $sites += [ordered]@{
                via_call = $viaCall
                property = $indexExpr.Value
                line     = $idx.Extent.StartLineNumber
                dynamic  = $false
            }
        } else {
            $sites += [ordered]@{
                via_call = $viaCall
                property = '*'
                line     = $idx.Extent.StartLineNumber
                dynamic  = $true
            }
        }
    }

    return ,@($sites)
}

function Get-CalledFunctionFromRhs {
    [CmdletBinding()]
    param($Rhs)
    $expr = $Rhs
    if ($expr -is [System.Management.Automation.Language.PipelineAst]) {
        if ($expr.PipelineElements.Count -ne 1) { return $null }
        $first = $expr.PipelineElements[0]
        if ($first -is [System.Management.Automation.Language.CommandAst]) {
            return $first.GetCommandName()
        }
        if ($first -is [System.Management.Automation.Language.CommandExpressionAst]) {
            $expr = $first.Expression
        } else {
            return $null
        }
    }
    while ($expr -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $expr = Get-CalledFunctionExprFromParen -Paren $expr
        if ($expr -is [string]) { return $expr }
        if ($null -eq $expr) { return $null }
    }
    if ($expr -is [System.Management.Automation.Language.CommandAst]) {
        return $expr.GetCommandName()
    }
    return $null
}

function Get-CalledFunctionExprFromParen {
    param([System.Management.Automation.Language.ParenExpressionAst]$Paren)
    $inner = $Paren.Pipeline
    if ($inner -isnot [System.Management.Automation.Language.PipelineAst]) { return $null }
    if ($inner.PipelineElements.Count -ne 1) { return $null }
    $first = $inner.PipelineElements[0]
    if ($first -is [System.Management.Automation.Language.CommandAst]) {
        return $first.GetCommandName()
    }
    if ($first -is [System.Management.Automation.Language.CommandExpressionAst]) {
        return $first.Expression
    }
    return $null
}

function Get-CalledFunctionFromParen {
    param([System.Management.Automation.Language.ParenExpressionAst]$Paren)
    $expr = Get-CalledFunctionExprFromParen -Paren $Paren
    if ($expr -is [string]) { return $expr }
    while ($expr -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $expr = Get-CalledFunctionExprFromParen -Paren $expr
        if ($expr -is [string]) { return $expr }
    }
    if ($expr -is [System.Management.Automation.Language.CommandAst]) {
        return $expr.GetCommandName()
    }
    return $null
}

function Compare-EmitShapesForDrop {
    <#
    Given pre and post emits_shape arrays for the same function, return:
      properties_dropped: properties consistently emitted before, never emitted after
      properties_added:   properties never emitted before, consistently emitted after
    Conservative direction. Excludes properties that came from any
    dynamic-keys site to avoid false positives.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [object[]]$PreEmits,
        [object[]]$PostEmits
    )

    $consistentPre  = Get-ConsistentlyEmittedProperties -Sites $PreEmits
    $consistentPost = Get-ConsistentlyEmittedProperties -Sites $PostEmits

    $dropped = @()
    foreach ($p in $consistentPre) {
        if ($p -notin $consistentPost) { $dropped += $p }
    }
    $added = @()
    foreach ($p in $consistentPost) {
        if ($p -notin $consistentPre) { $added += $p }
    }
    return @{
        properties_dropped = @($dropped)
        properties_added   = @($added)
    }
}

function Get-ConsistentlyEmittedProperties {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([object[]]$Sites)

    $sites = @($Sites | Where-Object { $null -ne $_ })
    if ($sites.Count -eq 0) { return @() }

    # If any site has dynamic_keys, we cannot tell whether an unseen
    # literal property is also emitted — be conservative and consider
    # nothing as "consistently emitted" for that function.
    foreach ($s in $sites) {
        if ($s.dynamic_keys) { return @() }
    }

    # Intersection of all sites' properties.
    $first = $true
    $intersection = @()
    foreach ($s in $sites) {
        $props = @($s.properties)
        if ($first) {
            $intersection = @($props)
            $first = $false
        } else {
            $intersection = @($intersection | Where-Object { $_ -in $props })
        }
    }
    return ,@($intersection | Select-Object -Unique)
}
