@{
    # PSScriptAnalyzer settings for pwsh-code-review-marketplace itself.
    # Curated from templates/PSScriptAnalyzerSettings.psd1, trimmed for the
    # actual CI surface (Windows + Linux on Core 7.4; macOS not gated).

    Severity     = @('Error', 'Warning', 'Information')

    IncludeRules = @('*')

    ExcludeRules = @(
        # Top-level scripts and pipeline composers legitimately use Write-Host
        # (Tests-*/Run.ps1 test runners; the agent banner). The conventions
        # agent enforces the deeper rule via standards.md / Output discipline.
        'PSAvoidUsingWriteHost'

        # The plugin ships no exported functions in a manifest -- the
        # marketplace contract is via slash commands and rule namespaces.
        'PSUseToExportFieldsInManifest'

        # Most scripts are top-level entry points, not state-changing
        # cmdlets. SupportsShouldProcess is project-context-dependent and
        # owned by the conventions agent.
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Rules = @{
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }

        PSPlaceCloseBrace = @{
            Enable             = $true
            NoEmptyLineBefore  = $false
            IgnoreOneLineBlock = $true
            NewLineAfter       = $true
        }

        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }

        PSUseConsistentWhitespace = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            CheckParameter                          = $false
            IgnoreAssignmentOperatorInsideHashTable = $true
        }

        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }

        PSAvoidLongLines = @{
            Enable            = $true
            MaximumLineLength = 140
        }

        PSAvoidSemicolonsAsLineTerminators = @{
            Enable = $true
        }

        # Compatibility: target pwsh 7.4 across Windows + Linux. macOS is
        # expected to work but is not gated in CI.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.4')
        }

        PSUseCompatibleCmdlets = @{
            Enable        = $true
            compatibility = @(
                'core-7.4-windows',
                'core-7.4-linux'
            )
        }

        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @(
                'core-7.4-windows-framework',
                'core-7.4-linux'
            )
        }

        PSUseCompatibleTypes = @{
            Enable         = $true
            TargetProfiles = @(
                'core-7.4-windows-framework',
                'core-7.4-linux'
            )
        }
    }
}
