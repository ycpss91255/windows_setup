#Requires -Version 5.1
# 重開後自動驗收：一鍵流程結束時，把續跑必需的 runtime 複製到本機受保護位置，並登記一次性的登入後排程。
# 載入本檔只定義函式，不變更檔案、ACL 或排程；路徑與 ACL 保護沿用 gui_stage_library.ps1。
. (Join-Path $PSScriptRoot 'gui_stage_library.ps1')
$script:SetupResumeTaskName='WindowsSetup-AfterRestart-Resume'
$script:SetupResumeTaskDescription='windows_setup after-restart resume v1'
$script:SetupResumeMaxAttempts=3
# 每機結果與暫存不屬於 runtime；程式檔與驅動設定檔若未登記就拒絕續跑。
$script:SetupResumeResultPattern='(?i)(-(Result|Verification|Progress)\.json|\.log|\.tmp)$'
$script:SetupResumeCodePattern='(?i)(\.(ps1|psm1|psd1|cmd|bat|cs|exe|dll)$|^drivers/)'
function Get-SetupResumeRuntimeFiles {
 # 只列續跑必需的 runtime：根目錄入口、core、modules 與驅動設定檔；不含驅動封存檔、維護工具、文件與每機結果。
 param([Parameter(Mandatory=$true)][string]$PackageRoot)
 $root=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
 $names=New-Object Collections.Generic.List[string]
 foreach($name in @('init.cmd','windows.cmd','readme.md','.version')){if(Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf){$names.Add($name)}}
 foreach($dir in @('core','modules')){
  foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $root $dir) -Recurse -File -Force -ErrorAction Stop)){
   $relative=$file.FullName.Substring($root.Length+1).Replace('\','/')
   if($relative -notmatch $script:SetupResumeResultPattern){$names.Add($relative)}
  }
 }
 $drivers=Join-Path $root 'drivers'
 if(Test-Path -LiteralPath $drivers -PathType Container){
  foreach($profile in @(Get-ChildItem -LiteralPath $drivers -Directory -ErrorAction Stop)){
   foreach($leaf in @('profile.json','manifest.json')){if(Test-Path -LiteralPath (Join-Path $profile.FullName $leaf) -PathType Leaf){$names.Add('drivers/'+$profile.Name+'/'+$leaf)}}
  }
 }
 return @($names|Sort-Object -Unique)
}
function Test-SetupResumeRelativePath {
 param([string]$Path)
 return (-not [string]::IsNullOrWhiteSpace($Path) -and -not [IO.Path]::IsPathRooted($Path) -and $Path -notmatch '(^|/)\.\.(/|$)' -and $Path -notmatch '[:*?"<>|\\]')
}
function Copy-SetupResumeFile {
 param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Target,[string]$UserSid)
 Assert-SetupGuiPlainPath $Source;Assert-SetupGuiPlainPath $Target
 $expected=(Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash
 Copy-Item -LiteralPath $Source -Destination $Target -Force -ErrorAction Stop
 Assert-SetupGuiProtectedPath $Target -UserSid $UserSid
 if((Get-FileHash -LiteralPath $Target -Algorithm SHA256 -ErrorAction Stop).Hash -cne $expected){throw ('續跑檔案複製前後雜湊不符：'+$Source)}
 return $expected.ToLowerInvariant()
}
function Remove-SetupResumeTree {
 param([Parameter(Mandatory=$true)][string]$Path)
 if(-not(Test-Path -LiteralPath $Path)){return}
 Assert-SetupGuiPlainPath $Path
 # 只刪除已確認是本工具建立的受保護目錄；擁有者或 ACL 不符時保留原資料。
 try{Assert-SetupGuiProtectedPath $Path -Directory}catch{throw ('不是本工具建立的受保護目錄，保留原資料未刪除：'+$Path+'（'+$_.Exception.Message+'）')}
 Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}
