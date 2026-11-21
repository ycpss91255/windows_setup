#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$originalConsoleEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$wrapper = Join-Path $repo 'script/test/clean_test_artifacts.ps1'
if (-not [IO.File]::Exists($wrapper)) { throw 'SPEC MISSING: PowerShell cleanup entry point' }
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = Join-Path $temp ('windows_setup_wrapper_test_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$root = Join-Path $fixture 'owned root'
$ps = (Get-Process -Id $PID).Path
function Assert([bool]$Value, [string]$Name) { Write-Host ('@@ASSERT@@' + (@{Name=$Name;Passed=$Value} | ConvertTo-Json -Compress)); if (-not $Value) { throw $Name } }
function Invoke-Wrapper([string[]]$Arguments, [int]$Expected) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = @(& $ps -NoProfile -ExecutionPolicy Bypass -File $wrapper @Arguments 2>&1); $actual = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    if (($Expected -eq 0 -and $actual -ne 0) -or ($Expected -ne 0 -and $actual -eq 0)) { throw "Unexpected exit code: $actual; $($output -join ' ')" }
    return ($output -join "`n")
}
Push-Location $fixture
try {
    [void](Invoke-Wrapper @('init', $root) 0)
    [void](Invoke-Wrapper @('create', $root, 'item') 0)
    $payload = Join-Path $root 'item/payload'
    [IO.File]::WriteAllText($payload, 'owned fixture')
    [void](Invoke-Wrapper @('finish', $root, 'item', '2000-01-01T00:00:00Z') 0)
    $preview = Invoke-Wrapper @('clean', $root, 'item') 0
    Assert (($preview -match ([string][char]0x5019 + [char]0x9078)) -and [IO.File]::Exists($payload)) 'Preview identifies candidate and retains data'
    [void](Invoke-Wrapper @('clean', $root, 'item', '--invalid') 1)
    Assert ([IO.File]::Exists($payload)) 'Invalid option retains data'
    [void](Invoke-Wrapper @('clean', $root, 'item', '--delete') 0)
    Assert (-not [IO.Directory]::Exists((Join-Path $root 'item'))) 'Explicit deletion removes item'
    $savedPath = $env:PATH
    try { $env:PATH = $fixture; [void](Invoke-Wrapper @('clean', $root, 'item') 1) } finally { $env:PATH = $savedPath }
    Assert $true 'Missing Go exits nonzero'
    Write-Output 'PASS: PS5 wrapper, preview, options and owned data'
} finally { Pop-Location; [Console]::OutputEncoding = $originalConsoleEncoding }
