#Requires -Version 5.1
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ToolArgs)
$ErrorActionPreference = 'Stop'
$go = Get-Command go.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $go) { [Console]::Error.WriteLine('Go executable not found; install Go 1.27.3 for this maintenance tool.'); exit 1 }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Push-Location -LiteralPath $repo
try {
    & $go.Source run ./script/test/clean_test_artifacts @ToolArgs
    $code = $LASTEXITCODE
} finally { Pop-Location }
exit $code
