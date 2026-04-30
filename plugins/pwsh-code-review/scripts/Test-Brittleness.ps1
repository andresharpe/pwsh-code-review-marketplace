#requires -Version 7.4
<#
.SYNOPSIS
    Detects brittle assertion patterns in PowerShell test files.

.DESCRIPTION
    Heuristic AST scan over Pester (`*.Tests.ps1`) and verb-noun
    (`Test-*.ps1`) test files. Emits findings under the `PWSH-TEST-NNN`
    rule namespace.

    Suppression via `# pwsh-review:disable-next-line PWSH-TEST-NNN` is
    documented in `docs/severity-rubric.md` but not yet implemented in
    the static layer; tracked for a follow-up PR.

.PARAMETER RepoRoot
    Repository root. Findings are emitted with paths relative to this.

.PARAMETER Path
    Explicit list of files or directories to scan. Files are filtered by
    convention: only `*.Tests.ps1` and `Test-*.ps1` files are parsed.
    When -All is set, this parameter is ignored.

.PARAMETER All
    Recursively scan the whole repo for matching test files.

.OUTPUTS
    Array of hashtables. Each hashtable matches the PSScriptAnalyzer-
    shape used by other static-layer producers, plus an additional
    `confidence` field honoured by `Merge-Findings.ps1`:
        @{ rule_name; severity; file; line; column; message; confidence }
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
    'PWSH-TEST-001' = @{ Severity = 'Information'; Confidence = 85 }  # minor
    'PWSH-TEST-002' = @{ Severity = 'Information'; Confidence = 75 }  # minor
    'PWSH-TEST-003' = @{ Severity = 'Warning';     Confidence = 80 }  # major
    'PWSH-TEST-004' = @{ Severity = 'Warning';     Confidence = 80 }  # major
    'PWSH-TEST-005' = @{ Severity = 'Warning';     Confidence = 90 }  # major
}

# Test-block anchors. Used by R3 and R4, which check production-code
# patterns (Sort|Unique pipelines, $hash.Keys access) that are bugs
# inside any test scriptblock — not just inside the assertion call.
$script:TestBlockAnchors = @(
    # Pester
    'Should', 'Describe', 'Context', 'It',
    'BeforeEach', 'AfterEach', 'BeforeAll', 'AfterAll'
    # Assert-* helpers (e.g. `Assert-True`) are matched by name prefix below.
)

function Test-IsInAssertion {
    <#
    Returns $true when the node is part of an assertion expression:
      - a descendant of a `Should` or `Assert-*` CommandAst (e.g. the
        argument to `Assert-True -Condition (...)`), OR
      - a sibling in a pipeline whose downstream element is a
        `Should` or `Assert-*` CommandAst (e.g. `$x | Should -Be 1`).
      - the node itself is a `Should` or `Assert-*` CommandAst.
    Used by R1 / R2 / R5, which flag the asserted expression itself.
    #>
    param(
        [Parameter(Mandatory)]
        $Node
    )
    $cur = $Node
    while ($null -ne $cur) {
        if ($cur -is [System.Management.Automation.Language.CommandAst]) {
            $name = $cur.GetCommandName()
            if ($name) {
                if ($name -eq 'Should') { return $true }
                if ($name -like 'Assert-*') { return $true }
            }
        }
        if ($cur -is [System.Management.Automation.Language.PipelineAst]) {
            foreach ($el in $cur.PipelineElements) {
                if ($el -is [System.Management.Automation.Language.CommandAst]) {
                    $name = $el.GetCommandName()
                    if ($name) {
                        if ($name -eq 'Should') { return $true }
                        if ($name -like 'Assert-*') { return $true }
                    }
                }
            }
        }
        $cur = $cur.Parent
    }
    return $false
}

