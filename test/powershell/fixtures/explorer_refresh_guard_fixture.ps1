#Requires -Version 5.1
param([Parameter(Mandatory=$true)][ValidateSet('OldOnly','Both')][string]$Case)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$library=Join-Path $root 'modules/explorer/explorer_settings_library.ps1'
$fake='using System; public static class WindowsSetupExplorerRefresh { public static int Calls; public static bool Valid=true; public static void SHChangeNotify(int e,uint f,IntPtr a,IntPtr b){Calls++;Valid=Valid && e==0x08000000 && f==0 && a==IntPtr.Zero && b==IntPtr.Zero;} }'
Microsoft.PowerShell.Utility\Add-Type -TypeDefinition 'public static class NucExplorerRefresh {}'
if($Case -eq 'Both'){Microsoft.PowerShell.Utility\Add-Type -TypeDefinition $fake}
$script:loads=0
function Add-Type {
 param([string]$TypeDefinition)
 $script:loads++
 if($Case -ne 'OldOnly' -or $script:loads -ne 1 -or $TypeDefinition -notmatch 'public\s+static\s+class\s+WindowsSetupExplorerRefresh\b'){throw 'unexpected managed load'}
 Microsoft.PowerShell.Utility\Add-Type -TypeDefinition $fake
}
. $library
Invoke-SetupExplorerNotification
Invoke-SetupExplorerNotification
$expected=if($Case -eq 'OldOnly'){1}else{0}
if($script:loads -ne $expected -or [WindowsSetupExplorerRefresh]::Calls -ne 2 -or -not [WindowsSetupExplorerRefresh]::Valid){throw 'incorrect refresh guard or arguments'}
$source=[IO.File]::ReadAllText($library)
if($source -notmatch '\[DllImport\("shell32\.dll"\)\]public static extern void SHChangeNotify\(int e,uint f,IntPtr a,IntPtr b\);' -or $source -notmatch '\[WindowsSetupExplorerRefresh\]::SHChangeNotify\(0x08000000,0,\[IntPtr\]::Zero,\[IntPtr\]::Zero\)'){throw 'native refresh declaration or arguments changed'}
Write-Host ('@@ASSERT@@'+(@{Name=('Explorer refresh '+$Case);Passed=$true}|ConvertTo-Json -Compress))
