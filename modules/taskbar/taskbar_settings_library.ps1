#Requires -Version 5.1
function Invoke-SetupTaskbarNativeAutoHide {
 param([string]$ModuleRoot,[bool]$Apply)
 if(-not ('WindowsSetup.Taskbar' -as [type])){Add-Type -Path (Join-Path $ModuleRoot 'native/taskbar.cs') -ErrorAction Stop}
 return [WindowsSetup.Taskbar]::AutoHide($Apply,$null)
}
function Get-SetupTaskbarPersistedAutoHide {
 # StuckRects3 Settings 第 9 個位元組：位元 0 = 自動隱藏（0x02 顯示、0x03 隱藏）。讀不到回 $false。
 $value=(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3' -Name Settings -ErrorAction SilentlyContinue).Settings
 if($null -eq $value -or @($value).Count -lt 9){return $false}
 return (([byte]@($value)[8]) -band 1) -eq 1
}
function Set-SetupTaskbarPersistedAutoHide {
 $path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
 $value=(Get-ItemProperty $path -Name Settings -ErrorAction SilentlyContinue).Settings
 if($null -eq $value -or @($value).Count -lt 9){return $false}
 [byte[]]$bytes=@($value);$bytes[8]=[byte]($bytes[8] -bor 1)
 Set-ItemProperty $path -Name Settings -Value $bytes -Type Binary -ErrorAction Stop
 return $true
}
function Invoke-SetupTaskbarAutoHide {
 param([string]$ModuleRoot=$PSScriptRoot,[switch]$VerifyOnly)
 $state=Invoke-SetupTaskbarNativeAutoHide -ModuleRoot $ModuleRoot -Apply:(-not $VerifyOnly)
 $running=($state -band 1) -eq 1
 if(-not $VerifyOnly -and -not $running){throw '工作列自動隱藏寫後讀回失敗。'}
 $persisted=[bool](Get-SetupTaskbarPersistedAutoHide)
 if(-not $VerifyOnly -and -not $persisted){
  # ABM_SETSTATE 只改執行中的工作列，重開或 Explorer 重啟會回到登錄值，必須同時寫入 StuckRects3 並讀回。
  # 全新設定檔可能尚無 StuckRects3：不擲錯中斷整個階段，如實回報未持久化（AutoHide=false），其餘設定照常套用並由彙總標為失敗。
  $wrote=Set-SetupTaskbarPersistedAutoHide
  if($false -ne $wrote){
   $persisted=[bool](Get-SetupTaskbarPersistedAutoHide)
   if(-not $persisted){throw '工作列自動隱藏未持久化：StuckRects3 寫後讀回失敗。'}
  }
 }
 return [pscustomobject]@{AutoHide=($running -and $persisted);PersistedAutoHide=$persisted;AppBarState=$state}
}
function Test-SetupTaskbarLayout {
 param([string]$LayoutPath)
 if(-not(Test-Path -LiteralPath $LayoutPath -PathType Leaf)){return $false}
 $settings=New-Object Xml.XmlReaderSettings;$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
 $reader=[Xml.XmlReader]::Create($LayoutPath,$settings)
 try{$xml=New-Object Xml.XmlDocument;$xml.XmlResolver=$null;$xml.Load($reader)}finally{$reader.Dispose()}
 $pins=@($xml.SelectNodes('//*[local-name()="TaskbarPinList"]/*'));$collections=@($xml.SelectNodes('//*[local-name()="CustomTaskbarLayoutCollection"]'))
 return ($pins.Count -eq 1 -and $pins[0].LocalName -ceq 'DesktopApp' -and $pins[0].DesktopApplicationID -ceq 'MSEdge' -and $collections.Count -eq 1 -and $collections[0].PinListPlacement -ceq 'Replace')
}
function Test-SetupTaskbarAccessDenied {
 param($Exception)
 for($e=$Exception;$null -ne $e;$e=$e.InnerException){if($e -is [UnauthorizedAccessException] -or $e -is [Security.SecurityException]){return $true}}
 return $false
}
function Initialize-SetupTaskbarRegistryKey {
 # 只建立缺少的機碼：Registry provider 對既有機碼 New-Item -Force 會清掉其他值。失敗訊息指出機碼與準備寫入的值。
 param([Parameter(Mandatory=$true)][string]$Path,[string]$ForValue)
 $ErrorActionPreference='Stop'
 if(Test-Path $Path){return}
 $target=if($ForValue){'（準備寫入 '+$ForValue+'）'}else{''}
 try{New-Item $Path -Force|Out-Null}catch{throw (New-Object InvalidOperationException ('無法建立登錄機碼 '+$Path+$target+'：'+$_.Exception.Message),$_.Exception)}
}
function Set-SetupTaskbarRegistryValue {
 # 重跑冪等：讀回已是目標值與型別就不重寫，避免受保護的值（例如 User Choice Protection）擋下重複寫入。
 # 寫入失敗時訊息指出機碼與值名稱並保留原始例外；不帶出資料值（版面路徑含設定檔目錄）。
 param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Name,[Parameter(Mandatory=$true)]$Value,[Parameter(Mandatory=$true)][ValidateSet('DWord','String')][string]$PropertyType)
 $ErrorActionPreference='Stop'
 $current=(Get-ItemProperty $Path -ErrorAction SilentlyContinue).$Name
 $same=if($PropertyType -ceq 'DWord'){$current -is [int] -and $current -eq [int]$Value}else{$current -is [string] -and $current -ceq [string]$Value}
 if($same){return 'Unchanged'}
 try{New-ItemProperty $Path -Name $Name -Value $Value -PropertyType $PropertyType -Force|Out-Null}catch{throw (New-Object InvalidOperationException ('登錄寫入失敗：'+$Path+'\'+$Name+'：'+$_.Exception.Message),$_.Exception)}
 return 'Written'
}
function Invoke-SetupTaskbarSettings {
 param([Parameter(Mandatory=$true)][string]$OutputRoot,[Parameter(Mandatory=$true)][string]$LayoutPath,[switch]$VerifyOnly,[string]$ExpectedFinalizeCommand,[switch]$PendingFinalizeTask)
 $autoHide=Invoke-SetupTaskbarAutoHide -VerifyOnly:$VerifyOnly
 if(-not $VerifyOnly){
  Export-SetupTaskbarBackup -Path (Join-Path $OutputRoot ('Taskbar-Before-'+(Get-Date -Format yyyyMMdd-HHmmss)+'.reg'))
$search='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
$advanced='HKCU:\Software\Microsoft\Windows\CurrentVersion\explorer\Advanced'
Initialize-SetupTaskbarRegistryKey -Path $search
$searchPolicy='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
Initialize-SetupTaskbarRegistryKey -Path $searchPolicy -ForValue SearchOnTaskbarMode
Set-SetupTaskbarRegistryValue -Path $searchPolicy -Name SearchOnTaskbarMode -Value 0 -PropertyType DWord|Out-Null
try{Set-SetupTaskbarRegistryValue -Path $advanced -Name TaskbarDa -Value 0 -PropertyType DWord|Out-Null}catch{Write-Warning ('個人小工具開關受保護（'+$advanced+'\TaskbarDa），將以機器原則關閉小工具：'+$_.Exception.Message)}
try{Set-SetupTaskbarRegistryValue -Path $advanced -Name ShowTaskViewButton -Value 0 -PropertyType DWord|Out-Null}catch{
 # 系統保護（例如 User Choice Protection）擋下個人值時改用官方機器原則 HideTaskViewButton（Taskbar.admx，class=Both）；其他錯誤照常失敗。
 if(-not(Test-SetupTaskbarAccessDenied $_.Exception)){throw}
 $machineExplorer='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
 Write-Warning ('工作檢視按鈕個人開關受保護（'+$advanced+'\ShowTaskViewButton），改以 HKLM 機器原則 '+$machineExplorer+'\HideTaskViewButton=1 隱藏；此原則對這臺電腦的所有使用者生效：'+$_.Exception.Message)
 Initialize-SetupTaskbarRegistryKey -Path $machineExplorer -ForValue HideTaskViewButton
 Set-SetupTaskbarRegistryValue -Path $machineExplorer -Name HideTaskViewButton -Value 1 -PropertyType DWord|Out-Null
}
$widgets='HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
Initialize-SetupTaskbarRegistryKey -Path $widgets -ForValue AllowNewsAndInterests
Set-SetupTaskbarRegistryValue -Path $widgets -Name AllowNewsAndInterests -Value 0 -PropertyType DWord|Out-Null

$xml=@"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
        <taskbar:DesktopApp DesktopApplicationID="MSEdge" />
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@
[xml]$validated=$xml
[IO.File]::WriteAllText($layoutPath,$xml,[Text.UTF8Encoding]::new($false))
$policy='HKCU:\Software\Policies\Microsoft\Windows\Explorer'
Initialize-SetupTaskbarRegistryKey -Path $policy -ForValue StartLayoutFile
Set-SetupTaskbarRegistryValue -Path $policy -Name StartLayoutFile -Value $layoutPath -PropertyType String|Out-Null
Set-SetupTaskbarRegistryValue -Path $policy -Name LockedStartLayout -Value 1 -PropertyType DWord|Out-Null

 }
 $searchPolicy='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';$advanced='HKCU:\Software\Microsoft\Windows\CurrentVersion\explorer\Advanced';$widgets='HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
 $search=(Get-ItemProperty $searchPolicy -ErrorAction SilentlyContinue).SearchOnTaskbarMode
 $advancedValues=Get-ItemProperty $advanced -ErrorAction SilentlyContinue
 $widgetsValue=(Get-ItemProperty $widgets -ErrorAction SilentlyContinue).AllowNewsAndInterests
 $taskViewPolicy=(Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -ErrorAction SilentlyContinue).HideTaskViewButton
 $taskViewSource=if($advancedValues.ShowTaskViewButton -eq 0){'UserPreference'}elseif($taskViewPolicy -eq 1){'MachinePolicy'}else{'None'}
 $policy=Get-ItemProperty 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -ErrorAction SilentlyContinue
 $runOnce=(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -ErrorAction SilentlyContinue).NUC8FinalizeTaskbar
 $pending=($PendingFinalizeTask -or $null -ne $runOnce -or $null -ne $policy.StartLayoutFile -or $null -ne $policy.LockedStartLayout)
 $layoutOK=Test-SetupTaskbarLayout $LayoutPath
 $bindingOK=($null -eq $policy.StartLayoutFile -or $policy.StartLayoutFile -ceq $LayoutPath) -and ($null -eq $runOnce -or ($ExpectedFinalizeCommand -and $runOnce -ceq $ExpectedFinalizeCommand))
 $configured=($autoHide.AutoHide -and $search -eq 0 -and $taskViewSource -cne 'None' -and $widgetsValue -eq 0 -and $layoutOK)
 $applyBinding=($policy.StartLayoutFile -ceq $LayoutPath -and $policy.LockedStartLayout -eq 1)
 $success=if($VerifyOnly){$configured -and $bindingOK -and -not $pending}else{$configured -and $applyBinding}
 [pscustomobject]@{Success=[bool]$success;Status=$(if(-not $success -and -not $VerifyOnly){'Failed'}elseif(-not $VerifyOnly){'Applied'}elseif($success){'Confirmed'}elseif($configured -and $bindingOK -and $pending){'PendingSignIn'}else{'Failed'});BindingMatches=[bool]$(if($VerifyOnly){$bindingOK}else{$applyBinding});Configured=[bool]$configured;AutoHide=$autoHide.AutoHide;PersistedAutoHide=$autoHide.PersistedAutoHide;AppBarState=$autoHide.AppBarState;SearchPolicyMode=$search;TaskbarDa=$advancedValues.TaskbarDa;WidgetsPolicy=$widgetsValue;ShowTaskViewButton=$advancedValues.ShowTaskViewButton;TaskViewPolicy=$taskViewPolicy;TaskViewButtonSource=$taskViewSource;TaskbarLayout=$LayoutPath;PinnedDesktopApp='MSEdge';RequiresNextSignIn=[bool]$(if($VerifyOnly){$pending}else{$true});Error=$(if(-not $success){'工作列設定尚未完成或暫時政策與本輪配置不符。'}else{''});CheckedAt=(Get-Date).ToString('o')}
}
function Invoke-SetupTaskbarFinalize {
 param([Parameter(Mandatory=$true)][string]$LayoutPath)
 Start-Sleep -Seconds 45
 $policy='HKCU:\Software\Policies\Microsoft\Windows\Explorer'
 $current=Get-ItemProperty $policy -ErrorAction SilentlyContinue
 if($current.StartLayoutFile -cne $LayoutPath){return [pscustomobject]@{Success=$false;Status='Obsolete';TemporaryLayoutPolicyRemoved=$false;Error='工作列政策已屬於其他配置，未解除。'}}
 Remove-ItemProperty $policy -Name LockedStartLayout -ErrorAction SilentlyContinue
 Remove-ItemProperty $policy -Name StartLayoutFile -ErrorAction SilentlyContinue
 $after=Get-ItemProperty $policy -ErrorAction SilentlyContinue
 if($null -ne $after.StartLayoutFile -or $null -ne $after.LockedStartLayout){return [pscustomobject]@{Success=$false;Status='Failed';TemporaryLayoutPolicyRemoved=$false;Error='工作列暫時政策讀回仍存在，未完成解除。'}}
 [pscustomobject]@{Success=$true;Status='Finalized';TemporaryLayoutPolicyRemoved=$true;FinalizedAt=(Get-Date).ToString('o')}
}

