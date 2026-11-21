#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Name}}
function Reject([scriptblock]$Action,[string]$Expected,[string]$Name){$errorText='';try{& $Action|Out-Null}catch{$errorText=$_.Exception.Message};Assert ($errorText.Contains($Expected)) ($Name+'; actual='+$errorText)}
$library=Join-Path $root 'modules/theme/theme_settings_library.ps1'
Assert (Test-Path -LiteralPath $library) 'Theme has a named original-source leaf without importing the elevated public entry'
. $library
Add-Type -TypeDefinition 'using System;using System.Text;public static class WindowsSetupTheme{public sealed class TaskbarSample{public int[] RGB;public bool AutoHidden;}public static bool AutoHidden;public static TaskbarSample ObserveTaskbar(){return new TaskbarSample{RGB=AutoHidden?new int[0]:TaskbarColor(),AutoHidden=AutoHidden};}public static bool ColorOk=true,WallpaperOk=true,ReadOk=true;public static uint Color;public static string Wallpaper="";public static int SetColorCalls,SetWallpaperCalls,NotifyCalls,Reads,LightReads;public static bool SetSysColors(int count,int[] elements,uint[] colors){SetColorCalls++;if(count!=1||elements[0]!=1||colors[0]!=0)throw new Exception("wrong colors");return ColorOk;}public static bool SystemParametersInfo(uint action,uint param,string value,uint flags){SetWallpaperCalls++;if(action!=20||param!=0||value!=""||flags!=3)throw new Exception("wrong wallpaper");if(WallpaperOk)Wallpaper="";return WallpaperOk;}public static IntPtr SendMessageTimeout(IntPtr hwnd,uint msg,IntPtr wp,string lp,uint flags,uint timeout,out IntPtr result){NotifyCalls++;result=IntPtr.Zero;return IntPtr.Zero;}public static int[] TaskbarColor(){Reads++;if(LightReads>0){LightReads--;return new int[]{240,240,240};}return new int[]{21,21,21};}public static bool ReadWallpaper(uint action,uint param,StringBuilder value,uint flags){if(ReadOk)value.Append(Wallpaper);return ReadOk;}public static uint GetSysColor(int index){return Color;}}'
$personalize='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$wallpapers='HKCU:\Software\Microsoft\Windows\CurrentVersion\explorer\Wallpapers';$cloud='HKCU:\Software\Policies\Microsoft\Windows\CloudContent'
$script:keys=@{};$script:values=@{AppsUseLightTheme=0;SystemUsesLightTheme=0};$script:writes=@();$script:created=@();$script:stopped=@();$script:started=0;$script:startedPaths=@()
$session=[Diagnostics.Process]::GetCurrentProcess().SessionId
$script:processes=@([pscustomobject]@{SessionId=$session;Name='current'},[pscustomobject]@{SessionId=($session+10);Name='other'})
function Test-Path {param($Path) if($Path -notin @($personalize,$wallpapers,$cloud)){throw 'unexpected theme registry path'};$script:keys.ContainsKey($Path)}
function New-Item {param($Path,[switch]$Force) $script:keys[$Path]=$true;$script:created+=@($Path)}
function New-ItemProperty {param($Path,$Name,$Value,$PropertyType,[switch]$Force) if($Path -notin @($personalize,$wallpapers,$cloud) -or $PropertyType -ne 'DWord' -or -not $Force){throw 'unexpected theme preference'};$script:values[$Name]=$Value;$script:writes+=@($Path+'|'+$Name+'|'+$Value)}
function Set-ItemProperty {param($Path,$Name,$Value) if(($Path -ne 'HKCU:\Control Panel\Colors' -or $Name -ne 'Background' -or $Value -ne '0 0 0') -and ($Path -ne 'HKCU:\Control Panel\Desktop' -or $Name -ne 'Wallpaper' -or $Value -ne '')){throw 'unexpected theme registry write'};$script:writes+=@($Path+'|'+$Name+'|'+$Value)}
function Get-ItemProperty {param($Path) if($Path -ne $personalize){throw 'unexpected theme verification read'};[pscustomobject]$script:values}
function Get-Process {param($Name,$ErrorAction) if($Name -ne 'explorer'){throw 'unexpected process lookup'};$script:processes}
function Stop-Process {param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$Force) process{if(-not $Force -or $InputObject.SessionId -ne $session){throw 'unsafe theme Explorer stop'};$script:stopped+=@($InputObject.Name);$script:processes=@($script:processes|Where-Object SessionId -ne $session)}}
function Start-Process {param($FilePath) if($FilePath -notin @('explorer.exe',$actualExplorer)){throw 'unexpected theme process'};$script:startedPaths+=@($FilePath);$script:started++}
function Start-Sleep {param($Seconds,$Milliseconds)}
$module=Join-Path $root 'modules/theme'
$r=Invoke-SetupThemeSettings -ModuleRoot $module -VerifyOnly
Assert ($r.Success -and $r.AppsMode -ceq 'Dark' -and $r.WindowsMode -ceq 'Dark' -and $r.Background -ceq '#000000' -and $r.TaskbarIsDark -and $r.ActualWallpaper -ceq '' -and $r.ActualBackgroundColor -eq 0) 'Theme VerifyOnly reads actual black background and dark shell/application modes'
Assert ($script:writes.Count -eq 0 -and $script:created.Count -eq 0 -and [WindowsSetupTheme]::SetColorCalls -eq 0 -and [WindowsSetupTheme]::SetWallpaperCalls -eq 0 -and $script:stopped.Count -eq 0 -and $script:started -eq 0) 'Theme VerifyOnly performs no preference mutation native apply or Explorer reload'
$script:values.AppsUseLightTheme=1;Reject {Invoke-SetupThemeSettings -ModuleRoot $module -VerifyOnly} '即時驗證' 'light application preference cannot pass';$script:values.AppsUseLightTheme=0
[WindowsSetupTheme]::Color=1;Reject {Invoke-SetupThemeSettings -ModuleRoot $module -VerifyOnly} '即時驗證' 'nonblack actual native background cannot pass';[WindowsSetupTheme]::Color=0
[WindowsSetupTheme]::Wallpaper='still present';Reject {Invoke-SetupThemeSettings -ModuleRoot $module -VerifyOnly} '即時驗證' 'remaining actual wallpaper cannot pass';[WindowsSetupTheme]::Wallpaper=''
[WindowsSetupTheme]::LightReads=1;Reject {Invoke-SetupThemeSettings -ModuleRoot $module -VerifyOnly} '即時驗證' 'light actual taskbar fails VerifyOnly without reapplying';Assert ($script:stopped.Count -eq 0) 'failed VerifyOnly does not stop Explorer'
$r=Invoke-SetupThemeSettings -ModuleRoot $module
Assert ($r.Success -and -not $r.ExplorerReloaded -and $script:writes.Count -eq 6 -and $script:created.Count -eq 3 -and [WindowsSetupTheme]::SetColorCalls -eq 1 -and [WindowsSetupTheme]::SetWallpaperCalls -eq 1 -and [WindowsSetupTheme]::NotifyCalls -eq 1) 'Theme apply retains six approved HKCU preferences and original native application'
Assert ($script:values.AppsUseLightTheme -eq 0 -and $script:values.SystemUsesLightTheme -eq 0 -and $script:values.BackgroundType -eq 1 -and $script:values.DisableSpotlightCollectionOnDesktop -eq 1) 'Theme applies dark modes solid-color background and desktop Spotlight preference'
[WindowsSetupTheme]::LightReads=1
$actualExplorer=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) 'explorer.exe'
$poison=Join-Path ([IO.Path]::GetTempPath()) ('theme_explorer_poison_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($poison)
[IO.File]::WriteAllText((Join-Path $poison 'explorer.exe'),'inert same-name fixture; never executed')
$oldWindows=$env:SystemRoot;$oldPath=$env:PATH;$oldLocation=Get-Location
try{$env:SystemRoot=$poison;$env:PATH=$poison;Set-Location -LiteralPath $poison;$r=Invoke-SetupThemeSettings -ModuleRoot $module}finally{$env:SystemRoot=$oldWindows;$env:PATH=$oldPath;Set-Location -LiteralPath $oldLocation.Path}
Assert ($script:startedPaths.Count -eq 1 -and $script:startedPaths[0] -ceq $actualExplorer) 'Explorer fallback uses the OS Windows folder despite poisoned CWD PATH and SystemRoot'
Assert ($r.Success -and $r.ExplorerReloaded -and ($script:stopped -join ',') -ceq 'current' -and $script:started -eq 1 -and @($script:processes|Where-Object Name -eq 'other').Count -eq 1) 'only current desktop Explorer reloads when taskbar has not accepted dark mode'
[WindowsSetupTheme]::LightReads=100;$before=[WindowsSetupTheme]::Reads;Reject {Invoke-SetupThemeSettings -ModuleRoot $module} '即時驗證' 'persistent light taskbar cannot be falsely accepted'
Assert (([WindowsSetupTheme]::Reads-$before) -eq 21) 'taskbar retry is bounded to twenty native reads after the first sample'
[WindowsSetupTheme]::LightReads=0;[WindowsSetupTheme]::ColorOk=$false;Reject {Invoke-SetupThemeSettings -ModuleRoot $module} '背景顏色' 'native desktop color failure propagates';[WindowsSetupTheme]::ColorOk=$true
[WindowsSetupTheme]::WallpaperOk=$false;Reject {Invoke-SetupThemeSettings -ModuleRoot $module} '背景圖片' 'native wallpaper removal failure propagates'
[WindowsSetupTheme]::WallpaperOk=$true;[WindowsSetupTheme]::ReadOk=$false
Reject {Invoke-SetupThemeSettings -ModuleRoot $module -VerifyOnly} '讀取' 'failed native wallpaper read cannot falsely verify an empty default buffer'

# Auto-hidden pixels are unavailable, while actual preferences and background remain mandatory.
[WindowsSetupTheme]::ReadOk=$true;[WindowsSetupTheme]::AutoHidden=$true
$beforeWrites=$script:writes.Count;$beforeStops=$script:stopped.Count;$beforeStarts=$script:started;$beforeReads=[WindowsSetupTheme]::Reads
$r=Invoke-SetupThemeSettings -ModuleRoot $module -VerifyOnly
Assert ($r.Success -and $r.TaskbarAppearanceStatus -ceq 'AutoHidden' -and @($r.TaskbarRGB).Count -eq 0 -and $null -eq $r.TaskbarIsDark -and -not $r.TaskbarPixelsVerified) 'confirmed auto-hidden taskbar does not invent RGB or claim verified dark pixels'
Assert ($script:writes.Count -eq $beforeWrites -and $script:stopped.Count -eq $beforeStops -and $script:started -eq $beforeStarts -and [WindowsSetupTheme]::Reads -eq $beforeReads) 'hidden VerifyOnly neither reveals taskbar nor mutates preferences or Explorer'
$script:values.SystemUsesLightTheme=1;Reject {Invoke-SetupThemeSettings -ModuleRoot $module -VerifyOnly} '即時驗證' 'hidden taskbar does not excuse light Windows preference';$script:values.SystemUsesLightTheme=0
[WindowsSetupTheme]::Color=1;Reject {Invoke-SetupThemeSettings -ModuleRoot $module -VerifyOnly} '即時驗證' 'hidden taskbar does not excuse nonblack desktop';[WindowsSetupTheme]::Color=0
[WindowsSetupTheme]::Wallpaper='still present';Reject {Invoke-SetupThemeSettings -ModuleRoot $module -VerifyOnly} '即時驗證' 'hidden taskbar does not excuse wallpaper';[WindowsSetupTheme]::Wallpaper=''
$r=Invoke-SetupThemeSettings -ModuleRoot $module
Assert ($r.Success -and -not $r.ExplorerReloaded -and $script:stopped.Count -eq $beforeStops -and $script:started -eq $beforeStarts) 'hidden apply does not restart Explorer to force a color sample'
[WindowsSetupTheme]::AutoHidden=$false