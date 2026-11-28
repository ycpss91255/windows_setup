#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Name}}
function Reject([scriptblock]$Action,[string]$Name){$caught=$false;try{& $Action|Out-Null}catch{$caught=$true};Assert $caught $Name}
$library=Join-Path $root 'core/verification_library.ps1'
Assert (Test-Path $library) '總驗收可由具名函式安全載入'
. (Join-Path $root 'core/hardware.ps1')
. (Join-Path $root 'core/verification.ps1')
. $library
$tokens=$null;$errors=$null
$entry=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'core/verify_only.ps1'),[ref]$tokens,[ref]$errors)
Assert (@($entry.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-SetupVerification'},$true)).Count -eq 1) '正式入口呼叫具名驗收彙整一次'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('verify_aggregate_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
$script:fixtureScripts=Join-Path $fixture 'scripts';[void][IO.Directory]::CreateDirectory($script:fixtureScripts)
foreach($name in @('apply_uac_settings.ps1','apply_debloat.ps1','audit_nuc.ps1','initialize_ssh_client.ps1','apply_lan_ping_settings.ps1','apply_hosts_sync.ps1','apply_privacy_settings.ps1','apply_display_settings.ps1','apply_theme_settings.ps1','desktop_icon_layout.ps1','apply_pagefile_settings.ps1','apply_copilot_settings.ps1','apply_amd_privacy_settings.ps1','apply_start_menu_settings.ps1','apply_input_method_settings.ps1','apply_terminal_hotkey.ps1','remove_setup_residue.ps1','remove_one_drive.ps1','apply_explorer_settings.ps1','apply_power_settings.ps1')){Copy-Item -LiteralPath (Join-Path $root 'test/powershell/fixtures/verification_module.ps1') -Destination (Join-Path $script:fixtureScripts $name)}
[IO.File]::WriteAllText((Join-Path $script:fixtureScripts 'autologon_library.ps1'),'function Get-SetupAutologonRestoreVerification {param($ReportPath) if($ReportPath -ne (Join-Path $env:ProgramData ''NUC8-Setup\Autologon-Result.json'')){throw ''unexpected autologon report''};if($global:AggregateFixtureMode -eq ''AutologonRestored''){return ''fixture autologon restored''};throw ''fixture autologon restore rejected''}',(New-Object Text.UTF8Encoding($true)))
Copy-Item -LiteralPath (Join-Path $root 'test/powershell/fixtures/mdns_verification_module.ps1') -Destination (Join-Path $script:fixtureScripts 'apply_mdns_settings.ps1')
$global:MdnsVerificationCalls=0;$global:MdnsVerificationFixture='Pass'
$script:fixtureApps=Join-Path $fixture 'apps.txt';[IO.File]::WriteAllText($script:fixtureApps,'Fixture.App')
@'
function Invoke-SetupDriverVerification {param($DriverRoot,$VerificationRunId) [pscustomobject]@{Success=($global:AggregateFixtureMode -notin @('False','Throw','Missing','Stale','WrongComputer','WrongUser'));VerificationRunId=$VerificationRunId;Computer=[Environment]::MachineName;UserSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Targets=@([pscustomobject]@{Status='Current'})}}
'@|Set-Content -LiteralPath (Join-Path $script:fixtureScripts 'driver_installation_library.ps1') -Encoding UTF8
function Resolve-NucPath {param($Name) if($Name -eq 'debloat_apps.txt'){return $script:fixtureApps};if($Name -eq 'Verification-Result.json'){return Join-Path $env:ProgramData 'aggregate.json'};return Join-Path $script:fixtureScripts $Name}
function Read-SetupUpdateResult {param($CommonDataRoot,$LegacyRoot,$UserSid,$Computer) Get-Content (Join-Path $env:ProgramData 'NUC8-Setup/WindowsUpdate/WindowsUpdate-Result.json') -Raw|ConvertFrom-Json}
function Invoke-SetupGuiFreshVerification {param($PackageRoot,$Role)
 if($global:AggregateFixtureMode -in @('NoDisplay','UntypedGui') -and $Role -in @('Display','Icons')){$gui=[InvalidOperationException]::new('未偵測到螢幕，無法驗收解析度與圖示');if($global:AggregateFixtureMode -eq 'NoDisplay'){$gui.Data['SetupGuiStatus']='Unverified'};throw $gui}
 if($Role -eq 'Taskbar'){return [pscustomobject]@{Success=($global:AggregateFixtureMode -ne 'Throw');Configured=($global:AggregateFixtureMode -ne 'Throw');BindingMatches=$true;RequiresNextSignIn=($global:AggregateFixtureMode -eq 'Throw');Status=$(if($global:AggregateFixtureMode -eq 'Throw'){'PendingSignIn'}else{'Confirmed'})}}
 if($Role -eq 'Start'){return (& (Resolve-NucPath 'apply_start_menu_settings.ps1') -VerifyOnly)}
 if($Role -notin @('Display','Theme','Icons')){throw 'unexpected fixture role'}
 Invoke-FreshVerification -ScriptPath (Resolve-NucPath $(if($Role -eq 'Icons'){'desktop_icon_layout.ps1'}else{'apply_'+$Role.ToLowerInvariant()+'_settings.ps1'})) -ReportPath (Join-Path $env:ProgramData $(if($Role -eq 'Icons'){'NUC8-Setup/IconLayout-Result.json'}else{'NUC8-Setup/'+$Role+'-Verification.json'})) -Arguments @{VerifyOnly=$true}
}
function Get-CimInstance {param($ClassName,$Filter) [pscustomobject]@{State=$(if($global:AggregateFixtureMode -eq 'Throw'){'Stopped'}else{'Running'});StartMode='Auto'}}
function Get-SetupSSHFirewallStatus {[pscustomobject]@{Passed=($global:AggregateFixtureMode -ne 'Throw');Detail='fixture'}}
function powercfg.exe {'AC Power Setting Index: 0x00000000'}
function Get-ItemProperty {param($Path,$ErrorAction)
 $values=@{AutoAdminLogon='1';DefaultUserName=$env:USERNAME;SearchOnTaskbarMode=0;AllowNewsAndInterests=0;ShowTaskViewButton=0;Hidden=1;ShowSuperHidden=0}
 foreach($id in @('{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}','{20D04FE0-3AEA-1069-A2D8-08002B30309D}','{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}','{645FF040-5081-101B-9F08-00AA002F954E}')){$values[$id]=0}
 if($global:AggregateFixtureMode -like 'Autologon*'){$values.AutoAdminLogon='0'}
 if($global:AggregateFixtureMode -like 'TaskView*'){$values.ShowTaskViewButton=1;if($global:AggregateFixtureMode -eq 'TaskViewMachinePolicy'){$values.HideTaskViewButton=1}}
 if($global:AggregateFixtureMode -eq 'Throw'){$values.Hidden=0;$values.AutoAdminLogon='0';$values.NUC8FinalizeTaskbar='pending';$values['{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}']=1}
 [pscustomobject]$values
}
function Get-PnpDevice {param([switch]$PresentOnly) if($global:AggregateFixtureMode -eq 'Throw'){[pscustomobject]@{Status='Error'}}}
function Get-ChildItem {param($LiteralPath,[switch]$Force,[switch]$Directory,$ErrorAction) if($Directory){return Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $LiteralPath -Directory -Force:$Force};if($global:AggregateFixtureMode -eq 'Throw'){[pscustomobject]@{Attributes=0;Name='fixture.txt'}};if($global:AggregateFixtureMode -eq 'HiddenDesktop'){[pscustomobject]@{Attributes=[IO.FileAttributes]::Hidden;Name='hidden.txt'}};if($global:AggregateFixtureMode -eq 'SystemDesktop'){[pscustomobject]@{Attributes=([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System);Name='desktop.ini'}}}
function Get-AppxPackage {param([switch]$AllUsers) if($global:AggregateFixtureMode -eq 'Throw'){[pscustomobject]@{Name='Fixture.App';PackageUserInformation=@([pscustomobject]@{InstallState='Installed'})}}}
function Get-AppxProvisionedPackage {param([switch]$Online) if($global:AggregateFixtureMode -eq 'Throw'){[pscustomobject]@{DisplayName='Fixture.App'}}}
function Test-SetupDriverPayload {param($Hardware,$DriverPackagePath) if($global:AggregateFixtureMode -eq 'Throw'){throw 'fixture invalid driver'};[pscustomobject]@{Status='Passed'}}
function Test-Path {param($Path,$LiteralPath,$PathType) if($Path -like 'HKLM:*'){return ($global:AggregateFixtureMode -eq 'Throw')};Microsoft.PowerShell.Management\Test-Path @PSBoundParameters}
$previousProgramData=$env:ProgramData
try{
 foreach($mode in @('Pass','False','Throw','Missing','Stale','WrongComputer','WrongUser','DebloatFeatureFailure')){
  $global:AggregateFixtureMode=$mode;$env:ProgramData=Join-Path $fixture $mode
  $data=Join-Path $env:ProgramData 'NUC8-Setup';[void][IO.Directory]::CreateDirectory((Join-Path $data 'WindowsUpdate'))
  [IO.File]::WriteAllText((Join-Path $data 'TaskbarLayout.xml'),'<Layout><TaskbarPinList><DesktopApp DesktopApplicationID="MSEdge" /></TaskbarPinList></Layout>')
  [IO.File]::WriteAllText((Join-Path $data 'WindowsUpdate/WindowsUpdate-Result.json'),'{"Selected":0,"Updates":[],"CompletedAt":"fixture"}')
  $hardware=Get-SetupHardwareProfile -BoardProduct 'NUC8i7HVB' -UICulture zh-TW -DriverPackagePath $fixture
  $id=[guid]::NewGuid().ToString()
  if($mode -eq 'Pass'){Invoke-SetupVerification -Hardware $hardware -DriverPackagePath $fixture -VerificationRunId $id|Out-Null}
  else{Reject {Invoke-SetupVerification -Hardware $hardware -DriverPackagePath $fixture -VerificationRunId $id} ('安全彙整拒絕 '+$mode)}
  $result=Get-Content (Resolve-NucPath 'Verification-Result.json') -Raw|ConvertFrom-Json
  Assert ($result.VerificationRunId -eq $id -and $result.UserSID -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) ('保留本輪ID及動態身分 '+$mode)
  Assert ($result.Passed -eq ($mode -eq 'Pass')) ('總結果不假通過 '+$mode)
  $driverCheck=@($result.Checks|Where-Object Name -eq '已選驅動官方目標')
  Assert ($driverCheck.Count -eq 1 -and $driverCheck[0].Status -eq $(if($mode -in @('Pass','DebloatFeatureFailure')){'Passed'}else{'Failed'})) ('NUC已選包真正走freshdriver檢查而非被fixture誤略過 '+$mode)
  Assert (@($result.Checks|Where-Object Name -eq '非必要資料分享政策').Count -eq 1) ('保留隱私檢查 '+$mode)
  $powerCheck=@($result.Checks|Where-Object Name -eq '休眠停用（含快速啟動）');Assert ($powerCheck.Count -eq 1 -and $powerCheck[0].Passed -eq ($mode -in @('Pass','DebloatFeatureFailure'))) ('每輪讀取本輪休眠結果 '+$mode)
  $mdnsCheck=@($result.Checks|Where-Object Name -eq 'mDNS 持續公告');Assert ($mdnsCheck.Count -eq 1 -and $mdnsCheck[0].Passed -eq $true) ('每輪真正fresh VerifyOnly公告檢查而非本機解析自證 '+$mode)
  $debloatCheck=@($result.Checks|Where-Object Name -eq '清理功能登錄讀回')
  Assert ($debloatCheck.Count -eq 1) ('每輪有真正Debloat功能fresh讀回 '+$mode)
  if($mode -eq 'DebloatFeatureFailure'){Assert ($debloatCheck[0].Status -eq 'Failed' -and @($result.Checks|Where-Object {$_.Status -eq 'Failed' -and $_.Name -ne '清理功能登錄讀回'}).Count -eq 0) 'Appx空且其他模組全通過時，僅功能讀回失敗就拒絕總成功'}
  $expected=@{Throw='fixture submodule failed';Missing='本輪驗證未產生結果';Stale='驗證結果不是本輪產生';WrongComputer='電腦或使用者不符';WrongUser='電腦或使用者不符'}
  if($expected.ContainsKey($mode)){$detail=($result.Checks|Where-Object Name -eq '非必要資料分享政策').Detail;Assert ($detail.Contains($expected[$mode])) ('失敗原因確實來自預期本輪拒絕 '+$mode)}
 }
 foreach($desktopMode in @('HiddenDesktop','SystemDesktop')){
  $global:AggregateFixtureMode=$desktopMode
  if($desktopMode -eq 'HiddenDesktop'){Reject {Invoke-SetupVerification -Hardware $hardware -DriverPackagePath $fixture -VerificationRunId ([guid]::NewGuid().ToString())} 'aggregation refuses visible hidden-only ordinary desktop file'}else{Invoke-SetupVerification -Hardware $hardware -DriverPackagePath $fixture -VerificationRunId ([guid]::NewGuid().ToString())|Out-Null;Assert $true 'aggregation preserves hidden system desktop.ini'}
  $desktopResult=Get-Content (Resolve-NucPath 'Verification-Result.json') -Raw|ConvertFrom-Json
  $desktopDriver=@($desktopResult.Checks|Where-Object Name -eq '已選驅動官方目標')
  Assert ($desktopDriver.Count -eq 1 -and $desktopDriver[0].Status -eq 'Passed') ('桌面專屬案例不應誤造驅動失敗 '+$desktopMode)
 }
 # #485：個人 ShowTaskViewButton 受系統保護時，工作列模組改寫機器原則 HideTaskViewButton；最終驗收以同一讀回條件判定。
 foreach($taskViewMode in @('TaskViewMachinePolicy','TaskViewNone')){
  $global:AggregateFixtureMode=$taskViewMode
  if($taskViewMode -eq 'TaskViewMachinePolicy'){Invoke-SetupVerification -Hardware $hardware -DriverPackagePath $fixture -VerificationRunId ([guid]::NewGuid().ToString())|Out-Null}else{Reject {Invoke-SetupVerification -Hardware $hardware -DriverPackagePath $fixture -VerificationRunId ([guid]::NewGuid().ToString())} '個人值與機器原則都未隱藏工作檢視按鈕時拒絕總成功'}
  $taskViewResult=Get-Content (Resolve-NucPath 'Verification-Result.json') -Raw|ConvertFrom-Json
  $taskViewCheck=@($taskViewResult.Checks|Where-Object Name -eq '工作檢視按鈕隱藏')
  Assert ($taskViewCheck.Count -eq 1 -and $taskViewCheck[0].Passed -eq ($taskViewMode -eq 'TaskViewMachinePolicy') -and $taskViewCheck[0].Detail.Contains('HideTaskViewButton')) ('工作檢視按鈕驗收接受機器原則讀回並如實列出來源 '+$taskViewMode)
 }
 foreach($guiMode in @('NoDisplay','UntypedGui')){
  $global:AggregateFixtureMode=$guiMode
  Reject {Invoke-SetupVerification -Hardware $hardware -DriverPackagePath $fixture -VerificationRunId ([guid]::NewGuid().ToString())} ('未偵測到螢幕或 GUI 失敗時總驗收不通過 '+$guiMode)
  $guiResult=Get-Content (Resolve-NucPath 'Verification-Result.json') -Raw|ConvertFrom-Json
  $guiChecks=@($guiResult.Checks|Where-Object {$_.Name -in @('實際解析度與縮放','四個圖示的實際排列座標')})
  $expectedStatus=if($guiMode -eq 'NoDisplay'){'Unverified'}else{'Failed'}
  Assert ($guiChecks.Count -eq 2 -and @($guiChecks|Where-Object {$_.Status -cne $expectedStatus -or $_.Passed -isnot [bool] -or $_.Passed -or -not $_.Detail.Contains('未偵測到螢幕')}).Count -eq 0) ('螢幕與圖示檢查狀態如實 '+$guiMode)
  Assert (-not $guiResult.Passed -and $guiResult.SkippedCount -eq 0 -and @($guiResult.Checks|Where-Object {$_.Status -cne 'Passed'}).Count -eq 2) ('未驗證不算通過也不算略過，其他檢查不受影響 '+$guiMode)
 }
 $global:AggregateFixtureMode='Pass'
 $generic=Get-SetupHardwareProfile -BoardProduct 'Other PC' -UICulture en-US
 Invoke-SetupVerification -Hardware $generic -VerificationRunId ([guid]::NewGuid().ToString())|Out-Null
 $result=Get-Content (Resolve-NucPath 'Verification-Result.json') -Raw|ConvertFrom-Json
 $uiClaim=@($result.Checks|Where-Object Name -eq '釘選登入後套用')
 Assert ($uiClaim.Count -eq 0) '無畫面證據不得聲稱釘選已套用'
 Assert ($result.Passed -and $result.SkippedCount -eq 3) '通用英文電腦明確略過NUC驅動AMD與中文座標'
 Assert (@($result.Checks|Where-Object {$_.Status -eq 'Skipped' -and $null -eq $_.Passed}).Count -eq 3) '略過不可冒充Passed'
 foreach($autologonMode in @('AutologonRestored','AutologonRestoreInvalid')){
  $global:AggregateFixtureMode=$autologonMode
  if($autologonMode -eq 'AutologonRestored'){Invoke-SetupVerification -Hardware $generic -VerificationRunId ([guid]::NewGuid().ToString())|Out-Null}
  else{Reject {Invoke-SetupVerification -Hardware $generic -VerificationRunId ([guid]::NewGuid().ToString())} '自動登入未啟用且沒有有效停用結果時拒絕總成功'}
  $result=Get-Content (Resolve-NucPath 'Verification-Result.json') -Raw|ConvertFrom-Json
  $check=@($result.Checks|Where-Object Name -eq '自動登入設定')
  if($autologonMode -eq 'AutologonRestored'){Assert ($result.Passed -and $check.Count -eq 1 -and $check[0].Status -eq 'Skipped' -and $null -eq $check[0].Passed -and $check[0].Detail -ceq 'fixture autologon restored') '已依還原停用自動登入時標示略過而非失敗或通過'}
  else{Assert ($check.Count -eq 1 -and $check[0].Status -eq 'Failed' -and $check[0].Detail.Contains('fixture autologon restore rejected') -and @($result.Checks|Where-Object {$_.Status -eq 'Failed' -and $_.Name -ne '自動登入設定'}).Count -eq 0) '無效停用結果如實記錄失敗原因'}
 }
 $global:AggregateFixtureMode='Pass'
 foreach($publisherMode in @('False','StringTrue','WrongName','WrongStatus','BadRunId','EmptyRunId','RemoteTrue','Duplicate','Missing','Throw')){
  $global:AggregateFixtureMode='Pass';$global:MdnsVerificationFixture=$publisherMode;$beforeCalls=$global:MdnsVerificationCalls
  Reject {Invoke-SetupVerification -Hardware $generic -VerificationRunId ([guid]::NewGuid().ToString())} ('fresh mDNS aggregate refuses '+$publisherMode)
  $result=Get-Content (Resolve-NucPath 'Verification-Result.json') -Raw|ConvertFrom-Json
  $check=@($result.Checks|Where-Object Name -eq 'mDNS 持續公告')
  Assert ($check.Count -eq 1 -and -not $check[0].Passed -and $global:MdnsVerificationCalls -eq ($beforeCalls+1)) ('bad mDNS cannot reuse a prior successful result: '+$publisherMode)
  Assert (@($result.Checks|Where-Object {$_.Status -eq 'Failed' -and $_.Name -ne 'mDNS 持續公告'}).Count -eq 0) ('mDNS negative case fails for intended publisher boundary: '+$publisherMode)
 }
 $global:MdnsVerificationFixture='Pass'
}finally{$env:ProgramData=$previousProgramData;Remove-Variable AggregateFixtureMode -Scope Global -ErrorAction SilentlyContinue}
Write-Host 'ALL PASS: verification aggregator source tests; OS boundaries mocked'
