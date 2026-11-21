#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Name}}
$library=Join-Path $root 'modules/desktop/icons_settings_library.ps1'
Assert (Test-Path -LiteralPath $library) 'Icons native algorithm has a named original-source leaf'
. $library
function Get-SetupSystemIconNames {@('控制台','本機','網路','資源回收筒')}
Add-Type -TypeDefinition 'using System;using System.Collections.Generic;namespace WindowsSetupIcons{public static class Desktop{public static Queue<object> Frames=new Queue<object>();public static int Moves;public static object Capture(){return Frames.Dequeue();}public static void Position(int i,int x,int y){Moves++;}}}'
function Frame($names=@('控制台','本機','網路','資源回收筒'),$offset=0){$i=0;[pscustomobject]@{Width=1920;Height=1080;Icons=@(foreach($n in $names){[pscustomobject]@{Name=$n;Index=$i;X=($i*100+$offset);Y=10};$i++})}}
$reference=Frame
function Get-ItemProperty {param($Path,$ErrorAction) [pscustomobject]@{FFlags=3}}
$script:flags=-1
function Set-ItemProperty {param($Path,$Name,$Value) if($Name -ne 'FFlags'){throw 'unexpected icons registry write'};$script:flags=$Value}
function Start-Sleep {param($Milliseconds) if($Milliseconds -ne 500){throw 'unexpected icons wait'}}
[WindowsSetupIcons.Desktop]::Frames.Enqueue((Frame));[WindowsSetupIcons.Desktop]::Frames.Enqueue((Frame -offset 2))
$r=Invoke-SetupIconsSettings -ModuleRoot (Join-Path $root 'modules/desktop') -Mode Load -Reference $reference
Assert ($r.Success -and [WindowsSetupIcons.Desktop]::Moves -eq 4 -and $script:flags -eq 2) 'Icons retains four native positions, disables auto-arrange, and accepts two-pixel tolerance'
[WindowsSetupIcons.Desktop]::Frames.Enqueue((Frame));[WindowsSetupIcons.Desktop]::Frames.Enqueue((Frame -offset 3))
$r=Invoke-SetupIconsSettings -ModuleRoot (Join-Path $root 'modules/desktop') -Mode Verify -Reference $reference
Assert (-not $r.Success -and $r.Differences.Count -eq 4) 'Icons Verify rejects three-pixel mismatch without moving icons'
[WindowsSetupIcons.Desktop]::Frames.Enqueue((Frame));$bad=Frame;$bad.Width=1280;$errorText=''
try{Invoke-SetupIconsSettings -ModuleRoot (Join-Path $root 'modules/desktop') -Mode Load -Reference $bad|Out-Null}catch{$errorText=$_.Exception.Message}
Assert ($errorText.Contains('桌面範圍與範本不同') -and [WindowsSetupIcons.Desktop]::Moves -eq 4) 'Icons refuses mismatched desktop dimensions before Position'
foreach($names in @(@('控制台','本機','網路'),@('控制台','本機','網路','網路'),@('控制台','本機','網路','資源回收筒','extra'))){
 [WindowsSetupIcons.Desktop]::Frames.Enqueue((Frame));[WindowsSetupIcons.Desktop]::Frames.Enqueue((Frame -names $names))
 $r=Invoke-SetupIconsSettings -ModuleRoot (Join-Path $root 'modules/desktop') -Mode Load -Reference $reference
 Assert (-not $r.Success -and $r.Error) ('after Capture refuses missing duplicate or extra icons: '+($names -join ','))
}
[WindowsSetupIcons.Desktop]::Frames.Enqueue((Frame -names @('a','b','c','d')));$failure=''
try{Invoke-SetupIconsSettings -ModuleRoot (Join-Path $root 'modules/desktop') -Mode Save|Out-Null}catch{$failure=$_.Exception.Message}
Assert (-not [string]::IsNullOrWhiteSpace($failure)) 'Save refuses four arbitrary icons instead of the four system CLSIDs'
[WindowsSetupIcons.Desktop]::Frames.Enqueue((Frame))
$r=Invoke-SetupIconsSettings -ModuleRoot (Join-Path $root 'modules/desktop') -Mode Save
Assert ($r.Success -and @($r.Reference.Icons).Count -eq 4 -and $r.Reference.Width -eq 1920) 'Save returns the validated reference without writing mutable staged input'
$wrong=Frame -names @('a','b','c','d');[WindowsSetupIcons.Desktop]::Frames.Enqueue($wrong);[WindowsSetupIcons.Desktop]::Frames.Enqueue($wrong);$failure=''
try{Invoke-SetupIconsSettings -ModuleRoot (Join-Path $root 'modules/desktop') -Mode Load -Reference $wrong|Out-Null}catch{$failure=$_.Exception.Message}
Assert (-not [string]::IsNullOrWhiteSpace($failure)) 'Load refuses a template with four arbitrary non-system names before native Position'
[WindowsSetupIcons.Desktop]::Frames.Clear();[WindowsSetupIcons.Desktop]::Frames.Enqueue((Frame -names @('控制台','本機','網路','資源回收筒','extra')));[WindowsSetupIcons.Desktop]::Frames.Enqueue((Frame));$failure='';$beforeMoves=[WindowsSetupIcons.Desktop]::Moves
try{Invoke-SetupIconsSettings -ModuleRoot (Join-Path $root 'modules/desktop') -Mode Load -Reference $reference|Out-Null}catch{$failure=$_.Exception.Message}
Assert (-not [string]::IsNullOrWhiteSpace($failure) -and [WindowsSetupIcons.Desktop]::Moves -eq $beforeMoves) 'initial Capture with extra icon is refused before native Position even if after frame has four'