function Test-IsInTestBlock {
    <#
    Returns $true when the node is inside any test scriptblock — Pester
    Describe/Context/It/Before*/After* or a Should/Assert-*. Used by R3
    and R4, which flag production-code patterns that are bugs even when
    the assertion sits at a different point in the script.
    #>
    param(
        [Parameter(Mandatory)]
        $Node
    )
    $cur = $Node.Parent
    while ($null -ne $cur) {
        if ($cur -is [System.Management.Automation.Language.CommandAst]) {
            $name = $cur.GetCommandName()
            if ($name) {
                if ($script:TestBlockAnchors -contains $name) { return $true }
                if ($name -like 'Assert-*') { return $true }
            }
        }
        $cur = $cur.Parent
    }
    return $false
}

function Get-CommandsInExpression {
    <#
    Walks an AST sub-tree and returns every CommandAst inside it.
    Used by R2 (does the LHS originate from Get-Content/Format-*/etc.).
    #>
    param([Parameter(Mandatory)]$Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
}

function Test-IsMultilineRegex {
    param([Parameter(Mandatory)][string]$Pattern)
    if ($Pattern.Contains('\n')) { return $true }
    if ($Pattern.Contains('[\s\S]*?')) { return $true }
    # Two `.*\n` style sequences in the same pattern.
    $matches = [regex]::Matches($Pattern, '\.\*\\n')
    if ($matches.Count -ge 2) { return $true }
    return $false
}

function Test-IsWindowsPathRegex {
    param([Parameter(Mandatory)][string]$Pattern)
    # Literal `\\` (an escaped backslash in regex => Windows path separator)
    # AND no forward slash (URLs / unix paths typically include them)
    if (-not $Pattern.Contains('\\')) { return $false }
    if ($Pattern.Contains('/')) { return $false }
    return $true
}

function Test-LooksLikeTestFile {
    param([Parameter(Mandatory)][string]$FilePath)
    $basename = [IO.Path]::GetFileName($FilePath)
    $isPester = $basename -like '*.Tests.ps1'
    $isVerbNoun = $basename -like 'Test-*.ps1'
    if (-not $isPester -and -not $isVerbNoun) { return $false }
    if ($isPester) { return $true }
    # Verb-noun convention: only treat as a test file if it actually
    # contains an assertion or Pester scaffolding. Excludes harnesses
    # like Run-Tests.ps1 / Test-Helpers.psm1-style files.
    try {
        $src = Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop
    } catch {
        return $false
    }
    return ($src -match '\b(Assert-\w+|Describe|It|Should)\b')
}

function Get-RuleSeverity {
    param([Parameter(Mandatory)][string]$Rule)
    return $script:Rules[$Rule].Severity
}

function Get-RuleConfidence {
    param([Parameter(Mandatory)][string]$Rule)
    return $script:Rules[$Rule].Confidence
}

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

function Test-Rule001 {
    # PWSH-TEST-001: `.Count -ge|-eq <int>` with int > 5 inside an assertion.
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$RelativePath
    )
    if ($Node -isnot [System.Management.Automation.Language.BinaryExpressionAst]) { return $null }
    $op = $Node.Operator
    if ($op -ne [System.Management.Automation.Language.TokenKind]::Ige -and
        $op -ne [System.Management.Automation.Language.TokenKind]::Ieq) { return $null }
    $left = $Node.Left
    if ($left -isnot [System.Management.Automation.Language.MemberExpressionAst]) { return $null }
    $member = $left.Member
    if ($member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
    if ($member.Value -ne 'Count') { return $null }
    $right = $Node.Right
    if ($right -isnot [System.Management.Automation.Language.ConstantExpressionAst]) { return $null }
    if ($right.Value -isnot [int]) { return $null }
    if ($right.Value -le 5) { return $null }
    if (-not (Test-IsInAssertion -Node $Node)) { return $null }

    $opSym = if ($op -eq [System.Management.Automation.Language.TokenKind]::Ige) { '-ge' } else { '-eq' }
    $msg = "Brittle assertion: ``.Count $opSym $($right.Value)`` couples the test to the exact data size. Assert on a property of the data instead, or use a relative bound."
    return (New-Finding -Rule 'PWSH-TEST-001' -File $RelativePath `
        -Line $Node.Extent.StartLineNumber -Column $Node.Extent.StartColumnNumber `
        -Message $msg)
}

function Test-Rule002 {
    # PWSH-TEST-002: order-dependent regex on multi-line cmdlet output.
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $pattern = $null
    $leftAst = $null

    if ($Node -is [System.Management.Automation.Language.BinaryExpressionAst]) {
        if ($Node.Operator -ne [System.Management.Automation.Language.TokenKind]::Imatch) { return $null }
        if ($Node.Right -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
        $pattern = $Node.Right.Value
        $leftAst = $Node.Left
    }
    elseif ($Node -is [System.Management.Automation.Language.CommandAst]) {
        if ($Node.GetCommandName() -ne 'Should') { return $null }
        # Look for `-Match` parameter followed by a string literal.
        $elements = @($Node.CommandElements)
        $matchPattern = $null
        for ($i = 0; $i -lt $elements.Count - 1; $i++) {
            $el = $elements[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                $el.ParameterName -eq 'Match') {
                $next = $elements[$i + 1]
                if ($next -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $matchPattern = $next.Value
                }
                break
            }
        }
        if (-not $matchPattern) { return $null }
        $pattern = $matchPattern
        # The piped-in expression for Should-Match is the parent PipelineAst's first element.
        $pipeline = $Node.Parent
        if ($pipeline -is [System.Management.Automation.Language.PipelineAst] -and
            $pipeline.PipelineElements.Count -ge 1) {
            $leftAst = $pipeline.PipelineElements[0]
        }
    }
    else { return $null }

    if (-not (Test-IsMultilineRegex -Pattern $pattern)) { return $null }
    if (-not $leftAst) { return $null }
    if (-not (Test-IsInAssertion -Node $Node)) { return $null }

    # Does the left expression descend from a multi-line cmdlet?
    $cmds = Get-CommandsInExpression -Ast $leftAst
    $multilineSources = @('Get-Content', 'Get-ChildItem', 'Get-Process')
    $matched = $false
    foreach ($c in $cmds) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        if ($multilineSources -contains $name) { $matched = $true; break }
        if ($name -like 'Format-*') { $matched = $true; break }
    }
    if (-not $matched) { return $null }

    $msg = "Order-dependent regex on multi-line output. Filter to the line of interest before matching, or assert structurally — the upstream cmdlet's line order is not a contract you should depend on."
    return (New-Finding -Rule 'PWSH-TEST-002' -File $RelativePath `
        -Line $Node.Extent.StartLineNumber -Column $Node.Extent.StartColumnNumber `
        -Message $msg)
}

function Find-PipelineSortUnique {
    param([Parameter(Mandatory)]$PipelineAst)
    if ($PipelineAst -isnot [System.Management.Automation.Language.PipelineAst]) { return $false }
    $elements = @($PipelineAst.PipelineElements)
    for ($i = 0; $i -lt $elements.Count - 1; $i++) {
        $a = $elements[$i]
        $b = $elements[$i + 1]
        if ($a -isnot [System.Management.Automation.Language.CommandAst]) { continue }
        if ($b -isnot [System.Management.Automation.Language.CommandAst]) { continue }
        if ($a.GetCommandName() -eq 'Sort-Object' -and $b.GetCommandName() -eq 'Get-Unique') {
            return $true
        }
    }
    return $false
}

function Test-Rule003 {
    # PWSH-TEST-003: `Sort-Object | Get-Unique` whose output is then ordered.
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$RelativePath
    )
    if (-not (Find-PipelineSortUnique -PipelineAst $Node)) { return $null }

    # Inline form: `(... | Sort-Object | Get-Unique)[0]` — the parent of the
    # ParenExpressionAst wrapping this pipeline is an IndexExpressionAst.
    $parent = $Node.Parent
    while ($parent -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $parent = $parent.Parent
    }
    $isInline = ($parent -is [System.Management.Automation.Language.IndexExpressionAst])

    $varName = $null
    $isAssigned = $false
    if (-not $isInline) {
        # Statement form: assignment to a variable.
        $statement = $Node.Parent
        while ($statement -and
               $statement -isnot [System.Management.Automation.Language.AssignmentStatementAst]) {
            $statement = $statement.Parent
        }
        if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst]) {
            $isAssigned = $true
            $target = $statement.Left
            if ($target -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $varName = $target.VariablePath.UserPath
            }
        }
    }

    $hasOrderedConsumer = $false
    if ($isInline) {
        $hasOrderedConsumer = $true
    }
    elseif ($varName) {
        # Search the enclosing script block for ordered uses of $varName.
        $scope = $Node.Parent
        while ($scope -and
               $scope -isnot [System.Management.Automation.Language.ScriptBlockAst]) {
            $scope = $scope.Parent
        }
        if ($scope) {
            $captured = $varName
            $predicate = {
                param($n)
                if ($n -is [System.Management.Automation.Language.IndexExpressionAst]) {
                    $t = $n.Target
                    if ($t -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $t.VariablePath.UserPath -eq $captured) {
                        return $true
                    }
                }
                if ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                    $n.Operator -eq [System.Management.Automation.Language.TokenKind]::Ieq) {
                    $r = $n.Right
                    if ($r -is [System.Management.Automation.Language.ArrayLiteralAst] -or
                        $r -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                        $l = $n.Left
                        if ($l -is [System.Management.Automation.Language.VariableExpressionAst] -and
                            $l.VariablePath.UserPath -eq $captured) {
                            return $true
                        }
                    }
                }
                if ($n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Select-Object') {
                    $hasOrderedFlag = $false
                    foreach ($el in $n.CommandElements) {
                        if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                            $el.ParameterName -in @('First', 'Last', 'Index')) {
                            $hasOrderedFlag = $true; break
                        }
                    }
                    if (-not $hasOrderedFlag) { return $false }
                    $pp = $n.Parent
                    if ($pp -is [System.Management.Automation.Language.PipelineAst]) {
                        foreach ($el in $pp.PipelineElements) {
                            if ($el -is [System.Management.Automation.Language.CommandExpressionAst]) {
                                $expr = $el.Expression
                                if ($expr -is [System.Management.Automation.Language.VariableExpressionAst] -and
                                    $expr.VariablePath.UserPath -eq $captured) {
                                    return $true
                                }
                            }
                        }
                    }
                }
                return $false
            }.GetNewClosure()
            $orderedUses = $scope.FindAll($predicate, $true)
            if (@($orderedUses).Count -gt 0) { $hasOrderedConsumer = $true }
        }
    }

    if (-not $hasOrderedConsumer) { return $null }
    # R3 fires when the brittle pipeline lives inside any test scriptblock —
    # the bug is the consumer's order assumption, but the pipeline itself
    # rarely sits inside the assertion call. Use the broader anchor.
    if (-not (Test-IsInTestBlock -Node $Node)) { return $null }

    $msg = "``Sort-Object | Get-Unique`` followed by an ordered comparison. The sort destroys the original order; the assertion now tests the sort, not the production code."
    return (New-Finding -Rule 'PWSH-TEST-003' -File $RelativePath `
        -Line $Node.Extent.StartLineNumber -Column $Node.Extent.StartColumnNumber `
        -Message $msg)
}

