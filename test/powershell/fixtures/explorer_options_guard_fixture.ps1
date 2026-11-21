#Requires -Version 5.1
param([Parameter(Mandatory=$true)][ValidateSet('OldOnly','Both')][string]$Mode)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$module=Join-Path $root 'modules/explorer'
$library=Join-Path $module 'explorer_settings_library.ps1'
$native=Join-Path $module 'native/explorer.cs'
$fake='public static class WindowsSetupExplorerOptions{public static int Calls;public static string Args="";public static uint Options(bool apply){Calls++;Args+=apply?"T":"F";return 3;}}'
Microsoft.PowerShell.Utility\Add-Type -TypeDefinition 'public static class NucExplorerLiveV2{}'
if($Mode -eq 'Both'){Microsoft.PowerShell.Utility\Add-Type -TypeDefinition $fake}
. $library
$script:compiles=0
function Add-Type {
 param($Path,$TypeDefinition)
 $script:compiles++
 if($Mode -eq 'Both' -or $Path -cne $native -or $TypeDefinition){throw 'unexpected native compilation'}
 Microsoft.PowerShell.Utility\Add-Type -TypeDefinition $fake
}
function Test-Path {throw 'unexpected Test-Path'}
function New-Item {throw 'unexpected New-Item'}
function Get-ItemProperty {throw 'unexpected Get-ItemProperty'}
function Set-ItemProperty {throw 'unexpected Set-ItemProperty'}
function New-Object {throw 'unexpected New-Object'}
function Get-Process {throw 'unexpected Get-Process'}
function Stop-Process {throw 'unexpected Stop-Process'}
function Start-Process {throw 'unexpected Start-Process'}
function Get-Service {throw 'unexpected Get-Service'}
function Start-Service {throw 'unexpected Start-Service'}
function Stop-Service {throw 'unexpected Stop-Service'}
$a=Get-SetupExplorerShellOptions -ModuleRoot $module
$b=Get-SetupExplorerShellOptions -ModuleRoot $module -Apply
$expected=if($Mode -eq 'OldOnly'){1}else{0}
if($a -ne 3 -or $b -ne 3 -or $script:compiles -ne $expected){throw 'wrong fake result or compilation count'}
if([WindowsSetupExplorerOptions]::Calls -ne 2 -or [WindowsSetupExplorerOptions]::Args -cne 'FT'){throw 'new fake did not receive read and apply in order'}
$cs=[IO.File]::ReadAllText($native);$ps=[IO.File]::ReadAllText($library)
if($cs -notmatch 'public\s+static\s+class\s+WindowsSetupExplorerOptions\b' -or $cs -match '\bNucExplorerLiveV2\b' -or $ps -match '\bNucExplorerLiveV2\b'){throw 'Explorer options source has old type name or lacks new declaration'}
Write-Host ('@@ASSERT@@'+(@{Name=('Explorer options guard '+$Mode);Passed=$true}|ConvertTo-Json -Compress))
