#requires -Version 7.4
<#
.SYNOPSIS
    Discovers `{{TOKEN}}` template placeholders that PowerShell `-replace`
    statements in the repository will substitute at runtime.

.DESCRIPTION
    Walks every `.ps1`/`.psm1` file under the repo root, parses each AST,
    and finds expressions of the form

        $someVar -replace '\{\{TOKEN_NAME\}\}', $rhs

    For each token found, returns:

        - name: the literal token text (e.g. 'TASK_ID')
        - defined_at: 'relative/path:line' of the `-replace` site
        - always_nonempty: $true when the RHS variable is provably never an
          empty string (parameter with non-empty default, unconditional
          string-literal assignment, or every branch of an if/elseif/else
          assignment terminates in a non-empty string literal). $false when
          uncertain — the agent / static check should hedge.

    The function is shared between `Initialize-ReviewProfile.ps1` (which
    snapshots the result to `.pwsh-review/template-rules.json`) and
    `Test-TemplateSubstitution.ps1` (which uses it at review time when no
    snapshot exists).

.PARAMETER RepoRoot
    Repository root.

.PARAMETER ExcludeGlobs
    Glob patterns whose matches are skipped. Defaults to vendored / cache /
    plugin-internal paths.

.OUTPUTS
    Array of [pscustomobject] with Name, DefinedAt, AlwaysNonEmpty.
#>
[CmdletBinding()]
[OutputType([pscustomobject[]])]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string[]]$ExcludeGlobs = @(
        '*/.pwsh-review/*'
        '*/node_modules/*'
        '*/.git/*'
    )
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# ---------------------------------------------------------------------------

function Test-StringNonEmpty {
    <#
    Returns $true when an AST node represents a non-empty string literal.
    #>
    param([Parameter(Mandatory)]$Node)
    if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return [string]::IsNullOrEmpty($Node.Value) -eq $false
    }
    if ($Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        return [string]::IsNullOrEmpty($Node.Value) -eq $false
    }
    return $false
}

function Test-IfStatementHasNonEmptyFallback {
    <#
    For an expression-form `$x = if (...) { ... } else { "literal" }`,
    return $true when the else clause's last statement is a non-empty
    string literal. The if/elseif clauses can be any expression — we
    accept that on faith, mirroring the statement-form heuristic.
    #>
    param([Parameter(Mandatory)]$IfAst)
    if ($IfAst -isnot [System.Management.Automation.Language.IfStatementAst]) { return $false }
    if (-not $IfAst.ElseClause) { return $false }

    $elseStmts = @($IfAst.ElseClause.Statements)
    if ($elseStmts.Count -eq 0) { return $false }
    $last = $elseStmts[-1]

    if ($last -is [System.Management.Automation.Language.PipelineAst] -and
        $last.PipelineElements.Count -eq 1) {
        $expr = $last.PipelineElements[0]
        if ($expr -is [System.Management.Automation.Language.CommandExpressionAst]) {
            return Test-StringNonEmpty -Node $expr.Expression
        }
    }
    if ($last -is [System.Management.Automation.Language.CommandExpressionAst]) {
        return Test-StringNonEmpty -Node $last.Expression
    }
    return $false
}

function Test-AssignmentRhsAlwaysNonEmpty {
    <#
    Inspect the RHS of an assignment. Returns $true when the RHS is provably
    a non-empty string at runtime.
    #>
    param([Parameter(Mandatory)]$Rhs)

    # Unwrap a single-element PipelineAst.
    if ($Rhs -is [System.Management.Automation.Language.PipelineAst] -and
        $Rhs.PipelineElements.Count -eq 1) {
        return Test-AssignmentRhsAlwaysNonEmpty -Rhs $Rhs.PipelineElements[0]
    }
    if ($Rhs -is [System.Management.Automation.Language.CommandExpressionAst]) {
        $expr = $Rhs.Expression
        if (Test-StringNonEmpty -Node $expr) { return $true }
        if ($expr -is [System.Management.Automation.Language.ParenExpressionAst]) {
            return Test-AssignmentRhsAlwaysNonEmpty -Rhs $expr.Pipeline
        }
        return $false
    }

    # Statement-form RHS (e.g. `$x = if (...) { ... } else { ... }` parses
    # the if as the assignment's value).
    if ($Rhs -is [System.Management.Automation.Language.IfStatementAst]) {
        return Test-IfStatementHasNonEmptyFallback -IfAst $Rhs
    }

    # Bare expression form.
    if (Test-StringNonEmpty -Node $Rhs) { return $true }

    return $false
}

function Get-AssignmentRhsList {
    <#
    Find every assignment to $varName inside a scope. Returns an array of
    Ast nodes (the right-hand side of each assignment).
    #>
    param(
        [Parameter(Mandatory)]$ScopeAst,
        [Parameter(Mandatory)][string]$VarName
    )
    $captured = $VarName
    $predicate = {
        param($n)
        if ($n -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { return $false }
        $left = $n.Left
        if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $false }
        if ($left.VariablePath.UserPath -ne $captured) { return $false }
        return $true
    }.GetNewClosure()
    $assignments = $ScopeAst.FindAll($predicate, $true)
    return @($assignments | ForEach-Object { $_.Right })
}

