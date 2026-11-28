#Requires -Version 5.1
# 重跑現場重放（#485）：fixture 取自 issue 的實機唯讀讀回，說明見 fixtures/nuc_scene_taskbar_rerun/readme.md。
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Name}}
. (Join-Path $root 'modules/taskbar/taskbar_settings_library.ps1')
$scene=Get-Content -LiteralPath (Join-Path $root 'test/powershell/fixtures/nuc_scene_taskbar_rerun/rerun_registry_state.json') -Raw -Encoding UTF8|ConvertFrom-Json
$advanced='HKCU:\Software\Microsoft\Windows\CurrentVersion\explorer\Advanced'
$userPolicy='HKCU:\Software\Policies\Microsoft\Windows\Explorer'
$searchPolicy='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
$widgets='HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
$machineExplorer='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
$sceneKey=@{};foreach($k in $scene.Keys){$sceneKey[$k.Path]=$k}
Assert ($scene.IntegrityLevel -ceq 'High' -and $sceneKey[$advanced].Values.ShowTaskViewButton -eq 0 -and 'TaskbarDa' -in @($sceneKey[$advanced].Absent)) 'fixture：ShowTaskViewButton=0 已存在、TaskbarDa 不存在（實機讀回）'
Assert ($sceneKey[$userPolicy].Acl.CurrentUser -ceq 'ReadKey' -and $sceneKey[$userPolicy].Acl.Administrators -ceq 'FullControl' -and @($sceneKey[$userPolicy].Absent).Count -eq 2) 'fixture：使用者政策機碼使用者本人只有 ReadKey、Administrators 為 FullControl，且無 StartLayoutFile／LockedStartLayout'
Assert ($sceneKey[$searchPolicy].Values.SearchOnTaskbarMode -eq 0 -and $sceneKey[$widgets].Values.AllowNewsAndInterests -eq 0) 'fixture：搜尋與小工具機器原則值都已是 0'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('taskbar_rerun_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temp)
$layout=Join-Path $temp 'TaskbarLayout.xml'
function Reset-Scene {
 $script:reg=@{};foreach($k in $scene.Keys){$v=@{};foreach($p in $k.Values.PSObject.Properties){$v[$p.Name]=$p.Value};$script:reg[$k.Path]=$v}
 $script:deny=@{};foreach($d in $scene.ObservedDenials){$script:deny[$d.Path+'|'+$d.Name]=$d.Message}
 $script:denyKeys=@{};$script:attempts=@();$script:failOther=@{}
}
function Test-Path {param($Path,$LiteralPath,$PathType,$ErrorAction) $p=if($LiteralPath){$LiteralPath}else{$Path};if($p -like 'HK*'){return $script:reg.ContainsKey($p)};Microsoft.PowerShell.Management\Test-Path @PSBoundParameters}
function New-Item {param($Path,[switch]$Force,$ErrorAction) if($Path -notlike 'HK*'){throw 'no real key creation'};if($script:denyKeys.ContainsKey($Path)){throw [UnauthorizedAccessException]::new($scene.UnattributedDenialMessage)};$script:reg[$Path]=@{}}
function New-ItemProperty {param($Path,$Name,$Value,$PropertyType,[switch]$Force,$ErrorAction) if($Path -notlike 'HK*' -or -not $Force){throw 'unexpected registry write'};$script:attempts+=@($Path+'|'+$Name);if($script:deny.ContainsKey($Path+'|'+$Name)){throw [UnauthorizedAccessException]::new($script:deny[$Path+'|'+$Name])};if($script:failOther.ContainsKey($Path+'|'+$Name)){throw [IO.IOException]::new($script:failOther[$Path+'|'+$Name])};if(-not $script:reg.ContainsKey($Path)){throw 'fixture key missing'};$script:reg[$Path][$Name]=$Value}
function Get-ItemProperty {param($Path,$LiteralPath,$Name,$ErrorAction) $p=if($LiteralPath){$LiteralPath}else{$Path};if($script:reg.ContainsKey($p)){return [pscustomobject]$script:reg[$p]};return $null}
function Export-SetupTaskbarBackup {param($Path) if(-not $Path.StartsWith($temp)){throw 'backup outside TEMP'}}
function Invoke-SetupTaskbarNativeAutoHide {param($ModuleRoot,[bool]$Apply) return [uint32]1}
function Get-SetupTaskbarPersistedAutoHide {return $true}
function Set-SetupTaskbarPersistedAutoHide {}
function Get-ExceptionChain($e){$list=@();while($null -ne $e){$list+=@($e);$e=$e.InnerException};$list}
try{
 Assert (@($scene.ObservedDenials|Where-Object{$_.Path -ceq $widgets -and $_.Name -ceq 'AllowNewsAndInterests' -and $_.ConfirmedOnDevice}).Count -eq 1) 'fixture：實機確認被拒的是 Dsh\AllowNewsAndInterests（值已是 0，寫入相同值仍被拒）'
 # 1. 現場重放：實機確認的 TaskbarDa 與 AllowNewsAndInterests 都被拒，重跑必須通過，且不重寫已是目標值的項目，以讀回值判定。
 Reset-Scene
 $r=Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout -WarningVariable warn -WarningAction SilentlyContinue
 Assert ($r.Success -and $r.Status -ceq 'Applied' -and $r.WidgetsPolicy -eq 0) '現場重跑（TaskbarDa 與 AllowNewsAndInterests 受保護）仍為 Applied，小工具原則以讀回值 0 判定'
 Assert (@($script:attempts|Where-Object{$_ -in @("$advanced|ShowTaskViewButton","$searchPolicy|SearchOnTaskbarMode","$widgets|AllowNewsAndInterests")}).Count -eq 0) '已是目標值的 ShowTaskViewButton／SearchOnTaskbarMode／AllowNewsAndInterests 不重寫'
 Assert (@($warn|Where-Object{"$_".Contains($advanced) -and "$_".Contains('TaskbarDa')}).Count -eq 1) 'TaskbarDa 受保護警告指出機碼與值名稱'
 # 1b. 實機被拒的值若尚非目標值：如實失敗並指出 Dsh 機碼與 AllowNewsAndInterests，不吞掉寫入失敗。
 Reset-Scene;$script:reg[$widgets].AllowNewsAndInterests=1
 $err=$null;try{Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout -WarningAction SilentlyContinue|Out-Null}catch{$err=$_}
 Assert ($null -ne $err -and $err.Exception.Message.Contains($widgets) -and $err.Exception.Message.Contains('AllowNewsAndInterests') -and @(Get-ExceptionChain $err.Exception|Where-Object{$_ -is [UnauthorizedAccessException]}).Count -ge 1) 'AllowNewsAndInterests 非 0 又寫不進去時如實失敗，指出機碼與值並保留未經授權原因'
 # 2. 已是目標值的候選即使被系統保護（例如 User Choice Protection 擋下寫入），重跑也不受影響。
 foreach($c in @(@($advanced,'ShowTaskViewButton'),@($searchPolicy,'SearchOnTaskbarMode'),@($widgets,'AllowNewsAndInterests'))){
  Reset-Scene;$script:deny[$c[0]+'|'+$c[1]]=$scene.UnattributedDenialMessage
  $r=$null;$err=$null;try{$r=Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout -WarningAction SilentlyContinue}catch{$err=$_}
  Assert ($null -eq $err -and $r.Success -and $r.Status -ceq 'Applied' -and ($c[0]+'|'+$c[1]) -notin $script:attempts) ('重跑時已是目標值且受保護的 '+$c[1]+' 不寫入，模組通過：'+$(if($err){$err.Exception.Message}else{''}))
 }
 # 3. 重跑必須寫入的暫時版面政策被拒：如實失敗，訊息指出機碼與值名稱，保留未經授權原因，不帶出含設定檔路徑的資料值。
 foreach($name in @('StartLayoutFile','LockedStartLayout')){
  Reset-Scene;$script:deny[$userPolicy+'|'+$name]=$scene.UnattributedDenialMessage
  $err=$null;try{Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout -WarningAction SilentlyContinue|Out-Null}catch{$err=$_}
  $msg=if($err){$err.Exception.Message}else{''}
  Assert ($null -ne $err) ('暫時版面政策 '+$name+' 被拒時不得回報通過')
  Assert ($msg.Contains($userPolicy) -and $msg.Contains($name) -and -not $msg.Contains($temp)) ('寫入被拒訊息指出機碼與值名稱，且不含資料值：'+$msg)
  Assert (@(Get-ExceptionChain $err.Exception|Where-Object{$_ -is [UnauthorizedAccessException]}).Count -ge 1) ('寫入被拒保留未經授權的原始例外：'+$name)
 }
 # 4. ShowTaskViewButton 尚非目標值且被保護：改用機器原則 HideTaskViewButton，讀回機器原則才算通過並如實回報來源。
 Reset-Scene;$script:reg[$advanced].ShowTaskViewButton=1;$script:deny["$advanced|ShowTaskViewButton"]=$scene.UnattributedDenialMessage
 $r=Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout -WarningVariable warn -WarningAction SilentlyContinue
 Assert ($r.Success -and $script:reg[$machineExplorer].HideTaskViewButton -eq 1 -and $r.TaskViewPolicy -eq 1 -and $r.TaskViewButtonSource -ceq 'MachinePolicy' -and $r.ShowTaskViewButton -eq 1) '受保護的工作檢視按鈕改以機器原則隱藏，讀回後通過並回報來源'
 Assert (@($warn|Where-Object{"$_".Contains($advanced) -and "$_".Contains('ShowTaskViewButton')}).Count -eq 1) '工作檢視按鈕受保護警告指出機碼與值名稱'
 Assert (@($warn|Where-Object{"$_".Contains($machineExplorer+'\HideTaskViewButton') -and "$_".Contains('所有使用者')}).Count -eq 1) '改用機器原則的警告說明 HKLM HideTaskViewButton 對這臺電腦所有使用者生效'
 $script:reg[$userPolicy].Remove('StartLayoutFile');$script:reg[$userPolicy].Remove('LockedStartLayout');$before=$script:attempts.Count
 $v=Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout -VerifyOnly
 Assert ($v.Success -and $v.Status -ceq 'Confirmed' -and $v.TaskViewButtonSource -ceq 'MachinePolicy' -and $script:attempts.Count -eq $before) 'VerifyOnly 以同一讀回條件確認機器原則，且不寫入'
 $script:reg[$machineExplorer].Remove('HideTaskViewButton')
 $v=Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout -VerifyOnly
 Assert (-not $v.Success -and $v.TaskViewButtonSource -ceq 'None') '使用者值與機器原則都未隱藏時，VerifyOnly 不得通過'
 # 5. 替代機器原則也被拒：如實失敗並指出替代機碼與值名稱。
 Reset-Scene;$script:reg[$advanced].ShowTaskViewButton=1;$script:deny["$advanced|ShowTaskViewButton"]=$scene.UnattributedDenialMessage;$script:deny["$machineExplorer|HideTaskViewButton"]=$scene.UnattributedDenialMessage
 $err=$null;try{Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout -WarningAction SilentlyContinue|Out-Null}catch{$err=$_}
 Assert ($null -ne $err -and $err.Exception.Message.Contains($machineExplorer) -and $err.Exception.Message.Contains('HideTaskViewButton')) '替代機器原則也被拒時如實失敗並指出機碼與值名稱'
 # 5b. 工作檢視按鈕寫入的錯誤不是未經授權（例如 I/O 錯誤）：照常失敗，不改用機器原則。
 Reset-Scene;$script:reg[$advanced].ShowTaskViewButton=1;$script:failOther["$advanced|ShowTaskViewButton"]='fixture I/O failure'
 $err=$null;try{Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout -WarningAction SilentlyContinue|Out-Null}catch{$err=$_}
 Assert ($null -ne $err -and $err.Exception.Message.Contains($advanced) -and $err.Exception.Message.Contains('ShowTaskViewButton') -and "$machineExplorer|HideTaskViewButton" -notin $script:attempts -and -not $script:reg.ContainsKey($machineExplorer)) '工作檢視按鈕非未經授權的錯誤照常失敗，不改寫 HideTaskViewButton 機器原則'
 # 5c. 原值型別不符（REG_SZ "0"）不算已是目標值：必須以 DWord 改寫並讀回。
 Reset-Scene;$script:reg[$advanced].ShowTaskViewButton='0'
 $r=Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout -WarningAction SilentlyContinue
 Assert ("$advanced|ShowTaskViewButton" -in $script:attempts -and $script:reg[$advanced].ShowTaskViewButton -is [int] -and $script:reg[$advanced].ShowTaskViewButton -eq 0 -and $r.Success) '原值為 REG_SZ "0" 時不視為已是目標值，改寫為 DWord 0'
 # 6. 缺少的機碼建立被拒：訊息指出機碼與準備寫入的值名稱。
 Reset-Scene;$script:reg.Remove($widgets);$script:denyKeys[$widgets]=$true
 $err=$null;try{Invoke-SetupTaskbarSettings -OutputRoot $temp -LayoutPath $layout -WarningAction SilentlyContinue|Out-Null}catch{$err=$_}
 Assert ($null -ne $err -and $err.Exception.Message.Contains($widgets) -and $err.Exception.Message.Contains('AllowNewsAndInterests')) '建立機碼被拒時訊息指出機碼與值名稱'
}finally{Microsoft.PowerShell.Management\Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
