@{
    # PSScriptAnalyzer settings for pwsh-code-review.
    # This is the template installed during /pwsh-review-bootstrap.
    # Project-specific overrides go in this file directly; the plugin
    # never modifies it once placed in .pwsh-review/.

    Severity     = @('Error', 'Warning', 'Information')

    IncludeRules = @('*')

    ExcludeRules = @(
        # Strongly opinionated rules that often misfire on legitimate code.
        # Remove an exclude here if you want the rule enforced.

        'PSUseShouldProcessForStateChangingFunctions'
        # Often false-positives on internal helpers. Re-enable for public modules.

        'PSAvoidUsingWriteHost'
        # OK for CLI tooling and interactive scripts. Re-enable for libraries.

        'PSUseToExportFieldsInManifest'
        # We check this in the conventions agent with project context.
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

        # Compatibility: target pwsh 7.4+ across the three desktop platforms.
        # Adjust TargetVersions / TargetProfiles for your project.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.4')
        }

        PSUseCompatibleCmdlets = @{
            Enable        = $true
            compatibility = @(
                'core-7.4-windows',
                'core-7.4-linux',
                'core-7.4-macos'
            )
        }

        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @(
                'core-7.4-windows-framework',
                'core-7.4-linux',
                'core-7.4-macos'
            )
        }

        PSUseCompatibleTypes = @{
            Enable         = $true
            TargetProfiles = @(
                'core-7.4-windows-framework',
                'core-7.4-linux',
                'core-7.4-macos'
            )
        }
    }
}