function Test-ParamHasNonEmptyDefault {
    <#
    For a function whose param block declares $varName with a string-literal
    default value, return $true if the default is non-empty.
    #>
    param(
        [Parameter(Mandatory)]$ScopeAst,
        [Parameter(Mandatory)][string]$VarName
    )
    if ($ScopeAst -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
        return $false
    }
    $body = $ScopeAst.Body
    if (-not $body.ParamBlock) { return $false }
    foreach ($p in $body.ParamBlock.Parameters) {
        if ($p.Name.VariablePath.UserPath -ne $VarName) { continue }
        if ($null -eq $p.DefaultValue) { return $false }
        return Test-StringNonEmpty -Node $p.DefaultValue
    }
    return $false
}

function Get-EnclosingScope {
    <#
    Walks up from $Node and returns the nearest enclosing scope: a
    FunctionDefinitionAst if there is one, otherwise the script-root
    ScriptBlockAst. Top-level `.ps1` code lives in the root script-block;
    we treat that as the variable's scope when no function wraps the site.
    #>
    param([Parameter(Mandatory)]$Node)
    $cur = $Node.Parent
    $root = $null
    while ($null -ne $cur) {
        if ($cur -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $cur
        }
        if ($cur -is [System.Management.Automation.Language.ScriptBlockAst]) {
            $root = $cur
        }
        $cur = $cur.Parent
    }
    return $root
}

function Test-ScopeIsFunction {
    param([Parameter(Mandatory)]$Scope)
    return $Scope -is [System.Management.Automation.Language.FunctionDefinitionAst]
}

