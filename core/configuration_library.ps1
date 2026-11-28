#Requires -Version 5.1
function Invoke-SetupConfiguration {
 param($Hardware,[string]$UserName,[string]$AutoLogonPassword,[string]$DriverPackagePath,[string]$ConfirmedBoard,[string]$ConfirmationComputer,$DriverChoice,[switch]$NonInteractive)
 $ErrorActionPreference='Stop';$skippedModules=@()
$log=Resolve-NucPath ('Setup-'+(Get-Date -Format yyyyMMdd-HHmmss)+'.log')
. (Resolve-NucPath 'start_pins_policy_library.ps1')
Start-Transcript -Path $log | Out-Null
try {
    # The choice was made before elevation; a missing record is unknown, never a skip.
    if(-not $DriverChoice){$DriverChoice=[pscustomobject]@{Record='未知';Text='[驅動選擇] 結果：未知（沒有可信的選包結果）；驅動包：未知；偵測型號：未知；包支援型號：未知；手動確認型號：未知'}}
    Write-Host $DriverChoice.Text
    Write-Host '[1/19] 管理員免提示與開機自動登入' -ForegroundColor Cyan
    & (Resolve-NucPath 'apply_uac_settings.ps1')
    # Start the progress pane only after the SecureString credential prompt has returned.
    & (Resolve-NucPath 'apply_autologon_settings.ps1') -UserName $UserName -AutoLogonPassword $AutoLogonPassword
    $AutoLogonPassword=$null
    Write-Progress -Id 1 -Activity 'Windows 一鍵設定' -Status '[1/19] 自動登入完成' -PercentComplete 0
    $auto=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $stageErrors=@();$failedModules=@();$startResult=$null
    $stageIndex=1
    foreach($stage in @(
        @{Name='停用磁碟分頁檔';File='apply_pagefile_settings.ps1'},
        @{Name='插電時停用自動睡眠/休眠';File='apply_power_settings.ps1'},
        @{Name='SSH 服務與區域網路防火牆';File='apply_ssh_settings.ps1'},
        @{Name='Windows Update 建議更新';File='install_windows_updates.ps1'},
        @{Name='驅動檢查與更新';File='install_drivers.ps1'},
        @{Name='拒絕 AMD Software 位置存取';File='apply_amd_privacy_settings.ps1'},
        @{Name='Win11Debloat 清理';File='apply_debloat.ps1'},
        @{Name='獨立版 Copilot 清理';File='apply_copilot_settings.ps1'},
        @{Name='工作列天氣/搜尋/Edge 釘選';File='apply_taskbar_settings.ps1'},
        @{Name='清空開始選單釘選及關閉推薦';File='apply_start_menu_settings.ps1'},
        @{Name='1920×1080 與 100% 縮放';File='apply_display_settings.ps1'},
        @{Name='清空一般桌面項目，僅顯示四個系統圖示';File='apply_desktop_settings.ps1'},
        @{Name='深色模式與純黑背景';File='apply_theme_settings.ps1'},
        @{Name='預設英文美式鍵盤';File='apply_input_method_settings.ps1'},
        @{Name='Ctrl+Alt+T 開啟 Terminal';File='apply_terminal_hotkey.ps1'},
        @{Name='顯示隱藏檔案';File='apply_explorer_settings.ps1'},
        @{Name='清除空的舊系統及預設使用者資料夾';File='remove_setup_residue.ps1'},
        @{Name='套用指定桌面圖示排列';File='desktop_icon_layout.ps1'}
    )){
        $stageIndex++
        Write-Host ('['+$stageIndex+'/19] '+$stage.Name) -ForegroundColor Cyan
        Write-Progress -Id 1 -Activity 'Windows 一鍵設定' -Status ('['+$stageIndex+'/19] '+$stage.Name) -PercentComplete ([int](100*($stageIndex-1)/19))
        @{Step=$stageIndex;Total=19;Stage=$stage.Name;UpdatedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content (Resolve-NucPath 'Setup-Progress.json') -Encoding UTF8
        $decision=Get-SetupModuleDecision -Module $stage.File -Hardware $hardware
        if($decision.Status -ceq 'Unknown'){$skippedModules+=$decision;$failedModules+=$stage.File;$stageErrors+=($stage.Name+'：未知（Unknown）：'+$decision.Reason);Write-Host ('[未知] '+$stage.Name+'：'+$decision.Reason) -ForegroundColor Red;continue}
        if(-not $decision.Applicable){$skippedModules+=$decision;Write-Host ('[略過] '+$stage.Name+'：'+$decision.Reason) -ForegroundColor Yellow;continue}
        try { if($stage.File -eq 'install_drivers.ps1'){& (Resolve-NucPath $stage.File) -NonInteractive -DriverPackagePath $DriverPackagePath -ConfirmedBoard $ConfirmedBoard -ConfirmationComputer $ConfirmationComputer}elseif($stage.File -eq 'apply_start_menu_settings.ps1'){$startResult=& (Resolve-NucPath $stage.File) -NonInteractive}else{& (Resolve-NucPath $stage.File)} }
        catch { $failedModules+=$stage.File;$stageErrors+=($stage.Name+'：'+$_.Exception.Message);Write-Warning $stageErrors[-1] }
    }
    $problems=@(Get-PnpDevice -PresentOnly|Where-Object Status -ne 'OK')
    try{ & (Resolve-NucPath 'audit_nuc.ps1') }catch{ $stageErrors+=('最終檢查：'+$_.Exception.Message);Write-Warning $stageErrors[-1] }
    $driverDecision=Get-SetupModuleDecision -Module 'install_drivers.ps1' -Hardware $hardware
    if($DriverPackagePath -and $driverDecision.Applicable){
     try{
      $null=Test-SetupDriverPayload -Hardware $hardware -DriverPackagePath $DriverPackagePath
      . (Resolve-NucPath 'verification_library.ps1')
      $driverSnapshot=Invoke-SetupDriverFreshVerification -DriverPackagePath $DriverPackagePath -VerificationRunId ([guid]::NewGuid().ToString())
      if(-not $driverSnapshot.Success){throw '完整設定後的官方驅動目標尚未全部核對通過。'}
     }catch{$failedModules+='install_drivers.ps1';$stageErrors+=('最終驅動核對：'+$_.Exception.Message);Write-Warning $stageErrors[-1]}
    }
    $pendingModules=@(if($startResult -and -not $startResult.Success){[pscustomobject]@{Module='apply_start_menu_settings.ps1';Status=$startResult.Status}})
    $summary=[ordered]@{Success=($stageErrors.Count -eq 0 -and $problems.Count -eq 0 -and $pendingModules.Count -eq 0);PendingModules=$pendingModules;Computer=$env:COMPUTERNAME;CompletedAt=(Get-Date).ToString('o');AutoLogonUser=$auto.DefaultUserName;AutoLogonEnabled=($auto.AutoAdminLogon -eq '1');RequiresNextSignIn=$true;ProblemDeviceCount=$problems.Count;StageErrors=$stageErrors;FailedModules=$failedModules;HardwareProfile=$hardware;DriverChoice=$DriverChoice.Record;SkippedModules=$skippedModules;UserSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;RebootRequired=((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))}
    $summary|ConvertTo-Json -Depth 5|Set-Content (Resolve-NucPath 'Setup-Result.json') -Encoding UTF8
    try{
        $startResult=Complete-StartPinsPending -Result $startResult -StageErrors $stageErrors -ProblemCount $problems.Count -NonInteractive:$NonInteractive -Apply {param([switch]$ApplyPolicy) & (Resolve-NucPath 'apply_start_menu_settings.ps1') -ApplyPolicy:$ApplyPolicy}
    }catch{$failedModules+='apply_start_menu_settings.ps1';$stageErrors+=('開始選單後置套用：'+$_.Exception.Message);Write-Warning $stageErrors[-1]}
    $pendingModules=@(if($startResult -and -not $startResult.Success){[pscustomobject]@{Module='apply_start_menu_settings.ps1';Status=$startResult.Status}})
    $summary.PendingModules=$pendingModules;$summary.StageErrors=$stageErrors;$summary.FailedModules=$failedModules
    $summary.Success=($stageErrors.Count -eq 0 -and $problems.Count -eq 0 -and $pendingModules.Count -eq 0)
    $summary|ConvertTo-Json -Depth 5|Set-Content (Resolve-NucPath 'Setup-Result.json') -Encoding UTF8
    Write-Progress -Id 1 -Activity 'Windows 一鍵設定' -Completed
    @{Step=19;Total=19;Stage='本輪執行結束';PendingModules=$pendingModules;HasErrors=($stageErrors.Count -gt 0 -or $problems.Count -gt 0);UpdatedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content (Resolve-NucPath 'Setup-Progress.json') -Encoding UTF8

    Write-Host ('目前異常裝置數：'+$problems.Count)
    if($stageErrors.Count -or $problems.Count){throw '部分步驟或裝置檢查未完成，已寫入 Setup-Result.json 與 Setup-Progress.json；請查看紀錄後重試。'}
    elseif($pendingModules.Count){Write-Warning ('本輪仍有待處理項目：'+(($pendingModules|ForEach-Object {$_.Module+' / '+$_.Status}) -join '；'))}
    else{Write-Host '本輪一鍵設定完成。' -ForegroundColor Green}
} finally { $AutoLogonPassword=$null; Stop-Transcript | Out-Null }
}
