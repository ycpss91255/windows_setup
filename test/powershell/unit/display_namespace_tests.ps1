#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
$source=[IO.File]::ReadAllText((Join-Path $root 'modules/display/native/display.cs'))
Assert ($source -match '(?m)^namespace\s+WindowsSetupDisplay\s*\{') 'native source uses neutral display namespace'
Assert ($source -notmatch '\bNUC8Display\b') 'native source no longer defines old namespace'
$library=Join-Path $root 'modules/display/display_settings_library.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($library,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'display library parses'
$text=[IO.File]::ReadAllText($library)
Assert ($text.Contains("'WindowsSetupDisplay.Display' -as [type]") -and $text -notmatch '\bNUC8Display\b') 'display guard and callers use neutral type'
$fixture=Join-Path $env:TEMP ('display_namespace_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
$runner=Join-Path $fixture 'runner.ps1'
$script=@'
param($Library,$Case)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition 'namespace NUC8Display { public static class Display { public static uint[] ReadSnapshot(){ throw new System.Exception("old type used"); } } }'
if($Case -eq 'new_loaded'){Add-Type -TypeDefinition 'namespace WindowsSetupDisplay { public static class Display { public static uint[] ReadSnapshot(){return new uint[]{1920,1080,100};} } }'}
function Add-Type {param($Path) if($Case -ne 'old_only'){throw 'unexpected recompilation'};Microsoft.PowerShell.Utility\Add-Type -TypeDefinition 'namespace WindowsSetupDisplay { public static class Display { public static uint[] ReadSnapshot(){return new uint[]{1920,1080,100};} } }';$script:compiled++}
function Get-ItemProperty {param($Path,$ErrorAction) [pscustomobject]@{Win8DpiScaling=0}}
function Set-ItemProperty {throw 'fixture blocks registry writes'}
function New-ItemProperty {throw 'fixture blocks registry writes'}
function Remove-ItemProperty {throw 'fixture blocks registry writes'}
function Start-Process {throw 'fixture blocks process launch'}
$script:compiled=0
. $Library
$result=Invoke-SetupDisplaySettings -ModuleRoot $env:TEMP -VerifyOnly
if(-not $result.Success -or $script:compiled -ne $(if($Case -eq 'old_only'){1}else{0})){throw 'wrong managed guard or snapshot'}
'@
[IO.File]::WriteAllText($runner,$script,(New-Object Text.UTF8Encoding($true)))
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach($case in @('old_only','new_loaded')){
 $output=Join-Path $fixture ($case+'.log');$prior=$ErrorActionPreference;$ErrorActionPreference='Continue'
 try{& $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -Library $library -Case $case *> $output;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$prior}
 Assert ($code -eq 0) ('fixed managed fixture selects neutral type '+$case)
}
