#Requires -Version 5.1
function Complete-SetupAfterRestartAcceptance {
 param($Hardware,$Errors,$Previous,$ResultPath,$Sid)
$verificationRunId=[guid]::NewGuid().ToString()
$verification=$null
try{ & (Resolve-NucPath 'verify_only.ps1') -VerificationRunId $verificationRunId }catch{$errors+=('本輪驗證：'+$_.Exception.Message)}
try{
 $candidate=Get-Content (Resolve-NucPath 'Verification-Result.json') -Raw|ConvertFrom-Json
 if($candidate.VerificationRunId -cne $verificationRunId -or $candidate.Computer -cne $env:COMPUTERNAME -or $candidate.UserSID -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw '驗證結果不是本輪、同機、同帳號的結果。'}
 $verification=$candidate
}catch{$errors+=('驗證結果：'+$_.Exception.Message)}
if($null -eq $verification){$verification=[pscustomobject]@{Passed=$false;Checks=@()}}
if($previous -and $previous.Computer -eq $env:COMPUTERNAME -and $previous.UserSID -eq $sid){
 $startPassed=@($verification.Checks|Where-Object {$_.Name -eq '開始選單釘選清空' -and $_.Passed}).Count -eq 1
 if($startPassed){$previous|Add-Member -NotePropertyName PendingModules -NotePropertyValue @($previous.PendingModules|Where-Object {$_.Module -ne 'apply_start_menu_settings.ps1'}) -Force}
 $previous.Success=($verification.Passed -and $errors.Count -eq 0)
 $previous|ConvertTo-Json -Depth 6|Set-Content $resultPath -Encoding UTF8
}
$taskbarChecks=@($verification.Checks|Where-Object {$_.Name -cin @('Edge-only 釘選配置','工作列待處理項目讀回')})
$taskbarEvidence=@{VisualStatus='Unknown';PolicyChecks=$taskbarChecks}
@{TaskbarEvidence=$taskbarEvidence;Computer=$env:COMPUTERNAME;CheckedAt=(Get-Date).ToString('o');Success=($verification.Passed -and $errors.Count -eq 0);Errors=$errors;SkippedChecks=@($verification.Checks|Where-Object Status -eq Skipped);HardwareProfile=$hardware;FailedChecks=@($verification.Checks|Where-Object {$_.Status -ne 'Skipped' -and -not $_.Passed})}|ConvertTo-Json -Depth 6|Set-Content (Resolve-NucPath 'Acceptance-Result.json') -Encoding UTF8
if($errors.Count -or -not $verification.Passed){throw '驗收尚未全部通過。請查看 Acceptance-Result.json；若要求重新開機，手動重開後再執行此入口。'}
Write-Host '設定及清理驗收通過。請目視確認自動登入、工作列僅釘選 Edge ；NUC 適用時再確認無 AMD 位置提示。' -ForegroundColor Green
}
function Invoke-SetupAfterRestartRetryDispatch {
 param([string]$File,[string]$DriverPackagePath,[hashtable]$Confirmation)
 if($File -eq 'install_drivers.ps1'){& (Resolve-NucPath $File) -NonInteractive -DriverPackagePath $DriverPackagePath @Confirmation}elseif($File -eq 'apply_start_menu_settings.ps1'){& (Resolve-NucPath $File) -VerifyOnly|Out-Null}else{& (Resolve-NucPath $File)}
}
function Invoke-SetupAfterRestart {
 param($Hardware,[string]$DriverPackagePath,[hashtable]$Confirmation=@{},[object[]]$SkippedModules=@(),$DriverChoice)
 $ErrorActionPreference='Stop'
$errors=@();$remaining=@()
$resultPath=Resolve-NucPath 'Setup-Result.json'
$retryFiles=@()
if(-not(Test-Path $resultPath)){throw '找不到續跑紀錄，請先執行 windows.cmd。'}
if(Test-Path $resultPath){
 $previous=Get-Content $resultPath -Raw|ConvertFrom-Json
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 if($previous.Computer -cne $env:COMPUTERNAME -or $previous.UserSID -cne $sid){throw '續跑紀錄不是同機、同帳號的結果，未執行更新。'}
 if($previous.Computer -eq $env:COMPUTERNAME -and $previous.UserSID -eq $sid){
  $config=[IO.File]::ReadAllText((Resolve-NucPath 'configuration_library.ps1'))
  $allowed=@([regex]::Matches($config,"File='([^']+\.ps1)'" )|ForEach-Object {$_.Groups[1].Value})
  $retryFiles=@($previous.FailedModules|ForEach-Object {Resolve-NucModuleName $_}|Where-Object {$_ -and $_ -ne 'install_windows_updates.ps1'})
  foreach($file in $retryFiles){
   if($file -notin $allowed){throw ('未知的失敗模組：'+$file)}

  }
 }
}
Write-Host '續跑沿用前次選包，未重新詢問；前次紀錄如下。'
Write-Host $(if($DriverChoice){$DriverChoice.Text}else{'[驅動選擇] 結果：未知（沒有可信的選包結果）；驅動包：未知；偵測型號：未知；包支援型號：未知；手動確認型號：未知'})
Write-Host '重新掃描更新；完成後再次清理預載程式並驗證。' -ForegroundColor Cyan
try{ & (Resolve-NucPath 'install_windows_updates.ps1') }catch{$errors+=('install_windows_updates.ps1：'+$_.Exception.Message);$remaining+='install_windows_updates.ps1';Write-Warning $errors[-1]}
$driverReady=$true
$driverDecision=Get-SetupModuleDecision -Module 'install_drivers.ps1' -Hardware $hardware
if($DriverPackagePath -and $driverDecision.Applicable){
 try{
  $installedOnly=[bool]$hardware.DriverPayloadAbsent
  $null=Test-SetupDriverPayload -Hardware $hardware -DriverPackagePath $DriverPackagePath -InstalledStateOnly:$installedOnly
  . (Resolve-NucPath 'verification_library.ps1')
  $snapshot=Invoke-SetupDriverFreshVerification -DriverPackagePath $DriverPackagePath -VerificationRunId ([guid]::NewGuid().ToString()) -InstalledStateOnly:$installedOnly
  if($installedOnly -and @($snapshot.Targets|Where-Object Status -eq 'UpdateRequired').Count){throw '已選驅動仍需安裝，但驅動包已不在本機；請插回工具包後執行 windows.cmd -AfterRestart。'}
  if(@($snapshot.Targets|Where-Object Status -eq 'UpdateRequired').Count){
   & (Resolve-NucPath 'install_drivers.ps1') -NonInteractive -DriverPackagePath $DriverPackagePath @confirmation
  }elseif(-not $snapshot.Success){throw '已選驅動目前仍有未驗證目標；未強行安裝，請查看唯讀盤點。'}
  elseif($installedOnly){Write-Host '驅動包不在場；本機已安裝驅動讀回符合已核官方目標。' -ForegroundColor Green}
  else{Write-Host '已選驅動符合已核官方目標，未重新解壓及安裝。' -ForegroundColor Green}
 }catch{$driverReady=$false;$errors+=('install_drivers.ps1：'+$_.Exception.Message);$remaining+='install_drivers.ps1';Write-Warning $errors[-1]}
}else{Write-Host '未選獨立驅動包或機型不適用，略過驅動續跑。'}
$guiModules=@('apply_amd_privacy_settings.ps1','apply_taskbar_settings.ps1','apply_start_menu_settings.ps1','apply_display_settings.ps1','apply_desktop_settings.ps1','apply_theme_settings.ps1','desktop_icon_layout.ps1')
foreach($file in $retryFiles){
   if($file -eq 'install_drivers.ps1'){continue}
   if(-not $driverReady -and $file -in $guiModules){$remaining+=$file;Write-Warning ('驅動未完成，保留畫面設定待續跑：'+$file);continue}
   $decision=Get-SetupModuleDecision -Module $file -Hardware $hardware
   if($decision.Status -ceq 'Unknown'){$errors+=($file+'：未知（Unknown）：'+$decision.Reason);$remaining+=$file;Write-Warning ('[未知] '+$errors[-1]);continue}
   if(-not $decision.Applicable){Write-Host ('[略過] '+$decision.Reason);continue}
   Write-Host ('重試未完成模組：'+$file) -ForegroundColor Cyan
   try{ Invoke-SetupAfterRestartRetryDispatch -File $file -DriverPackagePath $DriverPackagePath -Confirmation $confirmation }catch{$errors+=($file+'：'+$_.Exception.Message);$remaining+=$file;Write-Warning $errors[-1]}
}
foreach($file in @('apply_debloat.ps1','apply_copilot_settings.ps1','remove_setup_residue.ps1')){
 try{ Invoke-SetupAfterRestartRetryDispatch -File $file -DriverPackagePath $DriverPackagePath -Confirmation $confirmation }catch{$errors+=($file+'：'+$_.Exception.Message);$remaining+=$file;Write-Warning $errors[-1]}
}
if($previous -and $previous.Computer -eq $env:COMPUTERNAME -and $previous.UserSID -eq $sid){
 $previous|Add-Member -NotePropertyName HardwareProfile -NotePropertyValue $hardware -Force
 $previous|Add-Member -NotePropertyName SkippedModules -NotePropertyValue @($skippedModules) -Force
 $previous.FailedModules=@($remaining|Select-Object -Unique);$previous.StageErrors=$errors
 $previous|ConvertTo-Json -Depth 6|Set-Content $resultPath -Encoding UTF8
}
# The temporary taskbar layout is removed by a 45-second logon worker.
for($i=0;$i -lt 12;$i++){
 $policy=Get-ItemProperty 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -ErrorAction SilentlyContinue
 if(-not $policy.StartLayoutFile){break}
 Write-Host '等待登入後的工作列配置收尾…';Start-Sleep -Seconds 5
}
$layoutDecision=Get-SetupModuleDecision -Module 'desktop_icon_layout.ps1' -Hardware $hardware
if($layoutDecision.Status -ceq 'Unknown'){$errors+=('desktop_icon_layout.ps1：未知（Unknown）：'+$layoutDecision.Reason);Write-Warning ('[未知] 桌面排列：'+$layoutDecision.Reason)}elseif($layoutDecision.Applicable -and $driverReady){try{ & (Resolve-NucPath 'desktop_icon_layout.ps1') -Mode Load }catch{$errors+=$_.Exception.Message}}else{Write-Host ('[略過] 桌面排列：'+$layoutDecision.Reason)}
Complete-SetupAfterRestartAcceptance -Hardware $hardware -Errors $errors -Previous $previous -ResultPath $resultPath -Sid $sid
}
