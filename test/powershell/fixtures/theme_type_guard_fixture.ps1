#Requires -Version 5.1
param([Parameter(Mandatory=$true)][ValidateSet('OldOnly','Both')][string]$Mode)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$module=Join-Path $repo 'modules/theme'
$library=Join-Path $module 'theme_settings_library.ps1'
$native=Join-Path $module 'native/theme.cs'
$fake='using System;using System.Text;public static class WindowsSetupTheme{public sealed class TaskbarSample{public int[] RGB=new int[]{0,0,0};public bool AutoHidden=false;}public static int Observations,WallpaperReads,ColorReads;public static TaskbarSample ObserveTaskbar(){Observations++;return new TaskbarSample();}public static bool ReadWallpaper(uint a,uint b,StringBuilder c,uint d){WallpaperReads++;return true;}public static uint GetSysColor(int n){ColorReads++;return 0;}}'
Microsoft.PowerShell.Utility\Add-Type -TypeDefinition 'public static class NUC8Theme{}'
if($Mode -eq 'Both'){Microsoft.PowerShell.Utility\Add-Type -TypeDefinition $fake}
. $library
$script:compiles=0
function Add-Type {param($Path) $script:compiles++;if($Mode -eq 'Both'){throw 'already loaded type must not compile again'};if($Path -cne $native){throw "unexpected source path: $Path"};Microsoft.PowerShell.Utility\Add-Type -TypeDefinition $fake}
function Get-ItemProperty {param($Path) if($Path -cne 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'){throw 'unexpected registry read'};[pscustomobject]@{AppsUseLightTheme=0;SystemUsesLightTheme=0}}
function Test-Path {throw 'unexpected Test-Path'}
function New-Item {throw 'unexpected New-Item'}
function New-ItemProperty {throw 'unexpected New-ItemProperty'}
function Set-ItemProperty {throw 'unexpected Set-ItemProperty'}
function Get-Process {throw 'unexpected Get-Process'}
function Stop-Process {throw 'unexpected Stop-Process'}
function Start-Process {throw 'unexpected Start-Process'}
function Start-Sleep {throw 'unexpected Start-Sleep'}
for($i=0;$i -lt 2;$i++){ $r=Invoke-SetupThemeSettings -ModuleRoot $module -VerifyOnly;if(-not $r.Success){throw 'fake verification failed'} }
$expected=if($Mode -eq 'OldOnly'){1}else{0}
if($script:compiles -ne $expected){throw "wrong compile count: $script:compiles expected $expected"}
if([WindowsSetupTheme]::Observations -ne 2 -or [WindowsSetupTheme]::WallpaperReads -ne 2 -or [WindowsSetupTheme]::ColorReads -ne 2){throw 'new fake was not used twice for each observation'}
$cs=[IO.File]::ReadAllText($native);$ps=[IO.File]::ReadAllText($library)
if($cs -notmatch 'public\s+static\s+class\s+WindowsSetupTheme\b' -or $cs -match '\bNUC8Theme\b' -or $ps -match '\bNUC8Theme\b'){throw 'Theme source still has old type name or lacks new declaration'}
Write-Host ('@@ASSERT@@'+(@{Name=('Theme type guard '+$Mode);Passed=$true}|ConvertTo-Json -Compress))
