#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Name}}
. (Join-Path $root 'core/gui_stage_library.ps1')
Add-Type -TypeDefinition 'using System;using System.Text;namespace WindowsSetupDisplay{public static class Display{public static int Applied,Scaled;public static uint[] Read(){return new uint[]{1920,1080,96};}public static uint[] ReadSnapshot(){return new uint[]{1920,1080,100};}public static uint[] Apply(){Applied++;return new uint[]{1280,720,1920,1080,0,96};}public static uint[] NativeScales(bool apply){if(!apply)throw new Exception("wrong scale mode");Scaled++;return new uint[]{100};}}}public static class NUC8Theme{public sealed class TaskbarSample{public int[] RGB;public bool AutoHidden;}public static bool AutoHidden;public static TaskbarSample ObserveTaskbar(){return new TaskbarSample{RGB=AutoHidden?new int[0]:TaskbarColor(),AutoHidden=AutoHidden};}public static int Applied;public static bool SetSysColors(int n,int[] e,uint[] c){Applied++;return true;}public static bool SystemParametersInfo(uint a,uint p,string v,uint f){return true;}public static IntPtr SendMessageTimeout(IntPtr h,uint m,IntPtr p,string v,uint f,uint t,out IntPtr r){r=IntPtr.Zero;return IntPtr.Zero;}public static int[] TaskbarColor(){return new int[]{21,21,21};}public static bool ReadWallpaper(uint a,uint p,StringBuilder v,uint f){return true;}public static uint GetSysColor(int i){return 0;}}'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('gui_display_theme_pipeline_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temp)
$script:session=0;$script:tasks=@{};$script:arguments=@();$script:writes=0;$script:values=@{Win8DpiScaling=0;AppsUseLightTheme=0;SystemUsesLightTheme=0}
function Get-SetupGuiIdentity {[pscustomobject]@{CommonDataRoot=$temp;UserSID='S-1-5-21-1-2-3-1001';SessionId=$script:session;Computer='fixture';PowerShell='fixture powershell.exe'}}
function Assert-SetupGuiAncestors {param($CommonDataRoot) if($CommonDataRoot -ne $temp){throw 'wrong fixture parent'}}
function New-SetupGuiProtectedDirectory {param($Path,$UserSid) if(-not $Path.StartsWith($temp)){throw 'outside TEMP'};[void][IO.Directory]::CreateDirectory($Path)}
function Assert-SetupGuiProtectedPath {param($Path,[switch]$Directory,$UserSid) if(-not $Path.StartsWith($temp) -or -not(Microsoft.PowerShell.Management\Test-Path -LiteralPath $Path)){throw 'outside protected fixture'}}
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) if($ClassName -ne 'Win32_Process' -or $Filter -ne "Name='explorer.exe'"){throw 'unexpected process query'};[pscustomobject]@{SessionId=4}}
function Invoke-CimMethod {param($InputObject,$MethodName,$ErrorAction) [pscustomobject]@{ReturnValue=0;Sid='S-1-5-21-1-2-3-1001'}}
function Get-ScheduledTask {param($TaskName,$ErrorAction) if($script:tasks.ContainsKey($TaskName)){[pscustomobject]@{State='Ready'}}}
function Get-ScheduledTaskInfo {param($TaskName,$ErrorAction) if(-not $script:tasks.ContainsKey($TaskName)){throw 'wrong task info'};[pscustomobject]@{LastTaskResult=0}}
function New-ScheduledTaskAction {param($Execute,$Argument) if($Execute -ne 'fixture powershell.exe'){throw 'unexpected task executable'};$script:arguments+=@($Argument);[pscustomobject]@{Argument=$Argument}}
function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel) if($UserId -ne 'S-1-5-21-1-2-3-1001' -or $LogonType -ne 'Interactive' -or $RunLevel -ne 'Highest'){throw 'wrong task principal'};[pscustomobject]@{UserId=$UserId}}
function Register-ScheduledTask {param($TaskName,$Action,$Principal,$ErrorAction) $script:tasks[$TaskName]=$Action}
function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm,$ErrorAction) $script:tasks.Remove($TaskName)}
function Start-ScheduledTask {param($TaskName,$ErrorAction)
 if($script:tasks[$TaskName].Argument -notmatch '-File "([^"]+)" -Role (Display|Theme) -RunId ([a-f0-9-]{36})$'){throw 'unexpected fixed worker command'}
 $code=Split-Path (Split-Path $Matches[1] -Parent) -Parent;$role=$Matches[2];$run=$Matches[3];$old=$script:session;$script:session=4
 try{Invoke-SetupGuiWorker -CodeRoot $code -Role $role -RunId $run|Out-Null}finally{$script:session=$old}
}
function Start-Sleep {param($Seconds,$Milliseconds)}
function Test-Path {param($Path,$LiteralPath,$PathType) if($Path -like 'HKCU:*'){return $true};Microsoft.PowerShell.Management\Test-Path @PSBoundParameters}
function New-ItemProperty {param($Path,$Name,$Value,$PropertyType,[switch]$Force) if($Path -notlike 'HKCU:*' -or $PropertyType -ne 'DWord'){throw 'unexpected registry create'};$script:values[$Name]=$Value;$script:writes++}
function Remove-ItemProperty {param($Path,$Name,$ErrorAction) if($Path -ne 'HKCU:\Control Panel\Desktop' -or $Name -ne 'LogPixels'){throw 'unexpected registry remove'};$script:writes++}
function Set-ItemProperty {param($Path,$Name,$Value) if($Path -notin @('HKCU:\Control Panel\Colors','HKCU:\Control Panel\Desktop')){throw 'unexpected registry write'};$script:writes++}
function Get-ItemProperty {param($Path,$ErrorAction) if($Path -notin @('HKCU:\Control Panel\Desktop','HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize')){throw 'unexpected registry read'};[pscustomobject]$script:values}
function Get-Process {throw 'pipeline must not need Explorer reload'}
function Stop-Process {throw 'pipeline forbids real Explorer changes'}
function Start-Process {throw 'pipeline forbids actual process starts'}
foreach($role in @('Display','Theme')){
 $r=Invoke-SetupGuiRole -PackageRoot $root -Role $role
 Assert ($r.Success -and $r.Role -ceq $role -and -not $r.VerifyOnly -and $r.SessionId -eq 4 -and $script:session -eq 0 -and $script:tasks.Count -eq 0) ('actual '+$role+' producer fixed worker leaf and scoped reader compose safely')
 $before=$script:writes;$beforeNative=[WindowsSetupDisplay.Display]::Applied+[NUC8Theme]::Applied;$applyId=$r.RunId
 $r=Invoke-SetupGuiFreshVerification -PackageRoot $root -Role $role
 $paths=Get-SetupGuiRunPaths -CommonDataRoot $temp -Role $role -RunId $r.RunId
 $context=Read-SetupGuiContext -CodeRoot $paths.CodeRoot -CommonDataRoot $temp -Role $role -RunId $r.RunId
 Assert ($r.Success -and $r.VerifyOnly -and $r.RunId -ceq $context.RunId -and $r.RunId -cne $applyId -and $r.UserSID -ceq $context.UserSID -and $r.Computer -ceq $context.Computer -and $script:tasks.Count -eq 0) ('fresh '+$role+' requested GUID reaches actual protected context and returned result')
 Assert ($script:writes -eq $before -and ([WindowsSetupDisplay.Display]::Applied+[NUC8Theme]::Applied) -eq $beforeNative) ('fresh '+$role+' verification does not reapply native APIs or preferences')
}
Assert (-not (Test-Path -LiteralPath (Join-Path $temp 'NUC8-Setup'))) 'Display and Theme never create legacy public result authority'
