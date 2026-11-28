#Requires -Version 5.1
# 整輪紀錄的驅動選擇：從真實選包提示、提權參數到 Setup-*.log 與續跑，全程只用替身模組。
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$fixture=Join-Path $env:TEMP ('driver_choice_'+[guid]::NewGuid().ToString('N'))
$package=Join-Path $fixture 'windows_setup';$core=Join-Path $package 'core';$stub=Join-Path $package 'stub';$reports=Join-Path $package 'reports';$init=Join-Path $package 'modules/init'
$payload=Join-Path $fixture 'windows_driver_packages\nuc8'
foreach($dir in @($core,$stub,$reports,$init)){[void][IO.Directory]::CreateDirectory($dir)}
function Same-Package([string]$Left,[string]$Right){[bool]$Left -and (Get-Item -LiteralPath $Left).FullName -eq (Get-Item -LiteralPath $Right).FullName}
$utf=[Text.UTF8Encoding]::new($true)
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
function Put([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,$utf)}
foreach($name in @('start_windows.ps1','network_preflight_library.ps1','configure_setup.ps1','configuration_library.ps1','verify_after_restart.ps1','after_restart_library.ps1')){Copy-Item -LiteralPath (Join-Path $root ('core/'+$name)) -Destination $core}
Put (Join-Path $core 'hardware.ps1') ([IO.File]::ReadAllText((Join-Path $root 'core/hardware.ps1'))+"`nfunction Test-SetupInteractiveHost {`$true}`n")
Copy-Item -LiteralPath (Join-Path $root 'drivers') -Destination $package -Recurse
foreach($name in @('start_pins_policy_library.ps1','start_pins_asset_library.ps1')){Copy-Item -LiteralPath (Join-Path $root ('modules/start_menu/'+$name)) -Destination $stub}
Put (Join-Path $core 'entry_os_boundary.ps1') @'
function Get-SetupEntryIdentity {[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
function Test-SetupEntryAdministrator {$global:choiceFixture.Admin}
function Start-SetupEntryElevated {param($Command) $global:choiceFixture.Command=$Command}
function Get-SetupEntryUserUILanguage {[pscustomobject]@{Name='en-US';Source='fixture';Reason=''}}
'@
Put (Join-Path $core 'paths.ps1') @'
. (Join-Path $PSScriptRoot 'hardware.ps1')
$script:NucPackageRoot=Split-Path -Parent $PSScriptRoot
function Initialize-NucReports {}
function Resolve-NucModuleName {param($Name) $Name}
function Resolve-NucPath {param($Name)
 if($Name -in @('configuration_library.ps1','after_restart_library.ps1')){return Join-Path $PSScriptRoot $Name}
 if($Name -like '*.ps1'){return Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'stub') $Name}
 Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'reports') $Name
}
'@
Put (Join-Path $init 'provisioning_library.ps1') 'function Invoke-InitWindowsCheckpoint {param($StageRoot)}'
Put (Join-Path $core 'resume_library.ps1') 'function Invoke-SetupResumeRegistration {param($PackageRoot,$Hardware,[datetime]$StartedAt)}'
Put (Join-Path $stub 'test_setup_prerequisites.ps1') 'param($DriverPackagePath,$ConfirmedBoard,$ConfirmationComputer)'
Put (Join-Path $stub 'verification_library.ps1') 'function Invoke-SetupDriverFreshVerification {param($DriverPackagePath,$VerificationRunId) [pscustomobject]@{Success=$true;Targets=@();VerificationRunId=$VerificationRunId}}'
Put (Join-Path $stub 'verify_only.ps1') @'
param($VerificationRunId)
@{VerificationRunId=$VerificationRunId;Computer=$env:COMPUTERNAME;UserSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Passed=$true;Checks=@()}|ConvertTo-Json -Depth 4|Set-Content (Resolve-NucPath 'Verification-Result.json') -Encoding UTF8
'@
$source=[IO.File]::ReadAllText((Join-Path $root 'core/configuration_library.ps1'))
foreach($name in @([regex]::Matches($source,"File='([^']+\.ps1)'")|ForEach-Object {$_.Groups[1].Value})+@('apply_uac_settings.ps1','apply_autologon_settings.ps1','audit_nuc.ps1')){
 $body='param($UserName,$AutoLogonPassword,$DriverPackagePath,$ConfirmedBoard,$ConfirmationComputer,$Mode,[switch]$NonInteractive,[switch]$ApplyPolicy,[switch]$VerifyOnly)'
 if($name -eq 'apply_start_menu_settings.ps1'){$body+="`n[pscustomobject]@{Success=`$true;Status='Confirmed';PinCount=0}"}
 if($name -eq 'install_drivers.ps1'){$body+="`n`$global:choiceFixture.Installed=`$DriverPackagePath"}
 Put (Join-Path $stub $name) $body
}
$global:choiceFixture=@{Admin=$false;Command='';Boards=@('NUC8i7HVB');Answers=$null;Prompts=0;Installed=$null;ReadFails=$false}
function Get-CimInstance {param($ClassName,$ErrorAction) foreach($b in $global:choiceFixture.Boards){[pscustomobject]@{Product=$b}}}
function Get-NetConnectionProfile {param($ErrorAction) [pscustomobject]@{IPv4Connectivity='Internet';IPv6Connectivity='NoTraffic'}}
function Get-PnpDevice {param([switch]$PresentOnly)}
function Get-ItemProperty {param($Path,$ErrorAction) [pscustomobject]@{DefaultUserName='fixture';AutoAdminLogon='1'}}
function Read-Host {param($Prompt) $global:choiceFixture.Prompts++;if($global:choiceFixture.ReadFails){throw 'fixture read failure C:\Users\typed-secret'};if(-not $global:choiceFixture.Answers.Count){throw ('Unexpected prompt: '+$Prompt)};$answer=$global:choiceFixture.Answers.Dequeue();if($answer -ceq '<EOF>'){return};return $answer}
$profileFile=Join-Path $root 'drivers/nuc8i7hvk_hnk/profile.json';$profileHash=(Get-FileHash -LiteralPath $profileFile -Algorithm SHA256).Hash
function Set-Package([string]$Kind,[object[]]$Boards=@('NUC8i7HVB','NUC8i7HNB')){
 if(Test-Path -LiteralPath $payload){Remove-Item -LiteralPath $payload -Recurse -Force}
 if($Kind -eq 'none'){return}
 $included=Join-Path $payload 'drivers\nuc8i7hvk_hnk';[void][IO.Directory]::CreateDirectory($included);Copy-Item -LiteralPath $profileFile -Destination $included
 $manifest=@(foreach($n in @('Chipset.zip','SerialIO.zip','UCM.zip','GFX-Radeon.zip')){$f=Join-Path $payload $n;[IO.File]::WriteAllText($f,'fixture');@{File=$n;SHA256=(Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash}})
 if($Kind -eq 'badzip'){$manifest[0].SHA256='0'*64}
 $manifest|ConvertTo-Json|Set-Content (Join-Path $payload 'manifest.json') -Encoding UTF8
 if($Kind -eq 'nojson'){return}
 if($Kind -eq 'badjson'){Put (Join-Path $payload 'package.json') '{ broken';return}
 @{SchemaVersion=2;ProfileId='nuc8i7hvk_hnk';Architecture='x64';ProfileSHA256=$(if($Kind -eq 'badprofile'){'A'*64}else{$profileHash});SupportedBoards=$Boards}|ConvertTo-Json|Set-Content (Join-Path $payload 'package.json') -Encoding UTF8
}
function Reset-Run([object[]]$Answers=@()){
 foreach($item in @(Get-ChildItem -LiteralPath $reports -File)){[IO.File]::Delete($item.FullName)}
 $global:choiceFixture.Admin=$false;$global:choiceFixture.Command='';$global:choiceFixture.Prompts=0;$global:choiceFixture.Installed=$null;$global:choiceFixture.ReadFails=$false
 $global:choiceFixture.Answers=[Collections.Generic.Queue[object]]::new();foreach($a in $Answers){$global:choiceFixture.Answers.Enqueue($a)}
}
function Invoke-Entry([object[]]$Answers=@(),[hashtable]$Arguments=@{}){Reset-Run $Answers;& (Join-Path $core 'start_windows.ps1') @Arguments *>$null}
function Invoke-Elevated([string]$Command=$global:choiceFixture.Command){$global:choiceFixture.Admin=$true;& ([scriptblock]::Create($Command)) *>$null}
function Get-RunLog{$logs=@(Get-ChildItem -LiteralPath $reports -Filter 'Setup-*.log');if($logs.Count -ne 1){throw ('整輪紀錄數量：'+$logs.Count)};[IO.File]::ReadAllText($logs[0].FullName)}
function Get-ChoiceLine([string]$Text){@($Text -split "`r?`n"|Where-Object {$_.StartsWith('[驅動選擇]')})}
function Line($Choice,$Package,$Detected,$Supported,$Manual){'[驅動選擇] 結果：'+$Choice+'；驅動包：'+$Package+'；偵測型號：'+$Detected+'；包支援型號：'+$Supported+'；手動確認型號：'+$Manual}
function Get-Record([string]$Command){[regex]::Match($Command,"-SelectionRecord '([^']*)'").Groups[1].Value}
function Get-SavedChoice{(Get-Content -LiteralPath (Join-Path $reports 'Setup-Result.json') -Raw -Encoding UTF8|ConvertFrom-Json).DriverChoice}
$unknownLine=Line '未知（沒有可信的選包結果）' '未知' '未知' '未知' '未知'
function Assert-Log([string]$Expected,[string]$Name){
 $text=Get-RunLog;$lines=@(Get-ChoiceLine $text)
 Assert ($lines.Count -eq 1 -and $lines[0] -ceq $Expected) ($Name+'：整輪紀錄有唯一且正確的驅動選擇行；實際='+($lines -join ' | '))
 Assert ($text.IndexOf('[驅動選擇]') -lt $text.IndexOf('[1/19]')) ($Name+'：驅動選擇寫在第一階段之前')
}
$both='NUC8i7HVB、NUC8i7HNB'
$typed=Join-Path $fixture 'typed-secret'
$missingDrive=([string]@([char[]](90..68)|Where-Object {-not [IO.Directory]::Exists([string]$_+':')})[0])+':	yped-secret'
try{
 $cases=@(
  @{Name='完全相符按 Enter 選用';Answers=@('');Line=(Line '選用' '檢查通過' 'NUC8i7HVB' $both '否');Installs=$true}
  @{Name='完全相符輸入 N';Answers=@('n');Line=(Line '輸入 N 略過' '型號與身分相符' 'NUC8i7HVB' $both '否')}
  @{Name='無法辨識的輸入之後 N';Answers=@('typed-secret','n');Line=(Line '輸入 N 略過' '型號與身分相符' 'NUC8i7HVB' $both '否')}
  @{Name='型號未對上按 Enter';Boards=@('NUC8i7HNB');Answers=@('');Line=(Line 'Enter 略過' '型號未對上' 'NUC8i7HVB' 'NUC8i7HNB' '否')}
  @{Name='型號未對上輸入 Y 後被拒再 Enter';Boards=@('NUC8i7HNB');Answers=@('y','');Line=(Line 'Enter 略過' '型號未對上' 'NUC8i7HVB' 'NUC8i7HNB' '否')}
  @{Name='找不到包按 Enter';Kind='none';Answers=@('');Line=(Line 'Enter 略過' '找不到包' 'NUC8i7HVB' '無' '否')}
  @{Name='找不到包後輸入不存在路徑再 Enter';Kind='none';Answers=@($typed,'');Line=(Line 'Enter 略過' '找不到包' 'NUC8i7HVB' '無' '否')}
  @{Name='包身分檔損毀按 Enter';Kind='badjson';Answers=@('');Line=(Line 'Enter 略過' '身分檢查失敗' 'NUC8i7HVB' '未知' '否')}
  @{Name='包身分檔缺少按 Enter';Kind='nojson';Answers=@('');Line=(Line 'Enter 略過' '身分檢查失敗' 'NUC8i7HVB' '未知' '否')}
  @{Name='設定檔雜湊不符按 Enter';Kind='badprofile';Answers=@('');Line=(Line 'Enter 略過' '身分檢查失敗' 'NUC8i7HVB' $both '否')}
  @{Name='設定檔雜湊不符輸入 Y 後被拒再 Enter';Kind='badprofile';Answers=@('y','');Line=(Line 'Enter 略過' '身分檢查失敗' 'NUC8i7HVB' $both '否')}
  @{Name='封存檔雜湊不符後 Enter';Kind='badzip';Answers=@('','');Line=(Line 'Enter 略過' '內容檢查失敗' 'NUC8i7HVB' $both '否')}
  @{Name='P 後直接 Enter';Answers=@('p','');Line=(Line 'Enter 略過' '型號與身分相符' 'NUC8i7HVB' $both '否')}
  @{Name='P 指定不存在路徑再 Enter';Answers=@('p',$typed,'');Line=(Line 'Enter 略過' '找不到包' 'NUC8i7HVB' '無' '否')}
  @{Name='P 指定不存在磁碟再 Enter';Answers=@('p',$missingDrive,'');Line=(Line 'Enter 略過' '找不到包' 'NUC8i7HVB' '無' '否')}
  @{Name='P 指定空白路徑（既有規則解析為目前目錄）再 Enter';Answers=@('p','  ','');Line=(Line 'Enter 略過' '身分檢查失敗' 'NUC8i7HVB' '未知' '否')}
  @{Name='手動確認後輸入 Y 選用';Detected=@('');Answers=@('1','NUC8i7HVB','y');Line=(Line '選用' '檢查通過' '未知' $both '是');Installs=$true}
  @{Name='手動確認後 Enter';Detected=@('');Answers=@('1','NUC8i7HVB','');Line=(Line 'Enter 略過' '型號未對上' '未知' $both '是')}
  @{Name='未知型號選通用';Detected=@('');Answers=@('g');Line=(Line '選通用設定' '沒有對應的驅動設定檔' '未知' '未知' '否')}
  @{Name='未知型號按 Enter';Detected=@('');Answers=@('');Line=(Line 'Enter 略過' '沒有對應的驅動設定檔' '未知' '未知' '否')}
  @{Name='其他型號不詢問';Detected=@('Other Board (X) 1.0');Answers=@();Line=(Line '未詢問' '沒有對應的驅動設定檔' 'Other Board (X) 1.0' '未知' '否')}
  @{Name='板號含不允許字元';Detected=@('C:\Users\typed-secret');Answers=@();Line=(Line '未詢問' '沒有對應的驅動設定檔' '未知' '未知' '否')}
  @{Name='多塊主機板';Detected=@('NUC8i7HVB','NUC8i7HNB');Answers=@();Line=(Line '未詢問' '沒有對應的驅動設定檔' '多塊主機板' '未知' '否')}
  @{Name='非互動未選包';Arguments=@{NonInteractive=$true};Answers=@();Line=(Line '未詢問' '未檢查' 'NUC8i7HVB' '未知' '否')}
  @{Name='明確傳入空路徑';Arguments=@{DriverPackagePath=''};Answers=@();Line=(Line '未詢問' '未檢查' 'NUC8i7HVB' '未知' '否')}
  @{Name='參數指定包';Arguments=@{NonInteractive=$true;DriverPackagePath=$payload};Answers=@();Line=(Line '選用' '檢查通過' 'NUC8i7HVB' $both '否');Installs=$true}
  @{Name='找不到包且沒有讀到輸入';Kind='none';Answers=@('<EOF>');Line=(Line '讀取輸入失敗' '找不到包' 'NUC8i7HVB' '無' '否')}
  @{Name='型號提示沒有讀到輸入';Detected=@('');Answers=@('<EOF>');Line=(Line '讀取輸入失敗' '沒有對應的驅動設定檔' '未知' '未知' '否')}
  @{Name='包支援型號含路徑或引號';Boards=@('C:\Users\typed-secret',"a';b");Answers=@('');Line=(Line 'Enter 略過' '型號未對上' 'NUC8i7HVB' '未知' '否')}
  @{Name='包支援型號過多';Boards=@(1..9|ForEach-Object {'BOARD'+$_});Answers=@('');Line=(Line 'Enter 略過' '型號未對上' 'NUC8i7HVB' '未知' '否')}
 )
 foreach($case in $cases){
  Set-Package $(if($case.Kind){$case.Kind}else{'good'}) $(if($case.Boards){$case.Boards}else{@('NUC8i7HVB','NUC8i7HNB')})
  $global:choiceFixture.Boards=$(if($case.Detected){$case.Detected}else{@('NUC8i7HVB')})
  if($case.ContainsKey('Detected')){$global:choiceFixture.Boards=$case.Detected}
  $arguments=if($case.Arguments){$case.Arguments}else{@{}}
  Invoke-Entry $case.Answers $arguments
  Assert ($global:choiceFixture.Prompts -eq @($case.Answers).Count) ($case.Name+'：詢問次數與既有規則相同')
  $command=$global:choiceFixture.Command
  Invoke-Elevated
  Assert-Log $case.Line $case.Name
  Assert ([bool]$global:choiceFixture.Installed -eq [bool]$case.Installs) ($case.Name+'：安裝與否不因紀錄改變')
  $record=Get-Record $command
  Assert ($record -and $record -notmatch 'typed-secret|Users' -and -not $record.Contains($env:USERNAME)) ($case.Name+'：傳遞內容不含輸入原文、帳號或路徑')
  Assert (-not @(Get-ChoiceLine (Get-RunLog))[0].Contains('typed-secret')) ($case.Name+'：驅動選擇行不含輸入原文或路徑')
 }
 # 提權傳遞遺失或被竄改：一律寫未知，不寫略過，也不改變安裝。
 Set-Package 'good';$global:choiceFixture.Boards=@('NUC8i7HVB')
 Invoke-Entry @('n');$skipCommand=$global:choiceFixture.Command;$skip=Get-Record $skipCommand
 Invoke-Entry @('');$pickCommand=$global:choiceFixture.Command;$pick=Get-Record $pickCommand
 Invoke-Elevated $pickCommand
 Assert ((Get-SavedChoice) -ceq $pick) '有效結果原樣保存到 Setup-Result.json 供續跑使用'
 $bad=[ordered]@{
  '遺失'='';'亂碼'='garbage';'版本不同'=$skip.Replace('v1;','v2;');'未知結果'=$skip.Replace('SkippedN','Whatever');'結果大小寫不同'=$skip.Replace('SkippedN','skippedn')
  '未知驅動包狀態'=$skip.Replace('package=Matched','package=Fine');'缺欄位'=$skip.Replace(';manual=0','');'多欄位'=$skip+';extra=1';'重複欄位'=$skip+';manual=0';'欄位順序不同'='v1;package=Matched;choice=SkippedN;detected=NUC8i7HVB;supported=NUC8i7HVB;manual=0'
  '尾端換行'=$skip+"`n";'換行夾帶'=$skip+"`n[1/19] fake";'手動值不合法'=$skip.Replace('manual=0','manual=2');'路徑'=$skip.Replace('detected=NUC8i7HVB','detected=C:\Users\x');'全形字元'=$skip.Replace('detected=NUC8i7HVB',('detected=NUC8i7HVB'+[char]0xFF11));'過長'=$skip.Replace('detected=NUC8i7HVB','detected='+('A'*4000));'型號過多'=$skip.Replace('supported=','supported='+((1..9|ForEach-Object {'B'+$_+','}) -join ''))
  '與實際選包不一致的選用'=$pick;'選用卻未通過檢查'=$pick.Replace('package=Verified','package=IdentityFailed');'略過卻標檢查通過'=$skip.Replace('package=Matched','package=Verified');'偵測型號與提權後不同'=$skip.Replace('detected=NUC8i7HVB','detected=NUC8i7HNB');'偽稱多塊主機板'=$skip.Replace('detected=NUC8i7HVB','detected=*')
 }
 foreach($name in $bad.Keys){
  Reset-Run;$value=$bad[$name]
  $tampered=if($value){$skipCommand.Replace("'"+$skip+"'","'"+$value.Replace("'","''")+"'")}else{$skipCommand.Replace(" -SelectionRecord '"+$skip+"'",'')}
  Assert ($tampered -cne $skipCommand) ('竄改案例確實改變提權參數 '+$name)
  Invoke-Elevated $tampered
  Assert-Log $unknownLine ('竄改／遺失 '+$name)
  Assert (-not $global:choiceFixture.Installed) ('竄改／遺失不觸發安裝 '+$name)
  Assert ((Get-SavedChoice) -ceq '未知') ('竄改／遺失保存為未知 '+$name)
 }
 foreach($pair in @(@('選用結果換成略過',$skip),@('選用結果換成手動確認',$pick.Replace('manual=0','manual=1')))){
  Reset-Run;Invoke-Elevated $pickCommand.Replace("'"+$pick+"'","'"+$pair[1]+"'")
  Assert-Log $unknownLine $pair[0]
  Assert (Same-Package $global:choiceFixture.Installed $payload) ($pair[0]+'：紀錄不可信仍依實際選包安裝')
 }
 # 提權後讀不到型號只是無法比對，不代表紀錄不可信。
 Reset-Run;$global:choiceFixture.Boards=@('');Invoke-Elevated $skipCommand;$global:choiceFixture.Boards=@('NUC8i7HVB')
 Assert-Log (Line '輸入 N 略過' '型號與身分相符' 'NUC8i7HVB' $both '否') '提權後無法偵測型號仍保留選包紀錄'
 Reset-Run;Invoke-Elevated $skipCommand.Replace('detected=NUC8i7HVB','detected=?')
 Assert-Log (Line '輸入 N 略過' '型號與身分相符' '未知' $both '否') '選包時無法偵測型號仍保留選包紀錄'
 # 未提權端：不合法內容不得進入提權命令列。
 foreach($value in @("x'; throw 'injected' #",('x'+[char]0x2019+'; throw injected #'),'$(throw 1)',($skip+"`n"),'typed-secret')){
  Reset-Run;& (Join-Path $core 'configure_setup.ps1') -SelectionRecord $value *>$null
  Assert ($global:choiceFixture.Command -and -not $global:choiceFixture.Command.Contains('SelectionRecord') -and -not $global:choiceFixture.Command.Contains('injected')) '不合法內容不帶入提權命令列'
 }
 # 找到相鄰包的提示讀到輸入結尾：中止、不提權、不選用，分類為讀取輸入失敗。
 foreach($case in @(@{Name='完全相符';Boards=@('NUC8i7HVB','NUC8i7HNB');Answers=@('<EOF>');Package='型號與身分相符';Supported=$both},@{Name='型號未對上';Boards=@('NUC8i7HNB');Answers=@('<EOF>');Package='型號未對上';Supported='NUC8i7HNB'},@{Name='無法辨識的輸入之後';Boards=@('NUC8i7HVB','NUC8i7HNB');Answers=@('x','<EOF>');Package='型號與身分相符';Supported=$both})){
  Set-Package 'good' $case.Boards;$global:choiceFixture.Boards=@('NUC8i7HVB');Reset-Run $case.Answers;$caught='';try{& (Join-Path $core 'start_windows.ps1') *>$null}catch{$caught=$_.Exception.Message}
  Assert ([bool]$caught -and -not $global:choiceFixture.Command -and $global:choiceFixture.Prompts -eq $case.Answers.Count) ('輸入結尾中止且不提權 '+$case.Name)
  Assert (@(Get-ChoiceLine (Get-RunLog)).Count -eq 1 -and @(Get-ChoiceLine (Get-RunLog))[0] -ceq (Line '讀取輸入失敗' $case.Package 'NUC8i7HVB' $case.Supported '否')) ('輸入結尾寫入讀取輸入失敗 '+$case.Name+'；實際='+((Get-ChoiceLine (Get-RunLog)) -join ' | '))
  Assert ($caught -match '沒有讀到輸入') ('輸入結尾的中止原因清楚 '+$case.Name+'；實際='+$caught)
 }
 # 選包階段讀取輸入失敗維持中止，不提權；只補一份可查的紀錄。
 foreach($stage in @('驅動包提示','型號提示')){
  Set-Package 'good';$global:choiceFixture.Boards=@($(if($stage -eq '型號提示'){''}else{'NUC8i7HVB'}))
  Reset-Run;$global:choiceFixture.ReadFails=$true;$caught='';try{& (Join-Path $core 'start_windows.ps1') *>$null}catch{$caught=$_.Exception.Message}
  Assert ($caught -like 'fixture read failure*' -and -not $global:choiceFixture.Command) ($stage+'讀取失敗維持原錯誤並中止，不提權')
  $text=Get-RunLog
  $expected=if($stage -eq '型號提示'){Line '讀取輸入失敗' '未檢查' '未知' '未知' '否'}else{Line '讀取輸入失敗' '型號與身分相符' 'NUC8i7HVB' $both '否'}
  Assert (@(Get-ChoiceLine $text).Count -eq 1 -and @(Get-ChoiceLine $text)[0] -ceq $expected) ($stage+'讀取失敗寫入分類；實際='+((Get-ChoiceLine $text) -join ' | '))
  Assert ($text.Contains('整輪設定沒有開始') -and $text -notmatch 'typed-secret|Users') ($stage+'讀取失敗紀錄不含錯誤原文或路徑')
 }
 foreach($case in @(@('badprofile','身分檢查失敗',$both),@('badzip','內容檢查失敗',$both),@('none','找不到包','無'))){
  Set-Package $case[0];$global:choiceFixture.Boards=@('NUC8i7HVB');Reset-Run;$caught='';try{& (Join-Path $core 'start_windows.ps1') -NonInteractive -DriverPackagePath $payload *>$null}catch{$caught=$_.Exception.Message}
  Assert ([bool]$caught -and -not $global:choiceFixture.Command) ('參數指定的包不合格維持中止 '+$case[0])
  Assert (@(Get-ChoiceLine (Get-RunLog))[0] -ceq (Line '未詢問' $case[1] 'NUC8i7HVB' $case[2] '否')) ('參數指定的包不合格寫入分類 '+$case[0])
 }
 Set-Package 'good';Reset-Run;$caught='';try{& (Join-Path $core 'start_windows.ps1') -NonInteractive -ConfirmedBoard NUC8i7HNB -ConfirmationComputer $env:COMPUTERNAME *>$null}catch{$caught=$_.Exception.Message}
 Assert ($caught -match '不符' -and @(Get-ChoiceLine (Get-RunLog))[0] -ceq $unknownLine) '選包前的其他中止原因寫未知且保留原錯誤'
 Reset-Run;[IO.Directory]::Delete($reports,$true);Put $reports 'blocked'
 try{$global:choiceFixture.ReadFails=$true;$caught='';try{& (Join-Path $core 'start_windows.ps1') *>$null}catch{$caught=$_.Exception.Message};Assert ($caught -like 'fixture read failure*') '紀錄寫不進去時不掩蓋原錯誤'}finally{[IO.File]::Delete($reports);[void][IO.Directory]::CreateDirectory($reports)}
 # 真 Read-Host：NonInteractive 主機讀取失敗的例外帶有分類。
 $child=Join-Path $fixture 'child.ps1'
 Put $child (@'
param($Hardware,$PackageRoot)
$ErrorActionPreference='Stop'
function Get-CimInstance {param($ClassName,$ErrorAction) [pscustomobject]@{Product='NUC8i7HVB'}}
. $Hardware
try{Select-SetupDriverRequest -PackageRoot $PackageRoot -Interactive $true|Out-Null}catch{Write-SetupAbortedDriverChoice -PackageRoot $PackageRoot -ErrorRecord $_}
'@)
 Reset-Run;$old=$ErrorActionPreference;$ErrorActionPreference='Continue';try{& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $child -Hardware (Join-Path $core 'hardware.ps1') -PackageRoot $package *>$null}finally{$ErrorActionPreference=$old}
 Assert (@(Get-ChoiceLine (Get-RunLog))[0] -ceq (Line '讀取輸入失敗' '型號與身分相符' 'NUC8i7HVB' $both '否')) '真 Read-Host 讀取失敗寫入分類'
 # 真 Read-Host 加上會結束的重導輸入：每個提示讀到結尾的分類。替身的「沒有輸出物件」須與此一致。
 $eofChild=Join-Path $fixture 'eof_child.ps1'
 Put $eofChild (@'
param($Hardware,$PackageRoot,$Board,$Out)
$ErrorActionPreference='Stop'
$script:board=if($Board -eq 'none'){''}else{$Board}
function Get-CimInstance {param($ClassName,$ErrorAction) [pscustomobject]@{Product=$script:board}}
. $Hardware
try{
 $request=Select-SetupDriverRequest -PackageRoot $PackageRoot -Interactive $true
 [IO.File]::WriteAllText($Out,'done|'+[bool]$request.DriverPackagePath+'|'+(Resolve-SetupDriverChoice -Record $request.SelectionRecord).Text)
}catch{
 Write-SetupAbortedDriverChoice -PackageRoot $PackageRoot -ErrorRecord $_
 $log=@(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'reports') -Filter 'Setup-*.log')[0]
 [IO.File]::WriteAllText($Out,'stopped|False|'+@([IO.File]::ReadAllLines($log.FullName))[0])
}
'@)
 foreach($case in @(
  @{Name='相鄰包';Kind='good';Board='NUC8i7HVB';Keys='';Expected=('stopped|False|'+(Line '讀取輸入失敗' '型號與身分相符' 'NUC8i7HVB' $both '否'))}
  @{Name='相鄰包型號未對上';Kind='good';Boards=@('NUC8i7HNB');Board='NUC8i7HVB';Keys='';Expected=('stopped|False|'+(Line '讀取輸入失敗' '型號未對上' 'NUC8i7HVB' 'NUC8i7HNB' '否'))}
  @{Name='P 之後';Kind='good';Board='NUC8i7HVB';Keys="p`r`n";Expected=('done|False|'+(Line '讀取輸入失敗' '型號與身分相符' 'NUC8i7HVB' $both '否'))}
  @{Name='重新輸入路徑';Kind='badzip';Board='NUC8i7HVB';Keys="y`r`n";Expected=('done|False|'+(Line '讀取輸入失敗' '內容檢查失敗' 'NUC8i7HVB' $both '否'))}
  @{Name='找不到包';Kind='none';Board='NUC8i7HVB';Keys='';Expected=('done|False|'+(Line '讀取輸入失敗' '找不到包' 'NUC8i7HVB' '無' '否'))}
  @{Name='型號提示';Kind='good';Board='none';Keys='';Expected=('done|False|'+(Line '讀取輸入失敗' '沒有對應的驅動設定檔' '未知' '未知' '否'))}
  @{Name='型號確認';Kind='good';Board='none';Keys="1`r`n";Expected=('done|False|'+(Line '讀取輸入失敗' '沒有對應的驅動設定檔' '未知' '未知' '否'))}
  @{Name='對照：真 Enter 不是輸入結尾';Kind='good';Board='NUC8i7HVB';Keys="`r`n";Expected=('done|True|'+(Line '選用' '檢查通過' 'NUC8i7HVB' $both '否'))}
 )){
  Set-Package $case.Kind $(if($case.Boards){$case.Boards}else{@('NUC8i7HVB','NUC8i7HNB')});Reset-Run
  $keys=Join-Path $fixture 'keys.txt';$out=Join-Path $fixture 'eof_result.txt';[IO.File]::WriteAllBytes($keys,[Text.Encoding]::ASCII.GetBytes($case.Keys));[IO.File]::Delete($out)
  $line='"powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$eofChild+'" -Hardware "'+(Join-Path $core 'hardware.ps1')+'" -PackageRoot "'+$package+'" -Board '+$case.Board+' -Out "'+$out+'" < "'+$keys+'" > nul 2>&1"'
  $null=(Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList ('/d /s /c '+$line) -NoNewWindow -PassThru -Wait)
  $actual=if(Test-Path -LiteralPath $out){[IO.File]::ReadAllText($out)}else{'沒有結果'}
  Assert ($actual -ceq $case.Expected) ('真 Read-Host 讀到輸入結尾 '+$case.Name+'；實際='+$actual)
 }
 # 續跑：不重新詢問；沿用同機同帳號紀錄，缺少或被改就寫未知。
 function Invoke-Restart{$global:choiceFixture.Admin=$true;$global:choiceFixture.Prompts=0;$script:restartError='';$script:restartOutput='';try{$script:restartOutput=(@(& (Join-Path $core 'start_windows.ps1') -AfterRestart *>&1)|ForEach-Object {[string]$_}) -join "`n"}catch{$script:restartError=$_.Exception.Message}}
 $result=Join-Path $reports 'Setup-Result.json'
 foreach($case in @(@{Answers=@('n');Line=(Line '輸入 N 略過' '型號與身分相符' 'NUC8i7HVB' $both '否')},@{Answers=@('');Line=(Line '選用' '檢查通過' 'NUC8i7HVB' $both '否')})){
  Set-Package 'good';$global:choiceFixture.Boards=@('NUC8i7HVB');Invoke-Entry $case.Answers;Invoke-Elevated
  $saved=Get-SavedChoice
  Invoke-Restart
  Assert (-not $restartError -and $global:choiceFixture.Prompts -eq 0) ('續跑不重新詢問；'+$restartError)
  Assert ($restartOutput.Contains('續跑沿用前次選包，未重新詢問') -and @(Get-ChoiceLine $restartOutput).Count -eq 1 -and @(Get-ChoiceLine $restartOutput)[0] -ceq $case.Line) ('續跑顯示前次選擇；實際='+((Get-ChoiceLine $restartOutput) -join ' | '))
  Assert ((Get-SavedChoice) -ceq $saved) '續跑更新結果檔後仍保留前次選擇'
 }
 foreach($value in @($null,'','未知','garbage',$skip,($pick+"`n"),$pick.Replace('v1;','v2;'),$pick.Replace('NUC8i7HVB','C:\Users\x'),@($pick,$pick),(,$pick),123)){
  Invoke-Entry @('');Invoke-Elevated;$json=Get-Content -LiteralPath $result -Raw -Encoding UTF8|ConvertFrom-Json
  if($null -eq $value){$json.PSObject.Properties.Remove('DriverChoice')}else{$json.DriverChoice=$value}
  $json|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $result -Encoding UTF8
  Invoke-Restart
  Assert (-not $restartError -and @(Get-ChoiceLine $restartOutput).Count -eq 1 -and @(Get-ChoiceLine $restartOutput)[0] -ceq $unknownLine) ('續跑紀錄缺少或被改寫未知；'+$restartError+' '+((Get-ChoiceLine $restartOutput) -join ' | '))
 }
 . (Join-Path $core 'hardware.ps1')
 Invoke-Entry @('');Invoke-Elevated;$hardware=Get-SetupHardwareProfile -UICulture 'en-US' -DriverPackagePath $payload
 Assert ((Get-SetupSavedDriverChoice -ResultPath $result -Hardware $hardware).Record -ceq $pick) '同機同帳號可讀回前次選擇'
 foreach($value in @((,$skip),@($skip,$skip),$null,123)){Assert ($null -eq (ConvertFrom-SetupDriverChoiceRecord -Record $value)) '非文字內容一律視為沒有結果'}
 foreach($field in @('Computer','UserSID')){$json=Get-Content -LiteralPath $result -Raw -Encoding UTF8|ConvertFrom-Json;$json.$field='other';$copy=Join-Path $fixture ($field+'.json');$json|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $copy -Encoding UTF8;Assert ((Get-SetupSavedDriverChoice -ResultPath $copy -Hardware $hardware).Text -ceq $unknownLine) ('不沿用其他電腦或帳號的前次選擇 '+$field)}
 Assert ((Get-SetupSavedDriverChoice -ResultPath (Join-Path $fixture 'missing.json') -Hardware $hardware).Text -ceq $unknownLine) '沒有續跑紀錄時寫未知'
 Put (Join-Path $fixture 'broken.json') '{ broken'
 Assert ((Get-SetupSavedDriverChoice -ResultPath (Join-Path $fixture 'broken.json') -Hardware $hardware).Text -ceq $unknownLine) '續跑紀錄損毀時寫未知'
 . (Join-Path $core 'paths.ps1')
 foreach($library in @('configuration_library.ps1','after_restart_library.ps1')){. (Join-Path $core $library)}
 Invoke-Entry @('n');Invoke-SetupConfiguration -Hardware $hardware -UserName fixture *>$null
 Assert-Log $unknownLine '呼叫端沒有帶入選包結果時寫未知'
 $direct=(@(Invoke-SetupAfterRestart -Hardware $hardware *>&1)|ForEach-Object {[string]$_}) -join "`n"
 Assert (@(Get-ChoiceLine $direct).Count -eq 1 -and @(Get-ChoiceLine $direct)[0] -ceq $unknownLine) '續跑呼叫端沒有帶入選包結果時寫未知'
 foreach($flag in @('AfterRestart','VerifyOnly')){$rejected=$false;$flags=@{};$flags[$flag]=$true;try{& (Join-Path $core 'start_windows.ps1') @flags -DriverPackagePath $payload *>$null}catch{$rejected=$true};Assert $rejected ('續跑與只驗證仍拒絕新的選包 '+$flag)}
}finally{Remove-Variable choiceFixture -Scope Global -ErrorAction SilentlyContinue;if([IO.Path]::GetFullPath($fixture).StartsWith([IO.Path]::GetFullPath($env:TEMP),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue}}
