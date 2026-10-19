# Managed by coding-standards (scripts/sync-standards.sh). Do not edit in projects; change it upstream.
# PowerShell standard: OTBS braces, 4-space indent, consistent whitespace, 115-column lines.
@{
    IncludeDefaultRules = $true
    Severity            = @('Error', 'Warning', 'Information')
    Rules               = @{
        PSPlaceOpenBrace                            = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace                           = @{
            Enable             = $true
            NewLineAfter       = $false
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
        PSUseConsistentIndentation                  = @{
            Enable              = $true
            IndentationSize     = 4
            Kind                = 'space'
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }
        PSUseConsistentWhitespace                   = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckSeparator                          = $true
            CheckParameter                          = $true
            IgnoreAssignmentOperatorInsideHashTable = $true # allow aligned splats
        }
        PSAlignAssignmentStatement                  = @{
            Enable         = $true
            CheckHashtable = $true
        }
        PSAvoidLongLines                            = @{
            Enable            = $true
            MaximumLineLength = 115
        }
        PSAvoidSemicolonsAsLineTerminators          = @{ Enable = $true }
        PSUseCorrectCasing                          = @{ Enable = $true }
        PSAvoidUsingCmdletAliases                   = @{ Enable = $true }
        PSAvoidUsingPositionalParameters            = @{ Enable = $true }
        PSAvoidUsingInvokeExpression                = @{ Enable = $true }
        PSAvoidUsingWriteHost                       = @{ Enable = $true }
        PSUseShouldProcessForStateChangingFunctions = @{ Enable = $true }
        PSUseApprovedVerbs                          = @{ Enable = $true }
        PSUseSingularNouns                          = @{ Enable = $true }
    }
}