function Publish-SetupResumeRuntime {
 param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$UserSid,[Parameter(Mandatory=$true)][string]$Computer,[Parameter(Mandatory=$true)][string]$ResultPath,$Hardware,[string]$CommonDataRoot=$env:ProgramData)
 $paths=Get-SetupResumePaths -CommonDataRoot $CommonDataRoot
 if(-not(Test-Path -LiteralPath $paths.Base -PathType Container)){[void][IO.Directory]::CreateDirectory($paths.Base)}
 Assert-SetupGuiAncestors $paths.Base
 # 同名位置只接受前次本工具建立的受保護目錄；其他內容保留並停止。
 if(Test-Path -LiteralPath $paths.Root){Assert-SetupGuiProtectedPath $paths.Root -Directory;Remove-SetupResumeTree $paths.Root}
 New-SetupGuiProtectedDirectory $paths.Root
 New-SetupGuiProtectedDirectory $paths.Runtime
 New-SetupGuiProtectedDirectory $paths.Reports -UserSid $UserSid
 $root=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
 $created=@{}
 $files=@(foreach($name in @(Get-SetupResumeRuntimeFiles -PackageRoot $root)){
  if(-not(Test-SetupResumeRelativePath $name)){throw ('續跑檔案路徑不安全：'+$name)}
  $parent=$paths.Runtime
  $parts=$name.Split('/')
  for($i=0;$i -lt $parts.Length-1;$i++){$parent=Join-Path $parent $parts[$i];if(-not $created.ContainsKey($parent)){New-SetupGuiProtectedDirectory $parent;$created[$parent]=$true}}
  [pscustomobject][ordered]@{Path=$name;SHA256=(Copy-SetupResumeFile -Source (Join-Path $root $name) -Target (Join-Path $paths.Runtime $name))}
 })
 $driver=$null
 if($Hardware -and $Hardware.DriverSelection -and $Hardware.DriverPackagePath){
  # 只保存驅動包身分與清單，不複製封存檔；驅動包不在時改讀本機已安裝驅動。
  New-SetupGuiProtectedDirectory $paths.Driver
  foreach($item in @(@('package.json','PackageSHA256'),@('manifest.json','ManifestSHA256'))){
   $hash=Copy-SetupResumeFile -Source (Join-Path ([string]$Hardware.DriverPackagePath) $item[0]) -Target (Join-Path $paths.Driver $item[0])
   if($hash -ne [string]$Hardware.DriverSelection.($item[1])){throw '驅動包清單與本輪選擇不同，未登記自動驗收。'}
  }
  $driver=[ordered]@{PackageSHA256=([string]$Hardware.DriverSelection.PackageSHA256).ToLowerInvariant();ManifestSHA256=([string]$Hardware.DriverSelection.ManifestSHA256).ToLowerInvariant()}
 }
 $null=Copy-SetupResumeFile -Source $ResultPath -Target (Join-Path $paths.Reports 'Setup-Result.json') -UserSid $UserSid
 $versionFile=Join-Path $root '.version'
 $version=if(Test-Path -LiteralPath $versionFile -PathType Leaf){([IO.File]::ReadAllText($versionFile)).Trim()}else{''}
 $manifest=[ordered]@{Schema=1;Computer=$Computer;UserSID=$UserSid;SourceVersion=$version;CreatedAt=(Get-Date).ToString('o');MaxAttempts=$script:SetupResumeMaxAttempts;Driver=$driver;Files=$files}
 Write-SetupGuiAtomicJson -Path $paths.Manifest -Value $manifest
 Write-SetupGuiAtomicJson -Path $paths.Attempts -Value ([ordered]@{Attempts=0;UpdatedAt=(Get-Date).ToString('o')})
 [pscustomobject]@{Paths=$paths;ManifestSHA256=(Get-FileHash -LiteralPath $paths.Manifest -Algorithm SHA256).Hash.ToLowerInvariant();FileCount=$files.Count;SourceVersion=$version}
}
function Get-SetupResumeTaskAction {
 param([Parameter(Mandatory=$true)]$Paths,[Parameter(Mandatory=$true)][string]$ManifestSha256)
 $powershell=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
 $entry=Join-Path $Paths.Runtime 'core\resume_after_restart.ps1'
 # 清單雜湊放在排程參數，續跑前以登記時的值核對本機複本。
 [pscustomobject]@{Execute=$powershell;Arguments=('-NoProfile -ExecutionPolicy Bypass -NoExit -File "'+$entry+'" -ManifestSHA256 '+$ManifestSha256.ToLowerInvariant())}
}
function Test-SetupResumeTaskOwned {
 param($Task,[Parameter(Mandatory=$true)]$Paths)
 if($null -eq $Task){return $false}
 $entry='"'+(Join-Path $Paths.Runtime 'core\resume_after_restart.ps1')+'"'
 return ([string]$Task.Description -ceq $script:SetupResumeTaskDescription -and @($Task.Actions).Count -eq 1 -and ([string]@($Task.Actions)[0].Arguments).Contains($entry))
}
function Register-SetupResumeTask {
 param([Parameter(Mandatory=$true)]$Paths,[Parameter(Mandatory=$true)][string]$UserSid,[Parameter(Mandatory=$true)][string]$ManifestSha256)
 $name=$script:SetupResumeTaskName
 $existing=@(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)
 if($existing.Count){
  if(-not(Test-SetupResumeTaskOwned -Task $existing[0] -Paths $Paths)){throw '已有同名排程不是本工具登記的重開後驗收，拒絕覆寫。'}
  Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
 }
 $spec=Get-SetupResumeTaskAction -Paths $Paths -ManifestSha256 $ManifestSha256
 $account=(New-Object Security.Principal.SecurityIdentifier($UserSid)).Translate([Security.Principal.NTAccount]).Value
 # 只在原帳號登入時以最高權限執行：不跳 UAC，且只開啟這一個終端機。
 $trigger=New-ScheduledTaskTrigger -AtLogOn -User $account
 $trigger.Delay='PT30S'
 $action=New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Arguments
 $principal=New-ScheduledTaskPrincipal -UserId $UserSid -LogonType Interactive -RunLevel Highest
 $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
 Register-ScheduledTask -TaskName $name -TaskPath '\' -Description $script:SetupResumeTaskDescription -Action $action -Trigger $trigger -Principal $principal -Settings $settings -ErrorAction Stop|Out-Null
 $registered=@(Get-ScheduledTask -TaskName $name -ErrorAction Stop)
 if($registered.Count -ne 1 -or -not(Test-SetupResumeTaskOwned -Task $registered[0] -Paths $Paths) -or @($registered[0].Actions).Count -ne 1 -or -not [string]::Equals([string]@($registered[0].Actions)[0].Execute,$spec.Execute,[StringComparison]::OrdinalIgnoreCase) -or [string]@($registered[0].Actions)[0].Arguments -cne $spec.Arguments -or [string]$registered[0].Principal.LogonType -cne 'Interactive' -or [string]$registered[0].Principal.RunLevel -cne 'Highest' -or @($registered[0].Triggers).Count -ne 1){throw '重開後驗收排程讀回與固定動作、權限或觸發不符。'}
 try{$principalId=[string]$registered[0].Principal.UserId;$principalSid=if($principalId -match '^S-1-'){(New-Object Security.Principal.SecurityIdentifier($principalId)).Value}else{(New-Object Security.Principal.NTAccount($principalId)).Translate([Security.Principal.SecurityIdentifier]).Value}}catch{throw '重開後驗收排程無法解析原帳號 SID。'}
 if($principalSid -cne $UserSid){throw '重開後驗收排程讀回不是原帳號。'}
}
function Unregister-SetupResumeTask {
 param([Parameter(Mandatory=$true)]$Paths)
 $task=@(Get-ScheduledTask -TaskName $script:SetupResumeTaskName -ErrorAction SilentlyContinue)
 if(-not $task.Count){return}
 if(-not(Test-SetupResumeTaskOwned -Task $task[0] -Paths $Paths)){throw '同名排程不是本工具登記的重開後驗收，未移除。'}
 Unregister-ScheduledTask -TaskName $script:SetupResumeTaskName -Confirm:$false -ErrorAction Stop
}
function Remove-SetupResumeRegistration {
 # 移除登記與本機暫存；報告目錄保留。
 param([Parameter(Mandatory=$true)]$Paths,[switch]$KeepFiles)
 $errors=@()
 try{Unregister-SetupResumeTask -Paths $Paths}catch{$errors+=$_.Exception.Message}
 if(-not $KeepFiles){try{Remove-SetupResumeTree $Paths.Root}catch{$errors+=('本機暫存未清除：'+$_.Exception.Message)}}
 if($errors.Count){throw ($errors -join '；')}
}
function Invoke-SetupResumeRegistration {
 # 一鍵流程結束時呼叫；本輪結果必須是同機、同帳號、本輪產生。失敗只提示，不覆蓋本輪原本的結果。
 param([Parameter(Mandatory=$true)][string]$PackageRoot,$Hardware,[Parameter(Mandatory=$true)][datetime]$StartedAt,[string]$ResultPath=(Resolve-NucPath 'Setup-Result.json'),[string]$CommonDataRoot=$env:ProgramData)
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $paths=Get-SetupResumePaths -CommonDataRoot $CommonDataRoot
 try{
  if(Test-SetupResumeRuntime -PackageRoot $PackageRoot){throw '目前就在本機續跑位置執行，不重新登記。'}
  if(-not(Test-Path -LiteralPath $ResultPath -PathType Leaf)){throw '本輪沒有產生 Setup-Result.json。'}
  $saved=Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8|ConvertFrom-Json
  $completed=[datetime]::MinValue
  if($saved.Computer -cne $env:COMPUTERNAME -or $saved.UserSID -cne $sid -or -not [datetime]::TryParse([string]$saved.CompletedAt,[ref]$completed) -or $completed -lt $StartedAt){throw 'Setup-Result.json 不是本輪、同機、同帳號的結果。'}
  $existing=@(Get-ScheduledTask -TaskName $script:SetupResumeTaskName -ErrorAction SilentlyContinue)
  if($existing.Count -and -not(Test-SetupResumeTaskOwned -Task $existing[0] -Paths $paths)){throw '已有同名排程不是本工具登記的重開後驗收，拒絕覆寫。'}
  $published=Publish-SetupResumeRuntime -PackageRoot $PackageRoot -UserSid $sid -Computer $env:COMPUTERNAME -ResultPath $ResultPath -Hardware $Hardware -CommonDataRoot $CommonDataRoot
  Register-SetupResumeTask -Paths $published.Paths -UserSid $sid -ManifestSha256 $published.ManifestSHA256
  Write-Host '請手動重新開機；自動登入進入桌面後，會自動開啟一個終端機執行重開後驗收，不需再輸入資訊。' -ForegroundColor Green
  Write-Host ('已複製續跑必需的 '+$published.FileCount+' 個檔案到本機（不含驅動封存檔）；之後拔除工具包或驅動包仍可驗收，報告寫在 '+$published.Paths.Reports+'。')
  return [pscustomobject]@{Registered=$true;Paths=$published.Paths;ManifestSHA256=$published.ManifestSHA256;Error=''}
 }catch{
  $message=$_.Exception.Message
  Write-Warning ('未登記重開後自動驗收：'+$message)
  if(-not $message.StartsWith('已有同名排程')){try{Remove-SetupResumeRegistration -Paths $paths}catch{Write-Warning ('未完成的登記未清除：'+$_.Exception.Message)}}
  Write-Host '請手動重新開機，再從工具包執行 windows.cmd -AfterRestart 檢查及繼續更新。'
  return [pscustomobject]@{Registered=$false;Paths=$paths;ManifestSHA256='';Error=$message}
 }
}
function Step-SetupResumeAttempt {
 # 先記次數再做任何檢查，雜湊不符或中途當掉也不會無限重跑。
 param([Parameter(Mandatory=$true)]$Paths)
 try{
  Assert-SetupGuiProtectedPath $Paths.Attempts
  $record=Get-Content -LiteralPath $Paths.Attempts -Raw -Encoding UTF8|ConvertFrom-Json
  if(($record.Attempts -isnot [int] -and $record.Attempts -isnot [long]) -or $record.Attempts -lt 0){throw '次數格式不符'}
  $count=[int]$record.Attempts+1
 }catch{return $script:SetupResumeMaxAttempts+1}
 Write-SetupGuiAtomicJson -Path $Paths.Attempts -Value ([ordered]@{Attempts=$count;UpdatedAt=(Get-Date).ToString('o')})
 return $count
}
function Assert-SetupResumeRuntime {
 param([Parameter(Mandatory=$true)]$Paths,[Parameter(Mandatory=$true)][string]$ManifestSHA256,[Parameter(Mandatory=$true)][string]$UserSid,[Parameter(Mandatory=$true)][string]$Computer)
 Assert-SetupGuiProtectedPath $Paths.Root -Directory
 Assert-SetupGuiProtectedPath $Paths.Manifest
 if((Get-FileHash -LiteralPath $Paths.Manifest -Algorithm SHA256 -ErrorAction Stop).Hash -ne $ManifestSHA256){throw '續跑清單與登記時的雜湊不同。'}
 $manifest=Get-Content -LiteralPath $Paths.Manifest -Raw -Encoding UTF8|ConvertFrom-Json
 if($manifest.Schema -ne 1 -or $manifest.Computer -cne $Computer -or $manifest.UserSID -cne $UserSid -or @($manifest.Files).Count -lt 1){throw '續跑清單不是同機、同帳號登記的內容。'}
 $listed=@{}
 foreach($file in @($manifest.Files)){
  $name=[string]$file.Path
  if(-not(Test-SetupResumeRelativePath $name) -or [string]$file.SHA256 -notmatch '^[a-f0-9]{64}$'){throw ('續跑清單含不安全項目：'+$name)}
  $path=Join-Path $Paths.Runtime $name
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ('續跑檔案缺少：'+$name)}
  if((Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ne $file.SHA256){throw ('續跑檔案雜湊不符：'+$name)}
  $listed[$name.ToLowerInvariant()]=$true
 }
 $runtime=[IO.Path]::GetFullPath($Paths.Runtime).TrimEnd('\')
 foreach($item in @(Get-ChildItem -LiteralPath $runtime -Recurse -File -Force -ErrorAction Stop)){
  $relative=$item.FullName.Substring($runtime.Length+1).Replace('\','/')
  if(-not $listed.ContainsKey($relative.ToLowerInvariant()) -and $relative -match $script:SetupResumeCodePattern){throw ('續跑位置有未登記的程式檔：'+$relative)}
 }
 if($manifest.Driver){
  foreach($item in @(@('package.json','PackageSHA256'),@('manifest.json','ManifestSHA256'))){
   $path=Join-Path $Paths.Driver $item[0]
   if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ne [string]$manifest.Driver.($item[1])){throw ('本機保存的驅動清單不符：'+$item[0])}
  }
 }
 return $manifest
}
function Wait-SetupResumeDesktop {
 # 登入後等原帳號的桌面（explorer.exe）就緒，最多等待指定秒數。
 param([Parameter(Mandatory=$true)][string]$UserSid,[int]$TimeoutSeconds=120)
 $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
 $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
 do{
  foreach($process in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue|Where-Object {$_.SessionId -eq $session})){
   $owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction SilentlyContinue
   if($owner -and $owner.ReturnValue -eq 0 -and $owner.Sid -ceq $UserSid){return $true}
  }
  Write-Host '等待桌面就緒…';Start-Sleep -Seconds 5
 }while((Get-Date) -lt $deadline)
 return $false
}
function Test-SetupResumeRebootPending {
 return ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))
}
function Test-SetupResumeRestartNeeded {
 # 只有重開或重新登入才會改變的項目才保留登記；其他失敗不自動重跑。
 param($Acceptance,[switch]$RebootPending)
 if($RebootPending){return $true}
 $names=@('無待處理重新開機','分頁檔實際已停用','工作列待處理項目讀回','開始選單釘選清空')
 return (@($Acceptance.FailedChecks|Where-Object {$_ -and [string]$_.Name -cin $names}).Count -gt 0)
}
function Write-SetupResumeResult {
 param([Parameter(Mandatory=$true)]$Paths,[Parameter(Mandatory=$true)][string]$Status,[int]$Attempt,[string]$Message,[string]$UserSid)
 $value=[ordered]@{Status=$Status;Attempt=$Attempt;MaxAttempts=$script:SetupResumeMaxAttempts;Computer=$env:COMPUTERNAME;CheckedAt=(Get-Date).ToString('o');Message=$Message}
 try{
  if(-not(Test-Path -LiteralPath $Paths.Reports)){New-SetupGuiProtectedDirectory $Paths.Reports -UserSid $UserSid}
  Write-SetupGuiAtomicJson -Path (Join-Path $Paths.Reports 'AfterRestartResume-Result.json') -Value $value -UserSid $UserSid
 }catch{Write-Warning ('自動驗收結果未寫入：'+$_.Exception.Message)}
 [pscustomobject]$value
}
function Invoke-SetupResumeAfterRestart {
 # 登入後排程的唯一入口：核對次數、身分與本機複本，再執行與手動 -AfterRestart 相同的流程。
 param([Parameter(Mandatory=$true)][string]$ManifestSHA256,[Parameter(Mandatory=$true)][string]$RuntimeRoot,[Parameter(Mandatory=$true)][scriptblock]$AfterRestart)
 $paths=Get-SetupResumePaths
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $max=$script:SetupResumeMaxAttempts
 Write-Host '=== 重開後自動驗收（不需輸入） ===' -ForegroundColor Cyan
 if(-not [string]::Equals([IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\'),$paths.Runtime.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){throw '自動驗收只能從本機續跑位置執行。'}
 Set-Location -LiteralPath $env:SystemRoot
 $attempt=Step-SetupResumeAttempt -Paths $paths
 if($attempt -gt $max){
  $message='已自動執行 '+$max+' 次仍未完成，停止自動驗收並移除登記；報告保留在 '+$paths.Reports+'。處理後可插回工具包執行 windows.cmd -AfterRestart。'
  try{Remove-SetupResumeRegistration -Paths $paths}catch{$message+='（清除失敗：'+$_.Exception.Message+'）'}
  Write-Warning $message;return (Write-SetupResumeResult -Paths $paths -Status 'AttemptLimit' -Attempt $attempt -Message $message -UserSid $sid)
 }
 try{$null=Assert-SetupResumeRuntime -Paths $paths -ManifestSHA256 $ManifestSHA256 -UserSid $sid -Computer $env:COMPUTERNAME}catch{
  $message='本機續跑檔案與登記時不同（'+$_.Exception.Message+'），已停止自動驗收並移除登記；保留 '+$paths.Root+' 供檢查。請插回工具包執行 windows.cmd -AfterRestart。'
  try{Remove-SetupResumeRegistration -Paths $paths -KeepFiles}catch{$message+='（登記移除失敗：'+$_.Exception.Message+'）'}
  Write-Warning $message;return (Write-SetupResumeResult -Paths $paths -Status 'IntegrityFailed' -Attempt $attempt -Message $message -UserSid $sid)
 }
 Write-Host ('第 '+$attempt+'/'+$max+' 次自動驗收；使用本機保存的工具檔案，不需要工具包或驅動包。')
 if(-not(Wait-SetupResumeDesktop -UserSid $sid)){Write-Warning '桌面尚未就緒，仍繼續驗收；如有失敗會依結果處理。'}
 $startedAt=Get-Date;$failure=''
 try{& $AfterRestart}catch{$failure=$_.Exception.Message}
 $acceptance=$null
 try{$candidate=Get-Content -LiteralPath (Join-Path $paths.Reports 'Acceptance-Result.json') -Raw -Encoding UTF8|ConvertFrom-Json;$checked=[datetime]::MinValue;if([datetime]::TryParse([string]$candidate.CheckedAt,[ref]$checked) -and $checked -ge $startedAt.AddSeconds(-1)){$acceptance=$candidate}}catch{}
 if(-not $failure){
  $message='重開後自動驗收通過，已移除自動執行登記與本機暫存；報告保留在 '+$paths.Reports+'。'
  try{Remove-SetupResumeRegistration -Paths $paths}catch{$message+='（清除失敗：'+$_.Exception.Message+'）'}
  Write-Host $message -ForegroundColor Green;return (Write-SetupResumeResult -Paths $paths -Status 'Completed' -Attempt $attempt -Message $message -UserSid $sid)
 }
 if(Test-SetupResumeRestartNeeded -Acceptance $acceptance -RebootPending:(Test-SetupResumeRebootPending)){
  if($attempt -lt $max){
   $message='仍需重新開機才能完成（'+$failure+'）。請手動重開；自動登入後會再自動驗收（已執行 '+$attempt+'/'+$max+' 次）。報告：'+$paths.Reports+'。'
   Write-Warning $message;return (Write-SetupResumeResult -Paths $paths -Status 'RestartRequired' -Attempt $attempt -Message $message -UserSid $sid)
  }
  $message='已自動驗收 '+$max+' 次仍需重新開機（'+$failure+'），停止自動執行並移除登記；報告保留在 '+$paths.Reports+'。處理後可插回工具包執行 windows.cmd -AfterRestart。'
  try{Remove-SetupResumeRegistration -Paths $paths}catch{$message+='（清除失敗：'+$_.Exception.Message+'）'}
  Write-Warning $message;return (Write-SetupResumeResult -Paths $paths -Status 'AttemptLimit' -Attempt $attempt -Message $message -UserSid $sid)
 }
 $message='重開後驗收未通過（'+$failure+'），不是重開可解決的項目，已移除自動執行登記與本機暫存；報告保留在 '+$paths.Reports+'。處理後可插回工具包執行 windows.cmd -AfterRestart。'
 try{Remove-SetupResumeRegistration -Paths $paths}catch{$message+='（清除失敗：'+$_.Exception.Message+'）'}
 Write-Warning $message;return (Write-SetupResumeResult -Paths $paths -Status 'Failed' -Attempt $attempt -Message $message -UserSid $sid)
}
