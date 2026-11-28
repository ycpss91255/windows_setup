#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Name}}
$library=Join-Path $root 'modules/taskbar/taskbar_settings_library.ps1'
Assert (Test-Path -LiteralPath $library) 'Taskbar has a named original-source leaf with independent readonly verification'
. $library
function Invoke-SetupTaskbarNativeAutoHide {param([string]$ModuleRoot,[bool]$Apply) return [uint32]1}
function Get-SetupTaskbarPersistedAutoHide {return $true}
function Set-SetupTaskbarPersistedAutoHide {}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('taskbar_leaf_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temp)
$script:createdKeys=@();$script:missingKeys=$true;$script:writes=@();$script:values=@{};$script:pending=$true;$script:backups=0;$script:removed=@();$script:delays=@()
function Test-Path {param($Path,$LiteralPath,$PathType) if($Path -like 'HK*'){return (-not $script:missingKeys)};Microsoft.PowerShell.Management\Test-Path @PSBoundParameters}
function New-Item {param($Path,[switch]$Force) if($Path -notlike 'HK*' -or -not $Force){throw 'unexpected Taskbar key creation'};$script:createdKeys+=@($Path)}
function New-ItemProperty {param($Path,$Name,$Value,$PropertyType,[switch]$Force) if($Path -notlike 'HK*' -or -not $Force){throw 'unexpected Taskbar registry write'};$script:writes+=@($Name);if($script:blockPersonalWidgets -and $Name -eq 'TaskbarDa'){throw 'fixture protected personal widgets'};if($Name -notin @($script:discardNames)){$script:values[$Name]=$Value}}
function Get-ItemProperty {param($Path,$ErrorAction) if($script:corruptLayout){[IO.File]::WriteAllText($layout,'<Layout/>')};if($Path -like '*RunOnce'){return [pscustomobject]@{NUC8FinalizeTaskbar=$(if($script:pending){'pending'}else{$null})}};[pscustomobject]$script:values}
function Export-SetupTaskbarBackup {param($Path) if(-not $Path.StartsWith($temp)){throw 'outside TEMP backup'};$script:backups++}
$layout=Join-Path $temp 'TaskbarLayout.xml'
$r=Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout
$script:missingKeys=$false
Assert ($script:createdKeys.Count -eq 4) 'first-use Taskbar creates missing search widget and layout policy keys through mocked registry only'
Assert ($r.Success -and $script:writes.Count -eq 6 -and $script:backups -eq 1 -and $r.RequiresNextSignIn) 'Taskbar retains original six preference writes backup and pending sign-in semantics'
[xml]$xml=[IO.File]::ReadAllText($layout);$pins=@($xml.SelectNodes('//*[local-name()="TaskbarPinList"]/*'))
Assert ($pins.Count -eq 1 -and $pins[0].DesktopApplicationID -ceq 'MSEdge') 'Taskbar generated layout pins exactly Edge'
$before=$script:writes.Count;$r=Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout -VerifyOnly
Assert (-not $r.Success -and $r.RequiresNextSignIn -and $script:writes.Count -eq $before -and $script:backups -eq 1) 'Taskbar readonly verification cannot claim pending RunOnce is complete'
$script:pending=$false;$script:values.Remove('StartLayoutFile');$script:values.Remove('LockedStartLayout');$r=Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout -VerifyOnly
Assert ($r.Success -and -not $r.RequiresNextSignIn -and $script:writes.Count -eq $before) 'Taskbar readonly verification accepts current preferences after temporary policy cleanup'
$before=$script:writes.Count;$r=Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout
Assert ($r.Success -and (@($script:writes|Select-Object -Skip $before) -join ',') -ceq 'StartLayoutFile,LockedStartLayout') 'Taskbar rerun rewrites only the cleaned-up temporary layout policy and skips preferences already at target'
function Start-Sleep {param($Seconds) $script:delays+=@($Seconds)}
function Remove-ItemProperty {param($Path,$Name,$ErrorAction) if($Path -ne 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'){throw 'unexpected finalize path'};$script:removed+=@($Name);if(-not $script:denyRemoval){$script:values.Remove($Name)}}
$script:values.StartLayoutFile=$layout
$r=Invoke-SetupTaskbarFinalize -LayoutPath $layout
Assert ($r.Success -and ($script:removed -join ',') -ceq 'LockedStartLayout,StartLayoutFile' -and ($script:delays -join ',') -ceq '45') 'Finalize preserves 45-second Explorer delay and removes only temporary matching policy'
$script:values.StartLayoutFile='other-layout';$before=$script:removed.Count;$r=Invoke-SetupTaskbarFinalize -LayoutPath $layout
Assert (-not $r.Success -and $script:removed.Count -eq $before) 'Finalize refuses a changed layout policy without deleting unrelated settings'
$script:values.StartLayoutFile=$layout;$script:values.LockedStartLayout=1;$script:denyRemoval=$true
$r=Invoke-SetupTaskbarFinalize -LayoutPath $layout
Assert (-not $r.Success -and $r.Status -eq 'Failed' -and -not $r.TemporaryLayoutPolicyRemoved) 'Finalize cannot claim removal when native registry readback still has temporary policy'
$script:pending=$true
foreach($name in @('SearchOnTaskbarMode','AllowNewsAndInterests','ShowTaskViewButton','StartLayoutFile','LockedStartLayout')){
 $script:discardNames=@($name);$script:values[$name]=$(if($name -eq 'StartLayoutFile'){'other-layout'}else{7})
 $r=Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout
 Assert (-not $r.Success -and $r.Status -eq 'Failed') ('Apply refuses native write that did not take effect: '+$name)
}
$script:discardNames=@();$script:corruptLayout=$true;$r=Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout
Assert (-not $r.Success -and $r.Status -eq 'Failed') 'Apply refuses invalid XML readback even after write returned normally'
$script:corruptLayout=$false;$r=Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout
Assert ($r.Success -and $r.Status -eq 'Applied' -and $r.RequiresNextSignIn) 'new Apply validates its own policies without rejecting old RunOnce before controller replacement'
$script:blockPersonalWidgets=$true;$script:values.TaskbarDa=7;$r=Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout
Assert ($r.Success -and $r.TaskbarDa -eq 7 -and $r.WidgetsPolicy -eq 0) 'protected personal widget switch still relies on native machine policy readback'
Assert (-not (Test-SetupTaskbarLayout (Join-Path $temp 'absent.xml'))) 'missing physical Taskbar layout cannot be accepted'