function Find-AssignmentInBlock {
    <#
    Returns the first AssignmentStatementAst inside $Block whose left side
    is the variable named $VarName. Returns $null if none found.
    #>
    param($Block, [string]$VarName)
    if ($Block -isnot [System.Management.Automation.Language.StatementBlockAst]) { return $null }
    foreach ($s in @($Block.Statements)) {
        if ($s -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { continue }
        $left = $s.Left
        if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        if ($left.VariablePath.UserPath -eq $VarName) { return $s }
    }
    return $null
}

function Test-IfStatementOverwritesNonEmpty {
    <#
    Returns $true when an IfStatementAst is exhaustive (has an else clause),
    every clause assigns to $VarName, AND the else-branch's assignment RHS
    is a non-empty string literal.
    #>
    param(
        [Parameter(Mandatory)]$IfAst,
        [Parameter(Mandatory)][string]$VarName
    )
    if ($IfAst -isnot [System.Management.Automation.Language.IfStatementAst]) { return $false }
    if (-not $IfAst.ElseClause) { return $false }

    foreach ($pair in $IfAst.Clauses) {
        if (-not (Find-AssignmentInBlock -Block $pair.Item2 -VarName $VarName)) { return $false }
    }
    $elseAsn = Find-AssignmentInBlock -Block $IfAst.ElseClause -VarName $VarName
    if (-not $elseAsn) { return $false }

    return Test-AssignmentRhsAlwaysNonEmpty -Rhs $elseAsn.Right
}

function Test-RhsAlwaysNonEmpty {
    <#
    Given a `-replace` whose RHS is a variable reference $varName, decide
    whether the variable is provably non-empty at the replace site.

    Cases that mark a token "always non-empty":
      1. The parameter has a non-empty string-literal default.
      2. The function body has an exhaustive `if/elseif/else` block where
         every branch assigns $varName to a non-empty literal (the dotbot
         init-then-overwrite idiom).
      3. The variable is assigned via expression-form `$x = if (...) { ... }
         else { "literal" }` whose every branch yields a non-empty string.
      4. Every plain assignment (and the param default, if any) produces a
         non-empty string literal — i.e. there's no path that could leave
         the variable empty.

    Conservative on falsy: when the analyser can't prove non-empty, it
    returns $false (the static check then hedges its finding).
    #>
    param(
        [Parameter(Mandatory)]$ReplaceCallNode,
        [Parameter(Mandatory)][string]$VarName
    )
    $scope = Get-EnclosingScope -Node $ReplaceCallNode
    if (-not $scope) { return $false }

    # Case 1: parameter with non-empty default (only meaningful for function
    # scopes — script-root scripts have $args, not param defaults of interest).
    if (Test-ScopeIsFunction -Scope $scope) {
        if (Test-ParamHasNonEmptyDefault -ScopeAst $scope -VarName $VarName) {
            return $true
        }
    }

    # Case 2: exhaustive if/else that overwrites the variable in every branch.
    # Walk the entire body for if-statements (covers nested constructs too).
    $allIfs = $scope.FindAll({
        param($n) $n -is [System.Management.Automation.Language.IfStatementAst]
    }, $true)
    foreach ($if in @($allIfs)) {
        if (Test-IfStatementOverwritesNonEmpty -IfAst $if -VarName $VarName) {
            return $true
        }
    }

    # Case 3 + 4: every assignment-form RHS is provably non-empty.
    $rhsList = @(Get-AssignmentRhsList -ScopeAst $scope -VarName $VarName)
    if ($rhsList.Count -eq 0) { return $false }
    foreach ($r in $rhsList) {
        if (-not (Test-AssignmentRhsAlwaysNonEmpty -Rhs $r)) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------------------

function Find-ReplaceTokenSites {
    <#
    Walk an AST for binary `-replace` expressions whose left operand is the
    literal `\{\{TOKEN\}\}` and whose right operand is a variable. Return a
    list of @{ Token; ReplaceNode; Rhs } records.
    #>
    param([Parameter(Mandatory)]$Ast)

    $tokenRegex = [regex]::new('^\\\{\\\{([A-Z][A-Z0-9_]*)\\\}\\\}$')

    $candidates = $Ast.FindAll({
        param($n)
        if ($n -isnot [System.Management.Automation.Language.BinaryExpressionAst]) { return $false }
        if ($n.Operator -ne [System.Management.Automation.Language.TokenKind]::Ireplace) { return $false }
        return $true
    }, $true)

    $records = @()
    foreach ($c in $candidates) {
        # Walk through the chain of -replace ops: the actual pattern we want is
        # the second-from-left operand (a string literal), and the third (rhs)
        # is the substitution. PowerShell's -replace operator parses left-
        # associatively: `$x -replace 'a', $b` -> Binary(Op='replace', Left=$x,
        # Right=ArrayLiteral('a',$b)). The right side IS the @(pattern, rhs)
        # array literal.
        $right = $c.Right
        if ($right -is [System.Management.Automation.Language.ArrayLiteralAst]) {
            $elements = @($right.Elements)
            if ($elements.Count -lt 2) { continue }
            $patternAst = $elements[0]
            $rhsAst     = $elements[1]
        } else {
            # Single-arg form, e.g. `-replace 'a'` (deletes matches). Skip.
            continue
        }

        if (-not (Test-StringNonEmpty -Node $patternAst)) { continue }
        $patternText = $patternAst.Value
        $m = $tokenRegex.Match($patternText)
        if (-not $m.Success) { continue }
        $tokenName = $m.Groups[1].Value

        $records += [pscustomobject]@{
            Token        = $tokenName
            ReplaceNode  = $c
            Rhs          = $rhsAst
        }
    }
    return $records
}

# ---------------------------------------------------------------------------

function Find-TemplateTokensInRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$ExcludeGlobs
    )

    $files = Get-ChildItem -Path $RepoRoot -Recurse -File `
        -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue |
        Where-Object {
            $full = $_.FullName -replace '\\', '/'
            foreach ($pattern in $ExcludeGlobs) {
                $glob = $pattern -replace '\\', '/'
                if ($full -like $glob) { return $false }
            }
            return $true
        }

    $byToken = @{}

    foreach ($file in $files) {
        $rel = [System.IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
        $errs = $null
        $tokens = $null
        $ast = $null
        try {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$tokens, [ref]$errs)
        } catch {
            Write-Warning "Get-TemplateTokens: parse failed on $rel - $($_.Exception.Message)"
            continue
        }
        if (-not $ast) { continue }
        if ($errs -and @($errs).Count -gt 0) { continue }

        $sites = Find-ReplaceTokenSites -Ast $ast
        foreach ($s in $sites) {
            $line = $s.ReplaceNode.Extent.StartLineNumber
            $alwaysNonEmpty = $false
            if ($s.Rhs -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $varName = $s.Rhs.VariablePath.UserPath
                $alwaysNonEmpty = Test-RhsAlwaysNonEmpty `
                    -ReplaceCallNode $s.ReplaceNode `
                    -VarName $varName
            } elseif (Test-StringNonEmpty -Node $s.Rhs) {
                $alwaysNonEmpty = $true
            }

            $existing = $byToken[$s.Token]
            $location = "$($rel):$line"
            if (-not $existing) {
                $byToken[$s.Token] = [pscustomobject]@{
                    Name           = $s.Token
                    DefinedAt      = @($location)
                    AlwaysNonEmpty = $alwaysNonEmpty
                }
            } else {
                $existing.DefinedAt += $location
                # If any single -replace site can produce empty, the token is
                # not provably always-non-empty across the whole codebase.
                if (-not $alwaysNonEmpty) {
                    $existing.AlwaysNonEmpty = $false
                }
            }
        }
    }

    return @($byToken.Values | Sort-Object Name)
}

# ---------------------------------------------------------------------------
# Entry

Push-Location $RepoRoot
try {
    Find-TemplateTokensInRepo -RepoRoot $RepoRoot -ExcludeGlobs $ExcludeGlobs
} finally {
    Pop-Location
}
