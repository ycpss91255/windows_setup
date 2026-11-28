#Requires -Version 5.1
# Definitions only: no users, setup files or provisioning are changed when loaded.
. (Join-Path $PSScriptRoot 'oobe_library.ps1')
. (Join-Path $PSScriptRoot 'provisioning_library.ps1')
function Get-SetupInitNativeIdentity {
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 $principal=New-Object Security.Principal.WindowsPrincipal($identity)
 return [pscustomobject]@{Sid=$identity.User.Value;UserSID=$identity.User;IsAdministrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;Is64Bit=[Environment]::Is64BitProcess;Architecture=$env:PROCESSOR_ARCHITECTURE}
}
function Get-SetupInitContext {
 $context=Get-SetupInitNativeIdentity
 $imageState=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction SilentlyContinue).ImageState
 $desktopOwned=$false
 if($context.Sid -ne 'S-1-5-18'){
  $explorers=@(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop|Where-Object {$_.SessionId -eq $context.SessionId})
  foreach($process in $explorers){$owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop;if(($owner.ReturnValue -is [uint32] -or $owner.ReturnValue -is [int]) -and $owner.ReturnValue -eq 0 -and $owner.Sid -eq $context.Sid){$desktopOwned=$true}}
 }
 $context|Add-Member NoteProperty ImageState $imageState -Force
 $context|Add-Member NoteProperty DesktopOwned $desktopOwned -Force
 $context|Add-Member NoteProperty ModeFacts (Get-SetupInitPreparationFacts -Identity $context) -Force
 return $context
}
function Get-SetupInitPreparationFacts {
 param($Identity)
 try{
  $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
  $setup=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
  $completion=Invoke-InitOobeCompleteNative
  $profile=Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$Identity.Sid) -ErrorAction Stop
  $registered=[Environment]::ExpandEnvironmentVariables([string]$profile.ProfileImagePath)
  $nativeProfile=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile,[Environment+SpecialFolderOption]::DoNotVerify)
  $profileMatches=($registered -and $nativeProfile -and [IO.Path]::GetFullPath($registered).TrimEnd('\') -ieq [IO.Path]::GetFullPath($nativeProfile).TrimEnd('\'))
  $processes=@(Get-CimInstance Win32_Process -Filter "Name='msoobe.exe' OR Name='CloudExperienceHostBroker.exe' OR Name='CloudExperienceHostApp.exe' OR Name='oobenetworkconnectionflow.exe' OR Name='setup.exe' OR Name='setuphost.exe' OR Name='setupprep.exe' OR Name='sysprep.exe'" -ErrorAction Stop|Where-Object SessionId -eq $Identity.SessionId)
  $oobeNames=[string[]]@($processes|Where-Object {$_.Name -in @('msoobe.exe','CloudExperienceHostBroker.exe','CloudExperienceHostApp.exe','oobenetworkconnectionflow.exe')}|ForEach-Object {[string]$_.Name}|Sort-Object -Unique)
  $setupNames=[string[]]@($processes|Where-Object {$_.Name -in @('setup.exe','setuphost.exe','setupprep.exe','sysprep.exe')}|ForEach-Object {[string]$_.Name}|Sort-Object -Unique)
  $sysprepIds=[int[]]@($processes|Where-Object {$_.Name -eq 'sysprep.exe' -and $null -ne $_.ProcessId}|ForEach-Object {[int]$_.ProcessId}|Where-Object {$_ -gt 0})
  $oobe=$oobeNames.Count -gt 0
  $setupBusy=$setupNames.Count -gt 0
  $localBuiltin=$false
  if($Identity.Sid -match '-500$'){$user=Get-LocalUser -SID $Identity.UserSID -ErrorAction Stop;$localBuiltin=([string]$user.SID -eq $Identity.Sid)}
  return @{ReadSucceeded=$true;Build=[int]$os.BuildNumber;ProductType=[int]$os.ProductType;IsWinPE=[bool](Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT' -ErrorAction Stop);OobeApiSucceeded=$completion.Succeeded;OobeComplete=$completion.Complete;SetupInProgress=$setup.SystemSetupInProgress;OobeInProgress=$setup.OOBEInProgress;OobeProcessInSession=$oobe;SetupProcessInSession=$setupBusy;OobeProcessNames=$oobeNames;SetupProcessNames=$setupNames;SysprepProcessIds=$sysprepIds;ProfileMatches=[bool]$profileMatches;LocalBuiltin=[bool]$localBuiltin}
 }catch{return @{ReadSucceeded=$false}}
}
# Asks the Audit-mode Sysprep dialog window to close (same as Cancel); never force-kills a process that may be working.
function Close-SetupInitSysprepDialog {
 param([int[]]$ProcessIds)
 if(-not $ProcessIds -or $ProcessIds.Count -eq 0){return $false}
 foreach($id in $ProcessIds){
  try{$process=[Diagnostics.Process]::GetProcessById($id)}catch{continue}
  try{
   if($process.ProcessName -ine 'sysprep' -or $process.MainWindowHandle -eq [IntPtr]::Zero){return $false}
   if(-not $process.CloseMainWindow()){return $false}
   if(-not $process.WaitForExit(15000)){return $false}
  }catch{return $false}finally{$process.Dispose()}
 }
 return $true
}
# Local record of a rejected Init state for the next diagnosis: no SID, user name or password; kept under ProgramData, never on the USB kit.
function Write-SetupInitRejectRecord {
 param([string]$Root,$Context,[string]$Route,[string[]]$Reasons,[int]$Rechecks,[bool]$SysprepDialogClosed)
 try{
  if(-not $Root){return $null}
  $directory=Join-Path $Root 'windows_setup_init_diagnostics'
  [void][IO.Directory]::CreateDirectory($directory)
  $facts=[ordered]@{}
  $source=$Context.ModeFacts
  if($source -is [Collections.IDictionary]){foreach($key in @($source.Keys|ForEach-Object {[string]$_}|Sort-Object)){$facts[$key]=$source[$key]}}
  elseif($null -ne $source){foreach($property in $source.PSObject.Properties){$facts[$property.Name]=$property.Value}}
  $now=[DateTime]::UtcNow
  $record=[ordered]@{Schema=1;TimeUtc=$now.ToString('o');Route=$Route;ImageState=[string]$Context.ImageState;IsAdministrator=[bool]$Context.IsAdministrator;BuiltinAdministrator=([string]$Context.Sid -match '-500$');DesktopOwned=[bool]$Context.DesktopOwned;Rechecks=$Rechecks;SysprepDialogClosed=$SysprepDialogClosed;Reasons=@($Reasons);ModeFacts=$facts}
  $path=Join-Path $directory ('init_reject_'+$now.ToString('yyyyMMddTHHmmssfff')+'Z.json')
  [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $record -Depth 5),(New-Object Text.UTF8Encoding($false)))
  foreach($old in @(Get-ChildItem -LiteralPath $directory -Filter 'init_reject_*.json' -File|Sort-Object Name -Descending|Select-Object -Skip 20)){Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue}
  return $path
 }catch{return $null}
}
function Format-SetupInitRecordNote([string]$Path){
 if($Path){return '診斷紀錄：'+$Path}
 return '診斷紀錄未能寫入。'
}
function Test-SetupInitInteractiveHost {
 try {return [Environment]::UserInteractive -and $Host.Name -ceq 'ConsoleHost' -and -not [Console]::IsInputRedirected} catch {return $false}
}
function Request-SetupInitConsent {
 if(-not (Test-SetupInitInteractiveHost)){return $false}
 try {$answer=Read-Host '是否準備新本機帳號與 OOBE？將建立受保護的 answer file 並執行 Sysprep /oobe /quit，不自動重開；Y/YES 或 Enter 同意（預設 Enter 同意），N 拒絕'} catch {return $false}
 if($answer -isnot [string]){return $false}
 return ($answer -ceq '' -or $answer -ieq 'y' -or $answer -ieq 'yes')
}
function Invoke-SetupInit {
 param([Parameter(Mandatory=$true)][string]$EntryPath,[Parameter(Mandatory=$true)][string]$ModuleRoot,[string]$SshScriptPath,[string]$ExpectedUserSID,[string]$ResumeStatePath)
if($SshScriptPath){$SshScriptPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SshScriptPath)}


$sourceRoot=[IO.Path]::GetFullPath((Join-Path $ModuleRoot '..\..'))
$stageRoot=Join-Path $env:ProgramData 'windows_setup_init'
if(Invoke-InitProvisioningEntry -SourceRoot $sourceRoot -StageRoot $stageRoot -ResumeStatePath $ResumeStatePath -ExpectedUserSID $ExpectedUserSID){return}
$context=Get-SetupInitContext
$sid=$context.Sid
if($ExpectedUserSID -and $ExpectedUserSID -ne $sid){throw '提權後帳號已改變，請使用原帳號的管理員權限。'}
$admin=$context.IsAdministrator;$imageState=$context.ImageState;$desktopOwned=$context.DesktopOwned
$route=Get-InitRoute -Sid $sid -ImageState $imageState -IsAdministrator $admin -DesktopOwned $desktopOwned -ModeFacts $context.ModeFacts
$sysprepClosed=$false;$rechecks=0;$recheckLimit=6;$recheckSeconds=5
while($route -eq 'RejectUnknownSetupState'){
 if(-not $sysprepClosed -and (Test-InitSysprepDialogOnlyBlocker -Sid $sid -ImageState $imageState -IsAdministrator $admin -DesktopOwned $desktopOwned -ModeFacts $context.ModeFacts)){
  if(-not (Close-SetupInitSysprepDialog -ProcessIds $context.ModeFacts.SysprepProcessIds)){
   $record=Write-SetupInitRejectRecord -Root $env:ProgramData -Context $context -Route $route -Reasons (Get-InitRouteRejectReasons -Sid $sid -ImageState $imageState -IsAdministrator $admin -DesktopOwned $desktopOwned -ModeFacts $context.ModeFacts) -Rechecks $rechecks -SysprepDialogClosed $false
   throw ('稽核模式自動開啟的 Sysprep（系統準備工具）對話框無法自動關閉，未變更設定。請在該視窗按「取消」關閉後，再重跑 init.cmd。'+(Format-SetupInitRecordNote $record))
  }
  Write-Host '已關閉稽核模式自動開啟的 Sysprep（系統準備工具）對話框，重新確認狀態。'
  $sysprepClosed=$true
 }elseif($rechecks -lt $recheckLimit -and (Test-InitTransientSetupBlocker -Sid $sid -ImageState $imageState -IsAdministrator $admin -DesktopOwned $desktopOwned -ModeFacts $context.ModeFacts)){
  if($rechecks -eq 0){Write-Host ('同一工作階段仍有安裝或 OOBE 程序，可能是開機初期仍在收尾；每 '+$recheckSeconds+' 秒重新檢查，最多 '+$recheckLimit+' 次。')}
  Start-Sleep -Seconds $recheckSeconds
  $rechecks++
 }else{break}
 $context=Get-SetupInitContext
 $sid=$context.Sid
 if($ExpectedUserSID -and $ExpectedUserSID -ne $sid){throw '提權後帳號已改變，請使用原帳號的管理員權限。'}
 $admin=$context.IsAdministrator;$imageState=$context.ImageState;$desktopOwned=$context.DesktopOwned
 $route=Get-InitRoute -Sid $sid -ImageState $imageState -IsAdministrator $admin -DesktopOwned $desktopOwned -ModeFacts $context.ModeFacts
}
Write-Host ('=== Init：Windows '+[Environment]::OSVersion.Version+'；階段 '+$route+' ===') -ForegroundColor Cyan
if($route -eq 'ElevationRequired'){
 Write-Host '請允許目前帳號的管理員權限；不可輸入另一個管理員帳號。'
 $command="& '"+$EntryPath.Replace("'","''")+"' -ExpectedUserSID '"+$sid+"'"
 if($SshScriptPath){$command+=" -SshScriptPath '"+$SshScriptPath.Replace("'","''")+"'"}
 Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -NoExit -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
 return
}
if($route -eq 'RejectBuiltinAdministrator'){throw '目前是一般 Administrator 桌面，不是可確認的稽核模式。請登入正式的本機管理員帳號再執行 Init。'}
if($route -eq 'RejectUnknownSetupState'){
 $reasons=@(Get-InitRouteRejectReasons -Sid $sid -ImageState $imageState -IsAdministrator $admin -DesktopOwned $desktopOwned -ModeFacts $context.ModeFacts)
 $record=Write-SetupInitRejectRecord -Root $env:ProgramData -Context $context -Route $route -Reasons $reasons -Rechecks $rechecks -SysprepDialogClosed $sysprepClosed
 $waited=$(if($rechecks){'已重新檢查 '+$rechecks+' 次（約 '+($rechecks*$recheckSeconds)+' 秒）仍不符。'}else{''})
 throw ('無法確認帳號準備條件或正式使用者桌面，未變更設定。不符條件：'+($reasons -join '；')+'。'+$waited+'ImageState='+$imageState+'。'+(Format-SetupInitRecordNote $record))
}
if(-not $context.Is64Bit -or $context.Architecture -ne 'AMD64'){throw '本入口僅支援 x64 Windows，請用 64 位元 Windows PowerShell。'}
if($route -eq 'DesktopReady'){
 $user=Get-LocalUser -SID $context.UserSID -ErrorAction Stop
 if(-not $user.Enabled){throw '目前本機使用者未啟用。'}
 Write-Host ('目前正式帳號：'+$user.Name+'；帳號已就緒，不重設密碼。請直接執行 windows.cmd，SSH 由第 4 階段安裝。') -ForegroundColor Green
 return
}
$null=Assert-InitProvisioningAsset -AssetRoot (Join-Path $sourceRoot 'modules/init/assets')
# Eligibility for controlled OOBE preparation is not proof of an official Audit mode API.
if(-not $desktopOwned){throw '請在稽核模式 Administrator 桌面執行，不接受遠端或非桌面工作階段。'}
if(Get-Process sysprep -ErrorAction SilentlyContinue){throw 'Sysprep 對話框或程序仍開啟。請先按「取消」關閉，勿同時執行兩份，再重跑 init.cmd。'}
$sMode=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction SilentlyContinue).SkuPolicyRequired
if($sMode -eq 1){throw 'S mode 不支援本工具使用的首次登入清理指令，本次未建立設定。'}
$sysprep=Join-Path $env:WINDIR 'System32\Sysprep\Sysprep.exe'
if(-not(Test-Path -LiteralPath $sysprep -PathType Leaf)){throw '找不到 Sysprep，未建立設定。'}
$existingAnswer=@(Get-InitAnswerCandidates -WindowsPath $env:WINDIR|Where-Object {Test-Path -LiteralPath $_})
$answerRegistry=(Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue).UnattendFile
if($answerRegistry){$existingAnswer+=@([Environment]::ExpandEnvironmentVariables([string]$answerRegistry))}
if($existingAnswer.Count){throw ('已有 Windows answer file 或快取設定，可能來自 Windows 安裝本身；本工具保守停止，請先確認用途，勿任意刪除：'+($existingAnswer -join '；'))}
$stage=Join-Path $env:ProgramData 'NUC-Init'
Assert-InitPlainPath $stage
if(Test-Path -LiteralPath $stage){throw ('已有 Init 暫存資料，請先查看 '+$stage+'，不要重複產生帳號設定。')}
Write-Host '已自動確認可準備新帳號與 Windows 初始設定。'
if(-not (Request-SetupInitConsent)){throw '未同意帳號與 OOBE 準備，本次未更改設定。'}
$existingNames=@((Get-LocalUser).Name)
$name=Read-Host '新的本機管理員帳號（最多 20 字；不可使用現有帳號或 Windows 保留符號）'
if(-not(Test-InitUserName -Name $name -ExistingNames $existingNames)){throw '帳號名稱無效、已存在或保留，請重新執行並使用另一個名稱。'}
$password=Read-Host '新帳號密碼' -AsSecureString
$confirm=Read-Host '再次輸入密碼' -AsSecureString
$plain=$null;$second=$null;$ptr=[IntPtr]::Zero;$ptr2=[IntPtr]::Zero
try{
 $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($password);$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
 $ptr2=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirm);$second=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr2)
 if(-not(Test-InitPassword $plain) -or $plain -cne $second){throw '密碼須為 1 至 127 字、不含控制字元，且兩次必須相同。本次未寫入設定。'}
 Write-Host '將在本機建立僅系統與管理員可讀的暫存 answer file。其密碼編碼可還原，不是加密；首次登入後會清理本工具檔案。密碼不寫入 USB。' -ForegroundColor Yellow
 Write-Host ('準備建立帳號 '+$name+' 並重新準備初始設定；不會自動重開。') -ForegroundColor Cyan
 New-Item -ItemType Directory -Path $stage|Out-Null
 Protect-InitFolder -Path $stage
 foreach($file in @('oobe_library.ps1','cleanup_oobe.ps1')){Copy-Item -LiteralPath (Join-Path $ModuleRoot $file) -Destination (Join-Path $stage $file)}
 $marker='NUC-INIT-'+[guid]::NewGuid().ToString('N')
 $cleanup='"'+(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')+'" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $stage 'cleanup_oobe.ps1')+'"'
 $xml=New-InitAnswerXml -UserName $name -Password $plain -CleanupCommand $cleanup -Marker $marker
 $utf8=New-Object Text.UTF8Encoding($false)
 [IO.File]::WriteAllText((Join-Path $stage 'state.json'),(@{Marker=$marker;UserName=$name;PreparedAt=(Get-Date).ToString('o')}|ConvertTo-Json),$utf8)
 [IO.File]::WriteAllText((Join-Path $stage 'answer.xml'),$xml,$utf8)
}catch{
 if(Test-Path -LiteralPath (Join-Path $stage 'state.json')){
  try{& (Join-Path $stage 'cleanup_oobe.ps1')}catch{Write-Warning '準備失敗且暫存檔未完全清理，請檢查受保護的 NUC-Init 資料夾。'}
 }
 throw
}finally{
 if($ptr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
 if($ptr2 -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr2)}
 $plain=$null;$second=$null;$xml=$null;$password.Dispose();$confirm.Dispose()
}
Write-Host '準備下一次 OOBE；不執行 generalize，也不自動重新開機。' -ForegroundColor Cyan
try{
 $process=Start-Process -FilePath $sysprep -ArgumentList ('/oobe /quit /unattend:"'+(Join-Path $stage 'answer.xml')+'"') -Wait -PassThru -WindowStyle Hidden
 if($process.ExitCode -ne 0){throw ('Sysprep 失敗，退出碼 '+$process.ExitCode+'。請查看 Windows\System32\Sysprep\Panther 記錄，不要直接重新安裝或反覆重試。')}
}catch{
 try{& (Join-Path $stage 'cleanup_oobe.ps1')}catch{Write-Warning '失敗後的暫存檔清理未完成，請檢查受保護的 NUC-Init 資料夾。'}
 throw
}
Write-Host '帳號設定已準備完成，請現在手動重新啟動；不要再開其他應用程式。' -ForegroundColor Green
Write-Host '完成剩餘地區／隱私等初始設定，用剛才的本機帳號登入，直接執行 windows.cmd；不需再跑 Init，SSH 由 Windows 第 4 階段處理。'
Write-Host ('若初始設定失敗或取消，密碼暫存仍可能存在於 '+$stage+'；不可忽略，請先檢查 cleanup-result.json 與受保護的 answer.xml。')

}
