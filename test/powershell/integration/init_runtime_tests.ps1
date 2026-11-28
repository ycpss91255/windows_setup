#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
function Reject([scriptblock]$Action,[string]$Name){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed $Name}
$library=Join-Path $root 'modules/init/init_entry_library.ps1'
Assert (Test-Path -LiteralPath $library) 'Init全部路線由原始具名來源執行且保留入口路徑'
. $library
$fixture=[IO.Path]::GetFullPath((Join-Path $env:TEMP ('init_runtime_'+[guid]::NewGuid().ToString('N'))));$module=Join-Path $fixture 'source/modules/init';[void][IO.Directory]::CreateDirectory($module)
$fixture=[IO.Path]::GetFullPath($fixture);$module=[IO.Path]::GetFullPath($module)
Copy-Item -LiteralPath (Join-Path $root 'modules/init/oobe_library.ps1') -Destination $module
[IO.File]::WriteAllText((Join-Path $module 'cleanup_oobe.ps1'),'$global:initCleanupCalls++')
$entry=Join-Path $module "入口 ' 中文.ps1";[IO.File]::WriteAllText($entry,'param($ExpectedUserSID,$SshScriptPath);[pscustomobject]@{SID=$ExpectedUserSID;SSH=$SshScriptPath}')
$oldData=$env:ProgramData;$oldWindows=$env:WINDIR;$fakeWindows=Join-Path $fixture 'Windows';[void][IO.Directory]::CreateDirectory((Join-Path $fakeWindows 'System32/Sysprep'));$sysprep=Join-Path $fakeWindows 'System32/Sysprep/Sysprep.exe';[IO.File]::WriteAllText($sysprep,'never executed')
function ResetCase {
 $env:ProgramData=Join-Path $fixture ([guid]::NewGuid().ToString('N'));$env:WINDIR=$fakeWindows
 $script:native=[pscustomobject]@{Sid='S-1-5-21-1-2-3-1001';UserSID='S-1-5-21-1-2-3-1001';IsAdministrator=$true;SessionId=44;Is64Bit=$true;Architecture='AMD64'}
 $script:ownerExit=0;$script:image='IMAGE_STATE_COMPLETE';$script:desktop=$true;$script:handled=$false;$script:sMode=0;$script:registryAnswer='';$script:runningSysprep=$false;$script:processExit=0;$script:copyFailure=$false;$script:userEnabled=$true;$script:queue=New-Object 'Collections.Generic.Queue[object]';$script:starts=@();$global:initCleanupCalls=0
}
function Get-SetupInitNativeIdentity {return $script:native}
function Get-SetupInitPreparationFacts {param($Identity);return @{ReadSucceeded=$true;Build=26200;ProductType=1;IsWinPE=$false;OobeApiSucceeded=$true;OobeComplete=($script:image -eq 'IMAGE_STATE_COMPLETE');SetupInProgress=0;OobeInProgress=0;OobeProcessInSession=$false;SetupProcessInSession=$false;ProfileMatches=$true;LocalBuiltin=($script:native.Sid -match '-500$')}}
function Get-ItemProperty {param($Path,$ErrorAction);switch -Wildcard ($Path){'*Setup\State'{[pscustomobject]@{ImageState=$script:image}} '*CI\Policy'{[pscustomobject]@{SkuPolicyRequired=$script:sMode}} default{[pscustomobject]@{UnattendFile=$script:registryAnswer}}}}
function Get-CimInstance {param($ClassName,$Filter);@([pscustomobject]@{SessionId=44;ProcessId=1},[pscustomobject]@{SessionId=99;ProcessId=2})}
function Invoke-CimMethod {param($InputObject,$MethodName);[pscustomobject]@{ReturnValue=$script:ownerExit;Sid=$(if($script:desktop){$script:native.Sid}else{'other'})}}
function Invoke-InitProvisioningEntry {param($SourceRoot,$StageRoot,$ResumeStatePath,$ExpectedUserSID);$script:provisioning=@{SourceRoot=$SourceRoot;StageRoot=$StageRoot;ResumeStatePath=$ResumeStatePath;ExpectedUserSID=$ExpectedUserSID};return $script:handled}
function Assert-InitProvisioningAsset {param($AssetRoot);return @{PackageSHA256='fixture'}}
function Get-LocalUser {param($SID,$ErrorAction);if($SID){[pscustomobject]@{Name='fixture';Enabled=$script:userEnabled}}else{[pscustomobject]@{Name='existing'}}}
function Get-Process {param($Name,$ErrorAction);if($script:runningSysprep){[pscustomobject]@{Name='sysprep'}}}
function Test-SetupInitInteractiveHost {return $true}
function Read-Host {param($Prompt,[switch]$AsSecureString);if(-not $script:queue.Count){throw 'unexpected prompt'};return $script:queue.Dequeue()}
function Protect-InitFolder {param($Path);if(-not $Path.StartsWith($fixture)){throw 'outside TEMP'};$script:protected=$Path}
function Start-Process {param($FilePath,$Verb,$ArgumentList,[switch]$Wait,[switch]$PassThru,$WindowStyle);$script:starts+=@{FilePath=$FilePath;Verb=$Verb;ArgumentList=$ArgumentList};[pscustomobject]@{ExitCode=$script:processExit}}
function Copy-Item {param($LiteralPath,$Destination);if($script:copyFailure){throw 'fixture copy failure'};Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters}
function New-LocalUser {throw 'must never create real accounts'}
function Restart-Computer {throw 'must never reboot'}
function Start-SshService {throw 'Init must not install SSH'}
function RunInit {param([string]$ExpectedUserSID='');Invoke-SetupInit -EntryPath $entry -ModuleRoot $module -ExpectedUserSID $ExpectedUserSID}
function AuditCase {ResetCase;$script:native.Sid='S-1-5-21-1-2-3-500';$script:native.UserSID=$script:native.Sid;$script:ownerExit=0;$script:image='IMAGE_STATE_UNDEPLOYABLE'}
function Passwords([string]$Second='fixture&<密碼'){$script:first=ConvertTo-SecureString 'fixture&<密碼' -AsPlainText -Force;$script:second=ConvertTo-SecureString $Second -AsPlainText -Force;foreach($item in @('YES','fixture_user',$script:first,$script:second)){$script:queue.Enqueue($item)}}
function Disposed($Value){try{$copy=$Value.Copy();$copy.Dispose();return $false}catch{return $true}}
try{
 ResetCase;$script:handled=$true;RunInit
  $actualRoot=[string]$script:provisioning.SourceRoot;$expectedRoot=Join-Path $fixture 'source'
 $safeActual=if($actualRoot.StartsWith($fixture,[StringComparison]::OrdinalIgnoreCase)){'<FIXTURE>'+$actualRoot.Substring($fixture.Length)}else{'<outside fixture; length='+$actualRoot.Length+'>'}
 Assert ($actualRoot -eq $expectedRoot -and -not $script:starts.Count) ('ShiftF10 provisioning fastpath保留且不進legacy提示; sourceRoot='+$safeActual+' expectedRoot=<FIXTURE>\source starts='+$script:starts.Count)
 Invoke-SetupInit -EntryPath $entry -ModuleRoot $module -ResumeStatePath (Join-Path $fixture 'resume.json') -ExpectedUserSID fixture_expected
 Assert ($script:provisioning.ResumeStatePath -eq (Join-Path $fixture 'resume.json') -and $script:provisioning.ExpectedUserSID -eq 'fixture_expected') 'F10續跑狀態及預期SID原樣傳遞'
 ResetCase;RunInit;Assert (-not $script:starts.Count -and -not(Test-Path $env:ProgramData)) '正式桌面不重設帳號、不需第二Init或SSH'
 ResetCase;Reject {RunInit -ExpectedUserSID 'other'} 'ExpectedSID變更立即拒絕'
 ResetCase;$script:native.IsAdministrator=$false;RunInit
 $command=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($script:starts[0].ArgumentList -split '-EncodedCommand ')[1]));$result=& ([scriptblock]::Create($command))
 Assert ($result.SID -eq $script:native.Sid -and $command.Contains($entry.Replace("'","''"))) '提權使用顯式EntryPath而非library，保留中文空白單引號'
 ResetCase;$script:userEnabled=$false;Reject {RunInit} '停用正式帳號拒絕'
 AuditCase;$script:ownerExit=0;$script:image='IMAGE_STATE_COMPLETE';Reject {RunInit} '一般內建Administrator桌面拒絕'
 ResetCase;$script:ownerExit=0;$script:image='UNKNOWN';Reject {RunInit} '未知setup state拒絕'
 ResetCase;$script:native.Is64Bit=$false;Reject {RunInit} '非x64流程拒絕'
 ResetCase;$script:native.Sid='S-1-5-18';Reject {RunInit} 'SYSTEM不從失敗F10路線落入Audit寫入'
 AuditCase;$script:desktop=$false;Reject {RunInit} 'Audit不是目前桌面owner拒絕'
 AuditCase;$script:ownerExit=5;Reject {RunInit} 'native owner query failure cannot reuse matching SID';$entries=@(Get-ChildItem -LiteralPath $env:ProgramData -Force -ErrorAction SilentlyContinue);$records=@(Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'windows_setup_init_diagnostics') -Force -ErrorAction SilentlyContinue)
 Assert ($script:queue.Count -eq 0 -and ($entries|ForEach-Object Name) -join ',' -ceq 'windows_setup_init_diagnostics' -and $records.Count -eq 1 -and $records[0].Name -like 'init_reject_*.json' -and [IO.File]::ReadAllText($records[0].FullName) -notmatch 'S-1-5-' -and [IO.File]::ReadAllText($records[0].FullName) -match '"DesktopOwned":\s*false') 'owner failure performs no prompt or setup write; only the SID-free reject diagnostic record is written'
 AuditCase;$script:queue.Enqueue('no');Reject {RunInit} '未同意帳號及OOBE準備零寫入'
 AuditCase;$script:queue.Enqueue('YES');$script:runningSysprep=$true;Reject {RunInit} '既有Sysprep程序拒絕'
 AuditCase;$script:queue.Enqueue('YES');$script:sMode=1;Reject {RunInit} 'SMode拒絕'
 AuditCase;$script:queue.Enqueue('YES');Move-Item -LiteralPath $sysprep -Destination ($sysprep+'.disabled')
 try{Reject {RunInit} '缺少Sysprep不建立設定'}finally{Move-Item -LiteralPath ($sysprep+'.disabled') -Destination $sysprep}
 AuditCase;$script:queue.Enqueue('YES');$oem=Join-Path $fakeWindows 'Panther/unattend.xml';[void][IO.Directory]::CreateDirectory((Split-Path $oem -Parent));[IO.File]::WriteAllText($oem,'OEM fixture')
 try{Reject {RunInit} '既有answer檔案不覆寫'}finally{Remove-Item -LiteralPath $oem}
 AuditCase;$script:queue.Enqueue('YES');$script:registryAnswer=Join-Path $fixture 'OEM.xml';Reject {RunInit} '既有answer registry拒絕'
 AuditCase;$script:queue.Enqueue('YES');[void][IO.Directory]::CreateDirectory((Join-Path $env:ProgramData 'NUC-Init'));Reject {RunInit} '既有安全stage不覆寫'
 AuditCase;foreach($i in @('YES','existing')){$script:queue.Enqueue($i)};Reject {RunInit} '既有帳號名稱拒絕'
 AuditCase;Passwords 'different';Reject {RunInit} '密碼不符不寫answer'
 Assert ((Disposed $script:first) -and (Disposed $script:second) -and -not(Test-Path (Join-Path $env:ProgramData 'NUC-Init/answer.xml'))) '密碼錯誤仍釋放SecureString且不寫明文'
 AuditCase;Passwords;$script:copyFailure=$true;Reject {RunInit} '依賴複製失敗如實拒絕'
 Assert ((Disposed $script:first) -and (Disposed $script:second)) '寫入前錯誤仍finally清理密碼'
 AuditCase;Passwords;RunInit
 $stage=Join-Path $env:ProgramData 'NUC-Init';$answer=[IO.File]::ReadAllText((Join-Path $stage 'answer.xml'))
 Assert ($script:starts.Count -eq 1 -and $script:starts[0].FilePath -eq $sysprep -and $script:starts[0].ArgumentList -like '/oobe /quit /unattend:*' -and $script:starts[0].ArgumentList -notmatch '/reboot|/generalize') 'Audit只準備sysprep不自動重新開機或generalize'
 Assert ($answer.Contains('fixture_user') -and -not $answer.Contains('fixture&<密碼') -and (Test-Path (Join-Path $stage 'cleanup_oobe.ps1'))) 'Audit answer採原編碼算法並複製明確ModuleRoot清理依賴'
 Assert ((Disposed $script:first) -and (Disposed $script:second)) 'Audit成功也finally釋放SecureString'
 AuditCase;Passwords;$script:processExit=5;Reject {RunInit} 'sysprep失敗不假通過'
 Assert ($global:initCleanupCalls -eq 1) 'sysprep失敗呼叫stage自己的清理入口'
}finally{$env:ProgramData=$oldData;$env:WINDIR=$oldWindows}
Write-Host 'ALL PASS: Init original-source paths with TEMP/mocked APIs; no system accounts, SSH, sysprep or reboot executed.'