function Test-IsHashKeysAccess {
    # Returns $true if the Ast is `<expr>.Keys` (a member expression named Keys).
    param([Parameter(Mandatory)]$Ast)
    if ($Ast -isnot [System.Management.Automation.Language.MemberExpressionAst]) { return $false }
    $m = $Ast.Member
    if ($m -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $false }
    return $m.Value -eq 'Keys'
}

function Test-Rule004 {
    # PWSH-TEST-004: ordered/single-element access on a hashtable's `.Keys`.
    # Catches:
    #   ($h.Keys)[N]
    #   $h.Keys | Select-Object -First/-Last/-Index
    # Hashtable key enumeration order is unspecified.
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $matched = $false

    if ($Node -is [System.Management.Automation.Language.IndexExpressionAst]) {
        $target = $Node.Target
        # Unwrap (paren) and (single-element pipeline) layers to reach the underlying expression.
        while ($true) {
            if ($target -is [System.Management.Automation.Language.ParenExpressionAst]) {
                $target = $target.Pipeline
                continue
            }
            if ($target -is [System.Management.Automation.Language.PipelineAst] -and
                $target.PipelineElements.Count -eq 1) {
                $first = $target.PipelineElements[0]
                if ($first -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $target = $first.Expression
                    continue
                }
            }
            break
        }
        if (Test-IsHashKeysAccess -Ast $target) { $matched = $true }
    }
    elseif ($Node -is [System.Management.Automation.Language.PipelineAst]) {
        $elements = @($Node.PipelineElements)
        if ($elements.Count -ge 2) {
            # Look for `<.Keys-expr> | Select-Object -First/-Last/-Index`
            $first = $elements[0]
            $sourceIsKeys = $false
            if ($first -is [System.Management.Automation.Language.CommandExpressionAst]) {
                if (Test-IsHashKeysAccess -Ast $first.Expression) { $sourceIsKeys = $true }
            }
            if ($sourceIsKeys) {
                for ($i = 1; $i -lt $elements.Count; $i++) {
                    $el = $elements[$i]
                    if ($el -isnot [System.Management.Automation.Language.CommandAst]) { continue }
                    if ($el.GetCommandName() -ne 'Select-Object') { continue }
                    foreach ($cel in $el.CommandElements) {
                        if ($cel -is [System.Management.Automation.Language.CommandParameterAst] -and
                            $cel.ParameterName -in @('First', 'Last', 'Index')) {
                            $matched = $true; break
                        }
                    }
                    if ($matched) { break }
                }
            }
        }
    }
    else { return $null }

    if (-not $matched) { return $null }
    # R4 fires when the brittle access lives inside any test scriptblock —
    # the bug is the test's order assumption, even when the access is in
    # setup code that feeds a downstream assertion.
    if (-not (Test-IsInTestBlock -Node $Node)) { return $null }

    $msg = "Ordered access on a hashtable's ``.Keys`` (``[N]`` or ``Select-Object -First/-Last/-Index``). Hashtable key enumeration order is unspecified — the assertion may pass or fail without the production code changing."
    return (New-Finding -Rule 'PWSH-TEST-004' -File $RelativePath `
        -Line $Node.Extent.StartLineNumber -Column $Node.Extent.StartColumnNumber `
        -Message $msg)
}

