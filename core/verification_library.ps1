#Requires -Version 5.1
function Invoke-SetupDriverFreshVerification {
 param([Parameter(Mandatory=$true)][string]$DriverPackagePath,[Parameter(Mandatory=$true)][string]$VerificationRunId)
 . (Resolve-NucPath 'driver_installation_library.ps1')
 $results=@(Invoke-SetupDriverVerification -DriverRoot $DriverPackagePath -VerificationRunId $VerificationRunId)
 if($results.Count -ne 1 -or $results[0].Success -isnot [bool] -or $results[0].VerificationRunId -cne $VerificationRunId -or $results[0].Computer -cne [Environment]::MachineName -or $results[0].UserSID -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw '驅動結果不是本輪、同機、同帳號的可信結果。'}
 return $results[0]
}
function Complete-SetupVerificationResult {
 param($Checks,$Hardware,$VerificationRunId)
$result=[ordered]@{VerificationRunId=$VerificationRunId;UserSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Computer=$env:COMPUTERNAME;VerifiedAt=(Get-Date).ToString('o');HardwareProfile=$hardware;SkippedCount=@($checks|Where-Object Status -eq Skipped).Count;Passed=(Test-SetupChecksPassed -Checks @($checks.ToArray()));Checks=@($checks.ToArray());Notes=@('本工具只驗證，不安裝更新或重新套用偏好。','自動登入是否真的成功，以及工作列實際圖示，仍需在下次登入後觀察。','Windows 啟用由使用者另外處理。')}
$result|ConvertTo-Json -Depth 6|Set-Content (Resolve-NucPath 'Verification-Result.json') -Encoding UTF8
Write-Host ('驗證紀錄：'+(Resolve-NucPath 'Verification-Result.json'))
if(-not $result.Passed){throw '驗證未全部通過；已寫入 Verification-Result.json。'}
}
function Add-SetupStartVerificationCheck {
 param([string]$PackageRoot)
 try{ $startCheck=Invoke-SetupGuiFreshVerification -PackageRoot $PackageRoot -Role Start;$startPassed=($startCheck.Success -eq $true -and $startCheck.Status -eq 'Confirmed' -and $null -ne $startCheck.PinCount -and $startCheck.PinCount -eq 0);Add-Check '開始選單釘選清空' $startPassed ('Status='+$startCheck.Status+'; PinCount='+$startCheck.PinCount) }catch{Add-Check '開始選單釘選清空' $false $_.Exception.Message}
}
function Invoke-SetupVerification {
 param([Parameter(Mandatory=$true)]$Hardware,[string]$DriverPackagePath,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9-]{36}$')][string]$VerificationRunId)
 $ErrorActionPreference='Stop'
$checks=New-Object Collections.Generic.List[object]
function Add-Check([string]$Name,[bool]$Passed,[string]$Detail){
 $checks.Add([pscustomobject]@{Name=$Name;Passed=$Passed;Status=$(if($Passed){'Passed'}else{'Failed'});Detail=$Detail})
 $label=if($Passed){'通過'}else{'未通過/待生效'}
 $color=if($Passed){'Green'}else{'Yellow'}
 Write-Host ('['+$label+'] '+$Name+'：'+$Detail) -ForegroundColor $color
}
Write-Host '=== Windows 可重複驗證（不安裝更新、不重新套用設定） ===' -ForegroundColor Cyan
try{ & (Resolve-NucPath 'audit_nuc.ps1')|Out-Null }catch{Add-Check '基本硬體與帳號稽核' $false $_.Exception.Message}
$ssh=Get-CimInstance Win32_Service -Filter "Name='sshd'"
Add-Check 'SSH' ($ssh.State -eq 'Running' -and $ssh.StartMode -eq 'Auto') ($ssh.State+' / '+$ssh.StartMode)
try{ & (Resolve-NucPath 'initialize_ssh_client.ps1') -VerifyOnly|Out-Null;Add-Check 'SSH 客戶端目錄' $true '目前使用者 .ssh/config、active-sites.conf、config.d 已存在' }catch{Add-Check 'SSH 客戶端目錄' $false $_.Exception.Message}
try{ & (Resolve-NucPath 'apply_lan_ping_settings.ps1') -VerifyOnly|Out-Null;Add-Check '同網段 IPv4/IPv6 Ping' $true 'LocalSubnet 入站回應規則啟用' }catch{Add-Check '同網段 IPv4/IPv6 Ping' $false $_.Exception.Message}
try{
 $mdnsResults=@(& (Resolve-NucPath 'apply_mdns_settings.ps1') -VerifyOnly)
 if($mdnsResults.Count -ne 1){throw 'mDNS公告唯讀驗證未回傳唯一結果。'}
 $mdns=$mdnsResults[0];$publisherRun=[guid]::Empty
 if($mdns.Success -isnot [bool] -or -not $mdns.Success -or $mdns.Status -cne 'Registered' -or $mdns.Name -isnot [string] -or $mdns.Name -ine ([Environment]::MachineName+'.local') -or $mdns.RemoteVerified -isnot [bool] -or $mdns.RemoteVerified -ne $false -or -not [guid]::TryParseExact([string]$mdns.RunId,'D',[ref]$publisherRun) -or $publisherRun -eq [guid]::Empty){throw 'mDNS公告結果的狀態、目前名稱或原生工作者識別不符。'}
 Add-Check 'mDNS 持續公告' $true ('本機原生持續公告已註冊：'+$mdns.Name+'；跨機解析請在另一臺同網段電腦驗證。')
}catch{Add-Check 'mDNS 持續公告' $false $_.Exception.Message}
try{ & (Resolve-NucPath 'apply_hosts_sync.ps1') -VerifyOnly|Out-Null;Add-Check '依網路自動匯入框架' $true '各啟用輸出、目前帳號、背景程序及來源收斂均通過' }catch{Add-Check '依網路自動匯入框架' $false $_.Exception.Message}
try{
 $privacy=Invoke-FreshVerification -ScriptPath (Resolve-NucPath 'apply_privacy_settings.ps1') -ReportPath (Join-Path $env:ProgramData 'NUC8-Setup/Privacy-Result.json') -Arguments @{VerifyOnly=$true}
 Add-Check '非必要資料分享政策' $privacy.Success ('九項政策讀回；Windows診斷級別：'+$privacy.DiagnosticLevel+'；不代表其他應用程式不傳送資料。')
}catch{Add-Check '非必要資料分享政策' $false $_.Exception.Message}
try{
 $uac=Invoke-FreshVerification -ScriptPath (Resolve-NucPath 'apply_uac_settings.ps1') -ReportPath (Join-Path $env:ProgramData 'NUC8-Setup/UAC-Result.json') -Arguments @{VerifyOnly=$true}
 Add-Check '管理員提權提示政策' $uac.Success 'EnableLUA仍為1；此電腦管理員自動核准提權。'
}catch{Add-Check '管理員提權提示政策' $false $_.Exception.Message}
$sshFirewall=Get-SetupSSHFirewallStatus
Add-Check 'SSH 防火牆規則' $sshFirewall.Passed $sshFirewall.Detail
foreach($setting in @('STANDBYIDLE','HIBERNATEIDLE')){
 $text=(& powercfg.exe /query SCHEME_CURRENT SUB_SLEEP $setting) -join "`n"
 $match=[regex]::Match($text,'(?im)^.*AC.*:\s*0x([0-9a-f]+)\s*$')
 $value=if($match.Success){[Convert]::ToInt64($match.Groups[1].Value,16)}else{-1}
 Add-Check ('插電 '+$setting) ($value -eq 0) ('秒數：'+$value+'；0 表示永不')
}
$auto=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Add-Check '自動登入設定' ($auto.AutoAdminLogon -eq '1' -and  $auto.DefaultUserName -eq $env:USERNAME) ('啟用值：'+$auto.AutoAdminLogon+'；帳號：'+$auto.DefaultUserName+'；實際自動登入仍需開機觀察')
$driverDecision=Get-SetupModuleDecision -Module 'install_drivers.ps1' -Hardware $hardware
if(-not $driverDecision.Applicable){$checks.Add((New-SetupSkippedCheck -Name '已選驅動官方目標' -Reason $driverDecision.Reason));Write-Host ('[略過] '+$driverDecision.Reason)}
else{try{
 $null=Test-SetupDriverPayload -Hardware $hardware -DriverPackagePath $DriverPackagePath
 $driver=Invoke-SetupDriverFreshVerification -DriverPackagePath $DriverPackagePath -VerificationRunId $VerificationRunId
 $states=@($driver.Targets|Group-Object Status|ForEach-Object {$_.Name+'='+$_.Count}) -join '；'
 Add-Check '已選驅動官方目標' $driver.Success ('本輪重新讀取供應商、版本及狀態；'+$states)
}catch{Add-Check '已選驅動官方目標' $false $_.Exception.Message}}
$devices=@(Get-PnpDevice -PresentOnly|Where-Object Status -ne 'OK')
Add-Check '驅動裝置' ($devices.Count -eq 0) ('異常數：'+$devices.Count)
$search=Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -ErrorAction SilentlyContinue
Add-Check '搜尋欄隱藏原則' ($null -ne $search.SearchOnTaskbarMode -and $search.SearchOnTaskbarMode -eq 0) ('SearchOnTaskbarMode：'+$search.SearchOnTaskbarMode)
$widgets=Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -ErrorAction SilentlyContinue
Add-Check '天氣/小工具關閉原則' ($null -ne $widgets.AllowNewsAndInterests -and $widgets.AllowNewsAndInterests -eq 0) ('AllowNewsAndInterests：'+$widgets.AllowNewsAndInterests)
$advanced=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\explorer\Advanced' -ErrorAction SilentlyContinue
Add-Check '工作檢視按鈕隱藏' ($null -ne $advanced.ShowTaskViewButton -and $advanced.ShowTaskViewButton -eq 0) ('ShowTaskViewButton：'+$advanced.ShowTaskViewButton)
try{
 $fresh=Invoke-SetupGuiFreshVerification -PackageRoot $script:NucPackageRoot -Role Taskbar
 Add-Check 'Edge-only 釘選配置' ([bool]$fresh.Configured -and [bool]$fresh.BindingMatches) '即時檢查受保護配置恰為 MSEdge Replace，政策及 RunOnce 對應固定 GUID 工作；實際圖示需在登入後查看'
 Add-Check '釘選登入後套用' ([bool]$fresh.Success -and -not $fresh.RequiresNextSignIn) ('Status='+$fresh.Status+'；以目前登錄與受保護 XML 讀回確認')
}catch{Add-Check 'Edge-only 釘選配置' $false $_.Exception.Message;Add-Check '釘選登入後套用' $false $_.Exception.Message}
try{
 $fresh=Invoke-SetupGuiFreshVerification -PackageRoot $script:NucPackageRoot -Role Display
 Add-Check '實際解析度與縮放' ([bool]$fresh.Success) ('本輪即時結果：'+($fresh|ConvertTo-Json -Compress -Depth 5))
}catch{Add-Check '實際解析度與縮放' $false $_.Exception.Message}
$desktopKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\explorer\HideDesktopIcons\NewStartPanel'
$icons=Get-ItemProperty $desktopKey -ErrorAction SilentlyContinue
$show=@('{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}','{20D04FE0-3AEA-1069-A2D8-08002B30309D}','{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}','{645FF040-5081-101B-9F08-00AA002F954E}')
$iconsOK=$true
foreach($id in $show){if($null -eq $icons.$id -or $icons.$id -ne 0){$iconsOK=$false}}
Add-Check '四個桌面系統圖示' $iconsOK '控制台、本機、網路、資源回收筒的顯示設定'
$desktopFiles=@(foreach($dir in @([Environment]::GetFolderPath('DesktopDirectory'),[Environment]::GetFolderPath('CommonDesktopDirectory'))){Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue|Where-Object {-not ($_.Attributes -band [IO.FileAttributes]::System)}|Select-Object -ExpandProperty Name})
Add-Check '桌面無其他一般檔案/捷徑' ($desktopFiles.Count -eq 0) ('剩餘項目：'+($desktopFiles -join ', '))
try{
 $fresh=Invoke-SetupGuiFreshVerification -PackageRoot $script:NucPackageRoot -Role Theme
 Add-Check '深色模式與純黑背景' ([bool]$fresh.Success) ('本輪即時結果：'+($fresh|ConvertTo-Json -Compress -Depth 5))
}catch{Add-Check '深色模式與純黑背景' $false $_.Exception.Message}
$layoutDecision=Get-SetupModuleDecision -Module 'desktop_icon_layout.ps1' -Hardware $hardware
if($layoutDecision.Applicable){
try{
 $fresh=Invoke-SetupGuiFreshVerification -PackageRoot $script:NucPackageRoot -Role Icons
 Add-Check '四個圖示的實際排列座標' ([bool]$fresh.Success) ('本輪即時結果：'+($fresh|ConvertTo-Json -Compress -Depth 5))
}catch{Add-Check '四個圖示的實際排列座標' $false $_.Exception.Message}
}else{$checks.Add((New-SetupSkippedCheck -Name '四個圖示的實際排列座標' -Reason $layoutDecision.Reason));Write-Host ('[略過] '+$layoutDecision.Reason)}
try{
 $commonData=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
 $updates=Read-SetupUpdateResult -CommonDataRoot $commonData -LegacyRoot (Join-Path $commonData 'NUC8-Setup/WindowsUpdate') -UserSid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -Computer $env:COMPUTERNAME
 Add-Check '最近一次更新結果' (Test-WindowsUpdateResult $updates) ('完成時間：'+$updates.CompletedAt+'；安裝項目：'+$updates.Updates.Count+'；本輪ID：'+$updates.RunId)
}catch{Add-Check '最近一次更新結果' $false $_.Exception.Message}
$reboot=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
Add-Check '無待處理重新開機' (-not $reboot) $(if($reboot){'Windows 要求重新開機；目前不會自動重開'}else{'未偵測到待重新開機'})
$apps=Get-Content (Resolve-NucPath 'debloat_apps.txt')|Where-Object {$_ -and -not $_.StartsWith('#')}
$remaining=@(Get-AppxPackage -AllUsers|Where-Object {@($_.PackageUserInformation|Where-Object InstallState -eq 'Installed').Count -gt 0}|Where-Object Name -in $apps|Select-Object -ExpandProperty Name -Unique)
Add-Check '預載 App 清理' ($remaining.Count -eq 0) ('清單內仍存在：'+($remaining -join ', '))
try{
 $fresh=Invoke-FreshVerification -ScriptPath (Resolve-NucPath 'apply_debloat.ps1') -ReportPath (Join-Path $env:ProgramData 'NUC8-Setup/Debloat-Result.json') -Arguments @{VerifyOnly=$true}
 Add-Check '清理功能登錄讀回' ([bool]$fresh.Success) '重新讀取目前 build 適用功能的登錄型別及值，不以第三方退出碼或舊報告代替'
}catch{Add-Check '清理功能登錄讀回' $false $_.Exception.Message}
try{
 $fresh=Invoke-FreshVerification -ScriptPath (Resolve-NucPath 'apply_pagefile_settings.ps1') -ReportPath (Join-Path $env:ProgramData 'NUC8-Setup\Pagefile-Result.json') -Arguments @{VerifyOnly=$true}
 Add-Check '磁碟分頁檔停用設定' ([bool]$fresh.Success) ('本輪即時結果：'+($fresh|ConvertTo-Json -Compress -Depth 5))
 Add-Check '分頁檔實際已停用' (@($fresh.ActivePagefiles|Where-Object {$_}).Count -eq 0) '如仍作用中，需重新開機才生效'
}catch{Add-Check '磁碟分頁檔停用設定' $false $_.Exception.Message}
try{ & (Resolve-NucPath 'apply_copilot_settings.ps1') -VerifyOnly|Out-Null;Add-Check '獨立版 Copilot 清理' $true '未安裝' }catch{Add-Check '獨立版 Copilot 清理' $false $_.Exception.Message}
$amdDecision=Get-SetupModuleDecision -Module 'apply_amd_privacy_settings.ps1' -Hardware $hardware
if($amdDecision.Applicable){
try{ & (Resolve-NucPath 'apply_amd_privacy_settings.ps1') -VerifyOnly|Out-Null;Add-Check 'AMD Software 位置權限' $true '已拒絕' }catch{Add-Check 'AMD Software 位置權限' $false $_.Exception.Message}
}else{$checks.Add((New-SetupSkippedCheck -Name 'AMD Software 位置權限' -Reason $amdDecision.Reason));Write-Host ('[略過] '+$amdDecision.Reason)}
Add-SetupStartVerificationCheck -PackageRoot $script:NucPackageRoot
try{ & (Resolve-NucPath 'apply_input_method_settings.ps1') -VerifyOnly|Out-Null;Add-Check '英文美式鍵盤存在且為預設' $true 'en-US、0409:00000409 與預設輸入法均已確認' }catch{Add-Check '英文美式鍵盤存在且為預設' $false $_.Exception.Message}
try{ & (Resolve-NucPath 'apply_terminal_hotkey.ps1') -VerifyOnly|Out-Null;Add-Check 'Terminal 全域快捷鍵' $true 'Ctrl+Alt+T 已註冊，監聽程序執行中' }catch{Add-Check 'Terminal 全域快捷鍵' $false $_.Exception.Message}
$explorer=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\explorer\Advanced'
Add-Check '顯示一般隱藏檔案' ($explorer.Hidden -eq 1 -and $explorer.ShowSuperHidden -eq 0) '一般隱藏檔案顯示；受保護系統檔案隱藏'
try{ & (Resolve-NucPath 'remove_setup_residue.ps1') -VerifyOnly|Out-Null;Add-Check '空資料夾殘留清理' $true '實際資料不會刪除，詳見 Residue-Result.json' }catch{Add-Check '空資料夾殘留清理' $false $_.Exception.Message}
try{ & (Resolve-NucPath 'remove_one_drive.ps1') -VerifyOnly|Out-Null;Add-Check 'OneDrive 解除安裝' $true '程式未安裝且未執行；資料檔保留' }catch{Add-Check 'OneDrive 解除安裝' $false $_.Exception.Message}
try{ & (Resolve-NucPath 'apply_explorer_settings.ps1') -VerifyOnly|Out-Null;Add-Check '檔案總管隱藏檔即時狀態' $true 'Shell 狀態與登錄值均為顯示' }catch{Add-Check '檔案總管隱藏檔即時狀態' $false $_.Exception.Message}
$provisioned=@(Get-AppxProvisionedPackage -Online|Where-Object DisplayName -in $apps|Select-Object -ExpandProperty DisplayName)
Add-Check '新帳號預載 App 清理' ($provisioned.Count -eq 0) ($provisioned -join ', ')
Complete-SetupVerificationResult -Checks $checks -Hardware $hardware -VerificationRunId $VerificationRunId
}
