@{
    IncludeRules = @('PSUseConsistentIndentation', 'PSUseConsistentWhitespace')
    Rules = @{
        PSUseConsistentIndentation = @{ Enable = $true; Kind = 'space'; IndentationSize = 4 }
        PSUseConsistentWhitespace = @{ Enable = $true; CheckInnerBrace = $true; CheckOpenBrace = $true; CheckOpenParen = $true; CheckOperator = $true; CheckPipe = $true; CheckSeparator = $true }
    }
}