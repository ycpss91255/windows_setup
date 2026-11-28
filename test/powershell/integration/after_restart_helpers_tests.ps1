#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
$library=Join-Path $root 'core/after_restart_library.ps1'
Assert (Test-Path -LiteralPath $library) 'AfterRestart 提供安全具名原始入口'
. $library
$fixture=Join-Path $env:TEMP ('after_restart_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Copy-Item -LiteralPath (Join-Path $root 'core/configuration_library.ps1') -Destination $fixture
foreach($name in @('apply_start_menu_settings.ps1','install_drivers.ps1','apply_power_settings.ps1','install_windows_updates.ps1','apply_debloat.ps1','apply_copilot_settings.ps1','remove_setup_residue.ps1','desktop_icon_layout.ps1')){
 [IO.File]::WriteAllText((Join-Path $fixture $name),@'
param([switch]$VerifyOnly,[switch]$NonInteractive,$DriverPackagePath,$ConfirmedBoard,$ConfirmationComputer,$Mode)
$name=[IO.Path]::GetFileName($PSCommandPath);$global:restartFixture.Calls.Add($name)
if($name -eq 'apply_start_menu_settings.ps1' -and -not $VerifyOnly){throw 'unsafe Start mutation'}
if($name -eq 'install_drivers.ps1'){$global:restartFixture.Driver=@{Path=$DriverPackagePath;Board=$ConfirmedBoard;Computer=$ConfirmationComputer;NonInteractive=[bool]$NonInteractive}}
if($name -eq $global:restartFixture.Fail){throw 'fixture module failure'}
'@,[Text.UTF8Encoding]::new($true))
}
[IO.File]::WriteAllText((Join-Path $fixture 'verify_only.ps1'),@'
param($VerificationRunId)
if($global:restartFixture.Mode -eq 'no_result'){throw 'fixture verifier failure'}
$r=@{VerificationRunId=$VerificationRunId;Computer=$env:COMPUTERNAME;UserSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Passed=$true;Checks=@(@{Name='開始選單釘選清空';Passed=$true;Status='Passed'})}
if($global:restartFixture.Mode -eq 'stale'){$r.VerificationRunId='old'}
if($global:restartFixture.Mode -eq 'wrong_user'){$r.UserSID='wrong'}
if($global:restartFixture.Mode -eq 'failed_check'){$r.Passed=$false;$r.Checks[0].Passed=$false}
$r|ConvertTo-Json -Depth 5|Set-Content (Join-Path $PSScriptRoot 'Verification-Result.json') -Encoding UTF8
'@,[Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText((Join-Path $fixture 'verification_library.ps1'),@'
function Invoke-SetupDriverFreshVerification {
 param($DriverPackagePath,$VerificationRunId,[switch]$InstalledStateOnly)
 $global:restartFixture.Calls.Add('driver_snapshot')
 $global:restartFixture.SnapshotPath=$DriverPackagePath
 $global:restartFixture.SnapshotInstalledOnly=[bool]$InstalledStateOnly
 $status=if($global:restartFixture.Mode -in @('update_required','driver_failure','installed_update_required')){'UpdateRequired'}elseif($global:restartFixture.Mode -eq 'unverified_driver'){'Unverified'}else{'Current'}
 [pscustomobject]@{Success=($status -eq 'Current');Targets=@([pscustomobject]@{Status=$status});VerificationRunId=$VerificationRunId}
}
'@,[Text.UTF8Encoding]::new($true))
function Test-SetupDriverPayload {param($Hardware,$DriverPackagePath,[switch]$InstalledStateOnly) $global:restartFixture.PayloadChecked=$true;$global:restartFixture.PayloadInstalledOnly=[bool]$InstalledStateOnly}
function Resolve-NucPath {param($Name) Join-Path $fixture $Name}
function Resolve-NucModuleName {param($Name) if($Name -eq 'Apply-PowerSettings.ps1'){'apply_power_settings.ps1'}else{$Name}}
function Get-SetupModuleDecision {param($Module,$Hardware) $unknown=($Module -eq $global:restartFixture.Unknown);[pscustomobject]@{Applicable=($Module -ne $global:restartFixture.Skip -and -not $unknown);Status=$(if($unknown){'Unknown'}else{'Applicable'});Reason=$(if($unknown){'fixture language unknown'}else{'fixture skipped'})}}
function Get-ItemProperty {param($Path,$ErrorAction) $global:restartFixture.PolicyReads++;[pscustomobject]@{StartLayoutFile=$(if($global:restartFixture.PolicyReads -eq 1){'fixture'}else{''})}}
function Start-Sleep {param($Seconds) $global:restartFixture.SleepCalls++}
try{
 foreach($mode in @('success','retry_failure','skip','stale','wrong_user','no_result','failed_check','foreign_previous','unknown_module','update_required','driver_failure','unverified_driver','unknown_layout','unknown_layout_final','installed_current','installed_update_required')){
  $global:restartFixture=@{Mode=$mode;Unknown=$(if($mode -in @('unknown_layout','unknown_layout_final')){'desktop_icon_layout.ps1'}else{''});Calls=[Collections.Generic.List[string]]::new();Fail=$(if($mode -eq 'retry_failure'){'apply_power_settings.ps1'}elseif($mode -eq 'driver_failure'){'install_drivers.ps1'}else{''});Skip=$(if($mode -eq 'skip'){'install_drivers.ps1'}else{''});PolicyReads=0;SleepCalls=0}
  $prior=@{Computer=$env:COMPUTERNAME;UserSID=$sid;FailedModules=@('Apply-PowerSettings.ps1','install_drivers.ps1','apply_start_menu_settings.ps1','install_windows_updates.ps1');StageErrors=@();Success=$false;PendingModules=@(@{Module='apply_start_menu_settings.ps1';Status='PendingSignIn'})}
  if($mode -eq 'foreign_previous'){$prior.UserSID='foreign'}
  if($mode -eq 'unknown_layout'){$prior.FailedModules=@($prior.FailedModules)+'desktop_icon_layout.ps1'}
  if($mode -eq 'unknown_module'){$prior.FailedModules=@('apply_power_settings.ps1','untrusted.ps1')}
  $result=Join-Path $fixture 'Setup-Result.json';$prior|ConvertTo-Json -Depth 5|Set-Content $result -Encoding UTF8
  Remove-Item -LiteralPath (Join-Path $fixture 'Verification-Result.json'),(Join-Path $fixture 'Acceptance-Result.json') -Force -ErrorAction SilentlyContinue
  $fixtureHardware=if($mode -like 'installed_*'){[pscustomobject]@{DriverPayloadAbsent=$true}}else{[pscustomobject]@{}}
  $caught='';try{Invoke-SetupAfterRestart -Hardware $fixtureHardware -DriverPackagePath 'fixture drivers' -Confirmation @{ConfirmedBoard='NUC8i7HVB';ConfirmationComputer='fixture'} -SkippedModules @()}catch{$caught=$_.Exception.Message}
  if($mode -eq 'unknown_module'){Assert ($caught -like '未知的失敗模組*' -and $global:restartFixture.Calls.Count -eq 0) '未知續跑模組拒絕且未執行';continue}
  if($mode -eq 'foreign_previous'){Assert ($caught -like '續跑紀錄不是*' -and $global:restartFixture.Calls.Count -eq 0) '不同帳號紀錄拒絕且更新之前沒有副作用';continue}
  $r=Get-Content -LiteralPath (Join-Path $fixture 'Acceptance-Result.json') -Raw|ConvertFrom-Json
  $pass=$mode -in @('success','skip','update_required','installed_current')
  if($mode -like 'installed_*'){Assert ($global:restartFixture.PayloadInstalledOnly -and $global:restartFixture.SnapshotInstalledOnly) ('驅動包不在時只核清單身分並讀回已安裝驅動 '+$mode)}
  if($mode -eq 'installed_current'){Assert (-not $global:restartFixture.Calls.Contains('install_drivers.ps1') -and $global:restartFixture.Calls.Contains('apply_start_menu_settings.ps1')) '驅動包不在但已安裝驅動符合時視為通過並繼續 GUI'}
  if($mode -eq 'installed_update_required'){$saved=Get-Content -LiteralPath $result -Raw|ConvertFrom-Json;Assert (-not $global:restartFixture.Calls.Contains('install_drivers.ps1') -and -not $global:restartFixture.Calls.Contains('apply_start_menu_settings.ps1') -and (@($saved.StageErrors) -join '|').Contains('驅動包已不在本機')) '驅動包不在且需安裝時不嘗試安裝並說明插回驅動包'}
  if($mode -in @('success','update_required')){Assert (-not $global:restartFixture.PayloadInstalledOnly -and -not $global:restartFixture.SnapshotInstalledOnly) ('驅動包在場時維持完整雜湊驗證 '+$mode)}
  Assert ($r.Success -eq $pass) ('AfterRestart 真結果 '+$mode)
  Assert ((-not $caught) -eq $pass) ('例外與摘要一致 '+$mode)
  Assert (@($global:restartFixture.Calls|Where-Object {$_ -eq 'install_windows_updates.ps1'}).Count -eq 1 -and $global:restartFixture.Calls.Contains('remove_setup_residue.ps1')) ('更新只呼叫一次且後續清理持續 '+$mode)
  Assert ($global:restartFixture.SleepCalls -eq 1) ('登入政策等待使用安全替身 '+$mode)
  if($mode -eq 'success'){$calls=@($global:restartFixture.Calls);Assert ($calls[0] -eq 'install_windows_updates.ps1' -and $calls.IndexOf('install_windows_updates.ps1') -lt $calls.IndexOf('apply_power_settings.ps1')) '續跑先更新才重試驅動與GUI，不能以舊排列先執行'}
  if($mode -eq 'success'){$calls=@($global:restartFixture.Calls);Assert ($calls.IndexOf('install_windows_updates.ps1') -lt $calls.IndexOf('driver_snapshot') -and $calls.IndexOf('driver_snapshot') -lt $calls.IndexOf('apply_start_menu_settings.ps1')) 'WU後重新讀回已選驅動才進GUI'}
  if($mode -eq 'update_required'){$calls=@($global:restartFixture.Calls);Assert ($calls.IndexOf('driver_snapshot') -lt $calls.IndexOf('install_drivers.ps1') -and $calls.IndexOf('install_drivers.ps1') -lt $calls.IndexOf('apply_start_menu_settings.ps1') -and $global:restartFixture.Driver.NonInteractive) '只有需更新才安裝，驅動完成後再跑GUI'}
  if($mode -in @('driver_failure','unverified_driver')){Assert (-not $global:restartFixture.Calls.Contains('apply_start_menu_settings.ps1') -and $global:restartFixture.Calls.Contains('remove_setup_residue.ps1')) '驅動未核正常不重試GUI，其他清理仍持續'}
  $saved=Get-Content -LiteralPath $result -Raw|ConvertFrom-Json
  if($mode -eq 'success'){Assert ($saved.PendingModules.Count -eq 0 -and $saved.Success -and $global:restartFixture.SnapshotPath -eq 'fixture drivers' -and $global:restartFixture.PayloadChecked -and -not $global:restartFixture.Calls.Contains('install_drivers.ps1')) '目前官方目標已核即不重解壓安裝，仍清除Start pending'}
  if($mode -eq 'unknown_layout'){Assert (-not $global:restartFixture.Calls.Contains('desktop_icon_layout.ps1') -and $saved.FailedModules -contains 'desktop_icon_layout.ps1' -and ((@($saved.StageErrors) -join ' ') -match 'Unknown|未知')) '續跑圖示語言 Unknown 不執行、保留待續跑並列為錯誤'}
  if($mode -eq 'unknown_layout_final'){Assert (-not $global:restartFixture.Calls.Contains('desktop_icon_layout.ps1') -and -not $r.Success -and ((@($r.Errors) -join ' ') -match 'desktop_icon_layout\.ps1.*Unknown') -and $caught) '續跑最後一步圖示語言 Unknown 不執行並使驗收失敗，而非略過'}
  if($mode -eq 'retry_failure'){Assert ($saved.FailedModules -contains 'apply_power_settings.ps1') '失敗模組仍留可續跑'}
  if($mode -eq 'foreign_previous'){Assert ($saved.UserSID -eq 'foreign' -and -not $global:restartFixture.Calls.Contains('apply_start_menu_settings.ps1')) '不同帳號舊紀錄不重試也不改寫'}
 }
}finally{if($fixture.StartsWith([IO.Path]::GetFullPath($env:TEMP),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $fixture -Recurse -Force};Remove-Variable restartFixture -Scope Global -ErrorAction SilentlyContinue}