function Test-Rule005 {
    # PWSH-TEST-005: Should -Match / -match on a regex literal with a literal `\\`.
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $pattern = $null
    if ($Node -is [System.Management.Automation.Language.BinaryExpressionAst]) {
        if ($Node.Operator -ne [System.Management.Automation.Language.TokenKind]::Imatch) { return $null }
        if ($Node.Right -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
        $pattern = $Node.Right.Value
    }
    elseif ($Node -is [System.Management.Automation.Language.CommandAst]) {
        if ($Node.GetCommandName() -ne 'Should') { return $null }
        $elements = @($Node.CommandElements)
        for ($i = 0; $i -lt $elements.Count - 1; $i++) {
            $el = $elements[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                $el.ParameterName -eq 'Match') {
                $next = $elements[$i + 1]
                if ($next -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $pattern = $next.Value
                }
                break
            }
        }
    }
    else { return $null }

    if (-not $pattern) { return $null }
    if (-not (Test-IsWindowsPathRegex -Pattern $pattern)) { return $null }
    if (-not (Test-IsInAssertion -Node $Node)) { return $null }

    $msg = "Windows-only path regex (literal ``\\`` and no forward slash). This assertion will fail on Linux/macOS CI. Use ``[IO.Path]::DirectorySeparatorChar`` or normalise the path before matching."
    return (New-Finding -Rule 'PWSH-TEST-005' -File $RelativePath `
        -Line $Node.Extent.StartLineNumber -Column $Node.Extent.StartColumnNumber `
        -Message $msg)
}

# --- Driver -----------------------------------------------------------------

function Get-RelativePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    try {
        $resolved = [IO.Path]::GetFullPath($Path)
        $rootResolved = [IO.Path]::GetFullPath($Root)
        if ($resolved.StartsWith($rootResolved, [StringComparison]::OrdinalIgnoreCase)) {
            $rel = $resolved.Substring($rootResolved.Length).TrimStart('\', '/')
            return $rel -replace '\\', '/'
        }
        return $Path -replace '\\', '/'
    } catch {
        return $Path -replace '\\', '/'
    }
}

function Invoke-FileScan {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    if (-not (Test-LooksLikeTestFile -FilePath $FilePath)) { return @() }

    $errs = $null
    $tokens = $null
    $ast = $null
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $FilePath, [ref]$tokens, [ref]$errs)
    } catch {
        Write-Warning "Test-Brittleness: parse failed on $FilePath - $($_.Exception.Message)"
        return @()
    }
    if (-not $ast) { return @() }
    # `ParseFile` can return a usable-looking AST even when it logged
    # non-terminating parse errors. Skip the file rather than risk
    # misleading findings from a partly-parsed tree.
    if ($errs -and @($errs).Count -gt 0) {
        Write-Warning "Test-Brittleness: $(@($errs).Count) parse error(s) in $FilePath - skipping"
        return @()
    }

    $rel = Get-RelativePath -Path $FilePath -Root $RepoRoot
    $findings = @()

    # One union-walk over the tree; per-rule check at each candidate node.
    $candidates = $ast.FindAll({
        param($n)
        return ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -or
                $n -is [System.Management.Automation.Language.PipelineAst] -or
                $n -is [System.Management.Automation.Language.ForEachStatementAst] -or
                $n -is [System.Management.Automation.Language.CommandAst] -or
                $n -is [System.Management.Automation.Language.IndexExpressionAst])
    }, $true)

    foreach ($n in $candidates) {
        try {
            $f = Test-Rule001 -Node $n -RelativePath $rel
            if ($f) { $findings += $f }
            $f = Test-Rule002 -Node $n -RelativePath $rel
            if ($f) { $findings += $f }
            $f = Test-Rule003 -Node $n -RelativePath $rel
            if ($f) { $findings += $f }
            $f = Test-Rule004 -Node $n -RelativePath $rel
            if ($f) { $findings += $f }
            $f = Test-Rule005 -Node $n -RelativePath $rel
            if ($f) { $findings += $f }
        } catch {
            Write-Warning "Test-Brittleness: rule eval failed on $rel`:$($n.Extent.StartLineNumber) - $($_.Exception.Message)"
        }
    }

    return $findings
}

function Resolve-FileList {
    param(
        [string[]]$Path,
        [switch]$All,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    if ($All) {
        return @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File `
            -Include '*.Tests.ps1', 'Test-*.ps1' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)
    }
    if (-not $Path) { return @() }
    $files = @()
    foreach ($p in $Path) {
        if (-not $p) { continue }
        if (-not [IO.Path]::IsPathRooted($p)) {
            $p = Join-Path $RepoRoot $p
        }
        if (Test-Path -LiteralPath $p -PathType Container) {
            $files += Get-ChildItem -LiteralPath $p -Recurse -File `
                -Include '*.Tests.ps1', 'Test-*.ps1' -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName
        }
        elseif (Test-Path -LiteralPath $p -PathType Leaf) {
            $files += $p
        }
    }
    return $files
}

# --- Entry ------------------------------------------------------------------

Push-Location $RepoRoot
try {
    $files = Resolve-FileList -Path $Path -All:$All -RepoRoot $RepoRoot
    $allFindings = @()
    foreach ($f in $files) {
        $allFindings += Invoke-FileScan -FilePath $f -RepoRoot $RepoRoot
    }
    , $allFindings
} finally {
    Pop-Location
}
