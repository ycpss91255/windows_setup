#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Name}}
$library=Join-Path $root 'modules/display/display_settings_library.ps1'
Assert (Test-Path -LiteralPath $library) 'Display has a named original-source leaf without importing the elevated public entry'
. $library
Add-Type -TypeDefinition 'namespace WindowsSetupDisplay { public static class Display { public static uint[] Current={1920,1080,96}; public static uint[] Scales={100}; public static uint[] AppliedState={1280,720,1920,1080,0,96}; public static int Applied,ReadCount,ScaleCalls; public static bool ThrowApply; public static uint[] Read(){ReadCount++;return Current;} public static uint[] ReadSnapshot(){ReadCount++;return new uint[]{Current[0],Current[1],Current[2]*100/96};} public static uint[] Apply(){Applied++;if(ThrowApply)throw new System.InvalidOperationException("fixture display native failure");return AppliedState;} public static uint[] NativeScales(bool apply){if(!apply)throw new System.InvalidOperationException("wrong scale mode");ScaleCalls++;return Scales;} } }'
$key='HKCU:\Control Panel\Desktop';$script:custom=0;$script:writes=@();$script:removed=@()
function Get-ItemProperty {param($Path,$ErrorAction) if($Path -ne $key){throw 'unexpected display registry read'};[pscustomobject]@{Win8DpiScaling=$script:custom}}
function New-ItemProperty {param($Path,$Name,$Value,$PropertyType,[switch]$Force) if($Path -ne $key -or $Name -ne 'Win8DpiScaling' -or $Value -ne 0 -or $PropertyType -ne 'DWord' -or -not $Force){throw 'unexpected display registry write'};if(-not $script:ignoreCustomWrite){$script:custom=$Value};$script:writes+=@($Name)}
function Remove-ItemProperty {param($Path,$Name,$ErrorAction) if($Path -ne $key -or $Name -ne 'LogPixels'){throw 'unexpected display registry removal'};$script:removed+=@($Name)}
$module=Join-Path $root 'modules/display'
$r=Invoke-SetupDisplaySettings -ModuleRoot $module -VerifyOnly
Assert ($r.Success -and $r.Width -eq 1920 -and $r.Height -eq 1080 -and $r.CurrentMonitorDPI -eq 96 -and $r.CurrentScalePercent -eq 100 -and -not $r.CustomScalingEnabled -and $null -eq $r.Error) 'Display VerifyOnly reports actual 1080p DPI96 and standard 100 percent'
Assert ($script:writes.Count -eq 0 -and $script:removed.Count -eq 0 -and [WindowsSetupDisplay.Display]::Applied -eq 0 -and [WindowsSetupDisplay.Display]::ScaleCalls -eq 0) 'Display VerifyOnly performs no native apply or registry mutations'
$script:custom=1;$r=Invoke-SetupDisplaySettings -ModuleRoot $module -VerifyOnly
Assert (-not $r.Success -and $r.CustomScalingEnabled -and $r.Error) 'matching actual resolution alone cannot hide custom scaling'
$script:custom=0;[WindowsSetupDisplay.Display]::Current=@(1920,1080,120);$r=Invoke-SetupDisplaySettings -ModuleRoot $module -VerifyOnly
Assert (-not $r.Success -and $r.CurrentScalePercent -eq 125) 'actual monitor DPI is verified instead of a requested scaling preference'
[WindowsSetupDisplay.Display]::Current=@(1280,720,96);$r=Invoke-SetupDisplaySettings -ModuleRoot $module -VerifyOnly
Assert (-not $r.Success -and $r.Width -eq 1280) 'nonmatching live resolution cannot pass verification'
$script:custom=1;$r=Invoke-SetupDisplaySettings -ModuleRoot $module
Assert ($r.Success -and $r.PreviousWidth -eq 1280 -and $r.PreviousHeight -eq 720 -and $r.Width -eq 1920 -and $r.Height -eq 1080 -and $r.RequestedScalePercent -eq 100 -and @($r.NativeScalePercent)[0] -eq 100 -and -not $r.CustomScalingEnabled -and $r.LegacyAppsMayRequireNextSignIn) 'Display apply preserves native result details and standard scaling contract'
Assert (($script:writes -join ',') -ceq 'Win8DpiScaling' -and ($script:removed -join ',') -ceq 'LogPixels' -and $script:custom -eq 0 -and [WindowsSetupDisplay.Display]::Applied -eq 1 -and [WindowsSetupDisplay.Display]::ScaleCalls -eq 1) 'Display applies original native API and only approved dynamic-user scaling changes'
[WindowsSetupDisplay.Display]::Scales=@(100,125);$failure='';try{Invoke-SetupDisplaySettings -ModuleRoot $module|Out-Null}catch{$failure=$_.Exception.Message}
Assert ($failure.Contains('100%')) 'one monitor failing standard scaling prevents a false successful apply'
[WindowsSetupDisplay.Display]::ThrowApply=$true;$failure='';try{Invoke-SetupDisplaySettings -ModuleRoot $module|Out-Null}catch{$failure=$_.Exception.Message}
Assert ($failure.Contains('fixture display native failure')) 'Display native failures propagate to the protected worker'
[WindowsSetupDisplay.Display]::ThrowApply=$false;[WindowsSetupDisplay.Display]::Scales=@(100)
foreach($case in @(@{State=@(1280,720,1280,720,0,96);Need='1920'},@{State=@(1280,720,1280,720,1,96);Need='重新開機'},@{State=@(1280,720,1920,1080,1,96);Need='重新開機'},@{State=@(1280,720,1920,1080,2,96);Need='結果碼'})){
 [WindowsSetupDisplay.Display]::AppliedState=$case.State;$before=$script:writes.Count;$failure='';$r=$null
 try{$r=Invoke-SetupDisplaySettings -ModuleRoot $module}catch{$failure=$_.Exception.Message}
 Assert (($failure.Contains($case.Need) -or ($r -and -not $r.Success)) -and $script:writes.Count -eq $before) ('Apply must reject unchanged actual size or nonzero native result before preference changes: '+($case.State -join ','))
}
[WindowsSetupDisplay.Display]::AppliedState=@(1280,720,1920,1080,0,96);$script:ignoreCustomWrite=$true;$script:custom=1;$failure=''
try{Invoke-SetupDisplaySettings -ModuleRoot $module|Out-Null}catch{$failure=$_.Exception.Message}
Assert ($failure.Contains('自訂縮放')) 'Apply must not claim standard scaling when disabling custom scaling did not take effect'
$script:ignoreCustomWrite=$false;[WindowsSetupDisplay.Display]::Scales=@();$failure=''
try{Invoke-SetupDisplaySettings -ModuleRoot $module|Out-Null}catch{$failure=$_.Exception.Message}
Assert ($failure.Contains('100%')) 'Apply requires at least one actual standard scaling readback'