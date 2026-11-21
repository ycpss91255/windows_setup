#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$script:count=0
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Name};$script:count++}
. (Join-Path $root 'core/gui_stage_library.ps1')
# The native boundary is an inert test assembly; production C# is not changed or executed.
Add-Type -TypeDefinition 'using System;public static class WindowsSetupExplorerOptions{public static int Applied;public static uint Options(bool apply){if(apply)Applied++;return 3;}}public static class NucExplorerRefresh{public static int Calls;public static void SHChangeNotify(int e,uint f,IntPtr a,IntPtr b){Calls++;}}'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('gui_pipeline_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temp)
$script:session=0;$script:tasks=@{};$script:values=@{Hidden=0;ShowSuperHidden=0;HideFileExt=1};$script:writes=0;$script:refreshes=0;$script:taskArguments=@();$script:guarded=@();$script:taskExit=0
function Get-SetupGuiIdentity {[pscustomobject]@{CommonDataRoot=$temp;UserSID='S-1-5-21-1-2-3-1001';SessionId=$script:session;Computer='fixture';PowerShell='fixture powershell.exe'}}
function Assert-SetupGuiAncestors {param($CommonDataRoot) if($CommonDataRoot -ne $temp){throw 'unexpected fixture parent'}}
function New-SetupGuiProtectedDirectory {param($Path,$UserSid) if(-not $Path.StartsWith($temp)){throw 'outside TEMP'};[void][IO.Directory]::CreateDirectory($Path)}
function Assert-SetupGuiProtectedPath {param($Path,[switch]$Directory,$UserSid) if(-not $Path.StartsWith($temp) -or -not(Microsoft.PowerShell.Management\Test-Path -LiteralPath $Path)){throw 'unprotected fixture path'};$script:guarded+=@($Path)}
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) [pscustomobject]@{SessionId=4}}
function Invoke-CimMethod {param($InputObject,$MethodName,$ErrorAction) [pscustomobject]@{ReturnValue=0;Sid='S-1-5-21-1-2-3-1001'}}
function Get-ScheduledTask {param($TaskName,$ErrorAction) if($script:tasks.ContainsKey($TaskName)){[pscustomobject]@{State='Ready'}}}
function Get-ScheduledTaskInfo {param($TaskName,$ErrorAction) if(-not $script:tasks.ContainsKey($TaskName)){throw 'missing pipeline task'};[pscustomobject]@{LastTaskResult=$script:taskExit}}
function New-ScheduledTaskAction {param($Execute,$Argument) $script:taskArguments+=@($Argument);[pscustomobject]@{Execute=$Execute;Argument=$Argument}}
function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel) if($UserId -ne 'S-1-5-21-1-2-3-1001' -or $LogonType -ne 'Interactive' -or $RunLevel -ne 'Highest'){throw 'wrong principal'};[pscustomobject]@{UserId=$UserId}}
function Register-ScheduledTask {param($TaskName,$Action,$Principal,$ErrorAction) $script:tasks[$TaskName]=$Action}
function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm,$ErrorAction) $script:tasks.Remove($TaskName)}
function Start-ScheduledTask {param($TaskName,$ErrorAction)
 $arguments=$script:tasks[$TaskName].Argument
 if($arguments -notmatch '-File "([^"]+)" -Role Explorer -RunId ([a-f0-9-]{36})$'){throw 'unexpected task command'}
 $code=Split-Path (Split-Path $Matches[1] -Parent) -Parent;$run=$Matches[2]
 $old=$script:session;$script:session=4
 try{Invoke-SetupGuiWorker -CodeRoot $code -Role Explorer -RunId $run|Out-Null}finally{$script:session=$old}
}
function Start-Sleep {param($Seconds)}
$key='HKCU:\Software\Microsoft\Windows\CurrentVersion\explorer\Advanced'
function Test-Path {param($Path,$LiteralPath,$PathType) if($Path -eq $key){return $true};Microsoft.PowerShell.Management\Test-Path @PSBoundParameters}
function Set-ItemProperty {param($Path,$Name,$Value) if($Path -ne $key){throw 'unexpected registry mutation'};$script:values[$Name]=$Value;$script:writes++}
function Get-ItemProperty {param($Path) if($Path -ne $key){throw 'unexpected registry read'};[pscustomobject]$script:values}
function New-Object {param($TypeName,$ComObject,$ArgumentList) if($ComObject -ne 'Shell.Application'){throw 'fixture forbids other COM construction'};$shell=[pscustomobject]@{};$shell|Add-Member ScriptMethod Windows {$window=[pscustomobject]@{FullName='explorer.exe'};$window|Add-Member ScriptMethod Refresh {$script:refreshes++};return $window};return $shell}
$result=Invoke-SetupGuiRole -PackageRoot $root -Role Explorer
Assert ($result.Success -and $result.Role -ceq 'Explorer' -and $result.SessionId -eq 4 -and $script:session -eq 0 -and $script:writes -eq 3 -and $script:refreshes -eq 1) 'actual producer dispatch worker and result reader compose safely end to end with inert native boundary'
Assert ([WindowsSetupExplorerOptions]::Applied -eq 1 -and [NucExplorerRefresh]::Calls -eq 1 -and $script:tasks.Count -eq 0) 'apply reaches native boundary once and cleans its own completed task'
$first=$result.RunId;$result=Invoke-SetupGuiRole -PackageRoot $root -Role Explorer -VerifyOnly
Assert ($result.Success -and $result.VerifyOnly -and $result.RunId -cne $first -and $script:writes -eq 3 -and [WindowsSetupExplorerOptions]::Applied -eq 1 -and [NucExplorerRefresh]::Calls -eq 1) 'VerifyOnly takes a fresh protected run without native application or registry writes'
Assert (@($script:taskArguments|Where-Object {$_ -match 'NUC8-Setup|EncodedCommand'}).Count -eq 0 -and $script:guarded.Count -gt 20) 'complete pipeline uses private staged code and validates protected paths repeatedly'
$script:taskExit=7;$failure=''
try{Invoke-SetupGuiRole -PackageRoot $root -Role Explorer -VerifyOnly|Out-Null}catch{$failure=$_.Exception.Message}
if($script:taskArguments[-1] -notmatch '-RunId ([a-f0-9-]{36})$'){throw 'missing rejected run ID'}
$rejectedRun=$Matches[1];$paths=Get-SetupGuiRunPaths -CommonDataRoot $temp -Role Explorer -RunId $rejectedRun
$published=Get-Content -LiteralPath (Join-Path $paths.DataRoot 'Explorer-Verification.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert ($failure.Contains('退出碼') -and $published.Success -eq $true -and $published.RunId -ceq $rejectedRun -and $published.UserSID -ceq 'S-1-5-21-1-2-3-1001' -and $published.SessionId -eq 4 -and $script:tasks.Count -eq 0) 'real bound successful worker report cannot mask exit seven and completed task is removed'
$script:taskExit=0;$result=Invoke-SetupGuiRole -PackageRoot $root -Role Explorer -VerifyOnly
Assert ($result.Success -and $result.RunId -cne $rejectedRun -and $script:tasks.Count -eq 0) 'worker-exit failure releases role stage lock for a fresh verified run'
Write-Host ('ALL PASS: '+$script:count+' TEMP pipeline assertions; no native UI registry or real task operations; ACL boundaries mocked')
