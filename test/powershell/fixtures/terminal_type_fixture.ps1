#Requires -Version 5.1
param([Parameter(Mandatory=$true)][ValidateSet('OldOnly','Both')][string]$Mode)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$module=Join-Path $root 'modules/terminal'
$library=Join-Path $module 'terminal_hotkey_library.ps1'
$native=Join-Path $module 'native/terminal_hotkey.cs'
$fake='public static class WindowsSetupTerminalHotkey{public static int Calls;public static string First,Second;public static void Run(string terminal,string log,string home){Calls++;string value=terminal+"|"+log+"|"+home;if(Calls==1)First=value;else if(Calls==2)Second=value;else throw new System.Exception("unexpected call");}}'
Microsoft.PowerShell.Utility\Add-Type -TypeDefinition 'public static class NucTerminalHotkey{}'
if($Mode -eq 'Both'){Microsoft.PowerShell.Utility\Add-Type -TypeDefinition $fake}
. $library
$script:loads=0
function Add-Type {
 param($Path,$TypeDefinition)
 if($Path -cne $native -or $TypeDefinition){throw 'unexpected native compilation'}
 $script:loads++
 if($script:loads -gt 2){throw 'unexpected extra native load'}
 if($Mode -eq 'OldOnly' -and $script:loads -eq 1){Microsoft.PowerShell.Utility\Add-Type -TypeDefinition $fake}
}
function New-Object {throw 'unexpected New-Object'}
function Test-Path {throw 'unexpected Test-Path'}
function New-Item {throw 'unexpected New-Item'}
function Get-ItemProperty {throw 'unexpected Get-ItemProperty'}
function Set-ItemProperty {throw 'unexpected Set-ItemProperty'}
function Get-Process {throw 'unexpected Get-Process'}
function Stop-Process {throw 'unexpected Stop-Process'}
function Start-Process {throw 'unexpected Start-Process'}
function Get-Service {throw 'unexpected Get-Service'}
function Start-Service {throw 'unexpected Start-Service'}
function Stop-Service {throw 'unexpected Stop-Service'}
function Get-CimInstance {throw 'unexpected Get-CimInstance'}
function Invoke-CimMethod {throw 'unexpected Invoke-CimMethod'}
function Register-ScheduledTask {throw 'unexpected Register-ScheduledTask'}
function Start-ScheduledTask {throw 'unexpected Start-ScheduledTask'}
Invoke-SetupTerminalNative -ModuleRoot $module -Terminal 'fake-terminal-1' -LogPath 'fake-log-1' -UserHome 'fake-home-1'
Invoke-SetupTerminalNative -ModuleRoot $module -Terminal 'fake-terminal-2' -LogPath 'fake-log-2' -UserHome 'fake-home-2'
if($script:loads -ne 2){throw 'native source load was not requested on each invocation'}
if([WindowsSetupTerminalHotkey]::Calls -ne 2 -or [WindowsSetupTerminalHotkey]::First -cne 'fake-terminal-1|fake-log-1|fake-home-1' -or [WindowsSetupTerminalHotkey]::Second -cne 'fake-terminal-2|fake-log-2|fake-home-2'){throw 'new fake did not receive expected arguments'}
$cs=[IO.File]::ReadAllText($native);$ps=[IO.File]::ReadAllText($library)
if($cs -notmatch 'public\s+static\s+class\s+WindowsSetupTerminalHotkey\b' -or $cs -match '\bNucTerminalHotkey\b' -or $ps -match '\[NucTerminalHotkey\]'){throw 'Terminal source has old CLR name or lacks new declaration'}
Write-Host ('@@ASSERT@@'+(@{Name=('Terminal type '+$Mode);Passed=$true}|ConvertTo-Json -Compress))
