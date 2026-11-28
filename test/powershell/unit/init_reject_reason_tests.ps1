#Requires -Version 5.1
# 現場重放（#481）：稽核模式 Init 被拒時只顯示「狀態未知」，且沒有記錄當下狀態。擷取來源、未知與限制見 fixtures/nuc_scene_audit_reject/readme.md。
# 第一次被拒時的實際原因未知；本測試只重放事後診斷，其餘為逐條件的合成案例，不宣稱任何一項是現場原因。
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'modules/init/init_entry_library.ps1')
$script:failures=@()
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){$script:failures+=$Name}}
$scene=Get-Content -LiteralPath (Join-Path $root 'test/powershell/fixtures/nuc_scene_audit_reject/scene.json') -Raw -Encoding UTF8|ConvertFrom-Json
function ConvertTo-Facts($Object){$table=@{};foreach($p in $Object.PSObject.Properties){$table[$p.Name]=$p.Value};return $table}
$ready=ConvertTo-Facts $scene.DiagnosticModeFacts
$ready.SetupProcessNames=@();$ready.OobeProcessNames=@();$ready.SysprepProcessIds=@()
$sid=[string]$scene.Sid;$state=[string]$scene.ImageState
function Facts([scriptblock]$Change){$f=$ready.Clone();if($Change){& $Change $f};return $f}
function Route($facts,[string]$Sid=$sid,[string]$State=$state,[bool]$Admin=$true,[bool]$Desktop=$true){Get-InitRoute -Sid $Sid -ImageState $State -IsAdministrator $Admin -DesktopOwned $Desktop -ModeFacts $facts}
function Try-Call([scriptblock]$Block){try{& $Block}catch [Management.Automation.CommandNotFoundException]{return $null}}
function Reasons($facts,[string]$Sid=$sid,[string]$State=$state,[bool]$Admin=$true,[bool]$Desktop=$true){@(Try-Call {Get-InitRouteRejectReasons -Sid $Sid -ImageState $State -IsAdministrator $Admin -DesktopOwned $Desktop -ModeFacts $facts})}

# 1. 現場重放：事後唯讀診斷的事實路由為 PrepareOobe，且不回報拒絕原因。
Assert ((Route $ready -Admin ([bool]$scene.DiagnosticContext.IsAdministrator) -Desktop ([bool]$scene.DiagnosticContext.DesktopOwned)) -ceq [string]$scene.DiagnosticRoute) '現場事後診斷的事實路由為 PrepareOobe'
$r=@(Reasons $ready);Assert ($r.Count -eq 0 -and [bool](Get-Command Get-InitRouteRejectReasons -ErrorAction SilentlyContinue)) '可準備時不回報拒絕原因'

# 2. 逐條件拒絕原因：每個不符條件各有白話說明，不輸出 SID。
$cases=@(
 @{Name='讀取失敗';Change={param($f) $f.ReadSucceeded=$false};Pattern='無法讀取'},
 @{Name='狀態欄位缺漏';Change={param($f) $f.Remove('ProfileMatches')};Pattern='ProfileMatches'},
 @{Name='組建過舊';Change={param($f) $f.Build=22000};Pattern='22000'},
 @{Name='非用戶端版本';Change={param($f) $f.ProductType=3};Pattern='ProductType=3'},
 @{Name='WinPE';Change={param($f) $f.IsWinPE=$true};Pattern='WinPE'},
 @{Name='OOBE API 失敗';Change={param($f) $f.OobeApiSucceeded=$false};Pattern='OOBE 是否完成'},
 @{Name='安裝程序';Change={param($f) $f.SetupProcessInSession=$true;$f.SetupProcessNames=@('setup.exe')};Pattern='setup\.exe'},
 @{Name='OOBE 程序';Change={param($f) $f.OobeProcessInSession=$true;$f.OobeProcessNames=@('msoobe.exe')};Pattern='msoobe\.exe'},
 @{Name='設定檔不符';Change={param($f) $f.ProfileMatches=$false};Pattern='設定檔'},
 @{Name='OOBE 已完成';Change={param($f) $f.OobeComplete=$true};Pattern='OOBE 已完成'},
 @{Name='非本機內建帳號';Change={param($f) $f.LocalBuiltin=$false};Pattern='內建 Administrator'}
)
$seen=@{}
foreach($case in $cases){
 $f=Facts $case.Change;$r=Reasons $f;$text=$r -join '；'
 Assert ((Route $f) -ceq 'RejectUnknownSetupState' -and $r.Count -ge 1 -and $text -match $case.Pattern -and $text -notmatch 'S-1-5-') ('拒絕原因說明：'+$case.Name)
 if($r.Count){$seen[$text]=$true}
}
Assert ($seen.Count -eq $cases.Count) '每個不符條件的說明文字各不相同'
Assert (((Reasons $ready -Desktop $false) -join '') -match '桌面') '非擁有桌面的拒絕原因'
Assert (((Reasons $ready -State 'UNKNOWN_STATE') -join '') -match 'UNKNOWN_STATE') '映像狀態不在可準備清單的拒絕原因'
Assert (((Reasons $ready -Admin $false) -join '') -match '系統管理員') '未以系統管理員權限執行的拒絕原因'
$r=Reasons $ready -Sid 'S-1-5-21-1-2-3-1001' -State 'IMAGE_STATE_COMPLETE';Assert ($r.Count -ge 1 -and ($r -join '') -match '矛盾' -and ($r -join '') -notmatch 'S-1-5-') '正式帳號但 OOBE 未完成的矛盾狀態有說明且不含 SID'
$r=Reasons $null -Sid 'S-1-5-21-1-2-3-1001' -State 'IMAGE_STATE_COMPLETE' -Desktop $false;Assert (($r -join '') -match '桌面') '無狀態事實的舊路徑也說明非擁有桌面'
$f=Facts {param($f) $f.SetupProcessInSession=$true;$f.SetupProcessNames=@('setup.exe','sysprep.exe');$f.ProfileMatches=$false}
$r=Reasons $f;Assert ($r.Count -eq 2 -and ($r -join '') -match 'setup\.exe、sysprep\.exe' -and ($r -join '') -match '取消' -and ($r -join '') -match '設定檔') '多項不符時全部列出，有 sysprep.exe 時附按取消提示'

# 3. 本機紀錄：寫入 ProgramData 下獨立診斷目錄，含當下 ModeFacts 與原因，不含 SID，保留最新 20 份。
$temp=Join-Path ([IO.Path]::GetTempPath()) ('init_reject_record_'+[guid]::NewGuid().ToString('N'))
try{
 [void][IO.Directory]::CreateDirectory($temp)
 $context=[pscustomobject]@{Sid=$sid;UserSID=$sid;IsAdministrator=$true;ImageState=$state;DesktopOwned=$true;ModeFacts=(Facts {param($f) $f.OobeProcessInSession=$true;$f.OobeProcessNames=@('msoobe.exe')})}
 $path=Try-Call {Write-SetupInitRejectRecord -Root $temp -Context $context -Route 'RejectUnknownSetupState' -Reasons @('原因甲','原因乙') -Rechecks 3 -SysprepDialogClosed $false}
 $ok=$path -is [string] -and (Test-Path -LiteralPath $path -PathType Leaf)
 Assert ($ok -and ([IO.Path]::GetDirectoryName($path) -ieq (Join-Path $temp 'windows_setup_init_diagnostics')) -and ([IO.Path]::GetFileName($path) -like 'init_reject_*.json')) '拒絕紀錄寫入 ProgramData 下的 windows_setup_init_diagnostics，不寫 Init 續跑或暫存目錄'
 if($ok){
  $raw=[IO.File]::ReadAllText($path);$json=$raw|ConvertFrom-Json
  Assert ($raw -notmatch 'S-1-5-' -and $json.ImageState -ceq $state -and $json.Route -ceq 'RejectUnknownSetupState' -and $json.BuiltinAdministrator -eq $true -and $json.IsAdministrator -eq $true -and $json.DesktopOwned -eq $true -and $json.Rechecks -eq 3 -and $json.SysprepDialogClosed -eq $false -and (@($json.Reasons) -join '|') -ceq '原因甲|原因乙') '紀錄含路由、映像狀態、帳號類型、桌面、重新檢查次數與原因，不含 SID'
  $names=@($json.ModeFacts.PSObject.Properties|ForEach-Object Name)
  Assert ($json.ModeFacts.OobeProcessInSession -eq $true -and (@($json.ModeFacts.OobeProcessNames) -join ',') -ceq 'msoobe.exe' -and $json.ModeFacts.Build -eq 26300 -and $json.ModeFacts.OobeInProgress -eq 1 -and @($ready.Keys|Where-Object {$_ -notin $names}).Count -eq 0) '紀錄保存當下全部 ModeFacts'
  Assert ([IO.File]::ReadAllBytes($path)[0] -ne 0xEF) '紀錄為 UTF-8 無 BOM'
 }
 $dir=Join-Path $temp 'windows_setup_init_diagnostics'
 if(Test-Path -LiteralPath $dir){1..25|ForEach-Object {[IO.File]::WriteAllText((Join-Path $dir ('init_reject_20200101T0000{0:00}000Z.json' -f $_)),'{}')}}
 $null=Try-Call {Write-SetupInitRejectRecord -Root $temp -Context $context -Route 'RejectUnknownSetupState' -Reasons @('x') -Rechecks 0 -SysprepDialogClosed $false}
 $left=@(Get-ChildItem -LiteralPath $dir -Filter 'init_reject_*.json' -File -ErrorAction SilentlyContinue)
 Assert ($left.Count -eq 20 -and @($left|Where-Object Name -eq ([IO.Path]::GetFileName([string]$path))).Count -eq 1) '紀錄只保留最新 20 份'
 $blocked=Join-Path $temp 'blocked';[IO.File]::WriteAllText($blocked,'file in place of directory')
 $threw=$false;try{$bad=Write-SetupInitRejectRecord -Root $blocked -Context $context -Route 'RejectUnknownSetupState' -Reasons @('x') -Rechecks 0 -SysprepDialogClosed $false}catch{$threw=$true}
 Assert (-not $threw -and $null -eq $bad -and (Get-Command Write-SetupInitRejectRecord -ErrorAction SilentlyContinue)) '紀錄寫入失敗不掩蓋原本的拒絕'
}finally{if($temp.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}}

# 4. 暫時狀態資格：只有安裝／OOBE 程序是唯一不符條件時才短暫重新檢查。
function Transient($facts,[string]$Sid=$sid,[string]$State=$state,[bool]$Admin=$true,[bool]$Desktop=$true){[bool](Try-Call {Test-InitTransientSetupBlocker -Sid $Sid -ImageState $State -IsAdministrator $Admin -DesktopOwned $Desktop -ModeFacts $facts})}
$busyOobe={param($f) $f.OobeProcessInSession=$true;$f.OobeProcessNames=@('msoobe.exe')}
$busySetup={param($f) $f.SetupProcessInSession=$true;$f.SetupProcessNames=@('setuphost.exe')}
Assert (Transient (Facts $busyOobe)) 'OOBE 程序仍在收尾時重新檢查'
Assert (Transient (Facts $busySetup)) '安裝程序仍在收尾時重新檢查'
Assert (Transient (Facts $busySetup) -State 'IMAGE_STATE_UNDEPLOYABLE') '其他可準備映像狀態也重新檢查'
Assert (-not (Transient $ready)) '已可準備時不重新檢查'
Assert (-not (Transient (Facts {param($f) & $busyOobe $f;$f.ProfileMatches=$false}))) '同時有非暫時條件不符時立即拒絕'
Assert (-not (Transient (Facts {param($f) & $busyOobe $f;$f.OobeComplete=$true}))) 'OOBE 已完成不重新檢查'
Assert (-not (Transient (Facts {param($f) $f.ReadSucceeded=$false}))) '讀取失敗不重新檢查'
Assert (-not (Transient (Facts $busyOobe) -Desktop $false)) '非擁有桌面不重新檢查'
Assert (-not (Transient (Facts $busyOobe) -Sid 'S-1-5-21-1-2-3-1001' -State 'IMAGE_STATE_COMPLETE')) '非內建 Administrator 不重新檢查'
Assert (-not (Transient (Facts $busyOobe) -State 'UNKNOWN_STATE')) '未知映像狀態不重新檢查'

# 5. Sysprep 對話框自動關閉資格（合成案例，非現場原因）。
$sysprepOnly={param($f) $f.SetupProcessInSession=$true;$f.SetupProcessNames=@('sysprep.exe');$f.SysprepProcessIds=@(4242)}
function Eligible($facts,[string]$Sid=$sid,[string]$State=$state,[bool]$Admin=$true){[bool](Try-Call {Test-InitSysprepDialogOnlyBlocker -Sid $Sid -ImageState $State -IsAdministrator $Admin -DesktopOwned $true -ModeFacts $facts})}
Assert (Eligible (Facts $sysprepOnly)) '稽核模式且同工作階段只有 sysprep.exe 時可自動關閉'
Assert (Eligible (Facts $sysprepOnly) -State 'IMAGE_STATE_GENERALIZE_RESEAL_TO_AUDIT') '稽核狀態可自動關閉：GENERALIZE_RESEAL_TO_AUDIT'
foreach($s in @('IMAGE_STATE_UNDEPLOYABLE','IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE','IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE','IMAGE_STATE_COMPLETE')){Assert (-not (Eligible (Facts $sysprepOnly) -State $s)) ('非稽核狀態不自動關閉：'+$s)}
Assert (-not (Eligible (Facts {param($f) & $sysprepOnly $f;$f.SetupProcessNames=@('sysprep.exe','setup.exe')}))) 'sysprep.exe 與 setup.exe 並存不自動關閉'
foreach($n in @('setuphost.exe','setupprep.exe')){Assert (-not (Eligible (Facts ([scriptblock]::Create("param(`$f) `$f.SetupProcessInSession=`$true;`$f.SetupProcessNames=@('$n');`$f.SysprepProcessIds=@(4242)"))))) ('不關閉安裝程序：'+$n)}
foreach($n in @('msoobe.exe','CloudExperienceHostBroker.exe')){Assert (-not (Eligible (Facts ([scriptblock]::Create("param(`$f) `$f.SetupProcessInSession=`$true;`$f.SetupProcessNames=@('sysprep.exe');`$f.SysprepProcessIds=@(4242);`$f.OobeProcessInSession=`$true;`$f.OobeProcessNames=@('$n')"))))) ('有 OOBE 程序不自動關閉：'+$n)}
Assert (-not (Eligible (Facts {param($f) & $sysprepOnly $f;$f.ProfileMatches=$false}))) '只有 sysprep.exe 但其他條件不符時不自動關閉'
Assert (-not (Eligible (Facts {param($f) & $sysprepOnly $f;$f.OobeComplete=$true}))) 'OOBE 已完成不自動關閉'
Assert (-not (Eligible (Facts {param($f) & $sysprepOnly $f;$f.LocalBuiltin=$false}))) '非本機內建帳號不自動關閉'
Assert (-not (Eligible (Facts $sysprepOnly) -Sid 'S-1-5-21-1-2-3-1001')) '非內建 Administrator 不自動關閉'
Assert (-not (Eligible (Facts $sysprepOnly) -Admin $false)) '未提權不自動關閉'
Assert (-not (Eligible (Facts {param($f) & $sysprepOnly $f;$f.Remove('SetupProcessNames')}))) '缺少程序名稱的舊事實不自動關閉'
Assert (-not (Eligible (Facts {param($f) & $sysprepOnly $f;$f.SysprepProcessIds=@()}))) '缺少程序識別碼不自動關閉'

# 5b. 實際關閉函式（尚未被模擬）：只對 sysprep 視窗送出關閉要求，不結束其他程序。
Assert ((Try-Call {Close-SetupInitSysprepDialog -ProcessIds @()}) -eq $false) '沒有程序識別碼時不嘗試關閉'
Assert ((Try-Call {Close-SetupInitSysprepDialog -ProcessIds @($PID)}) -eq $false -and -not (Get-Process -Id $PID -ErrorAction SilentlyContinue).HasExited) '非 sysprep 程序不關閉並回報失敗'
Assert ((Try-Call {Close-SetupInitSysprepDialog -ProcessIds @(2147483000)}) -eq $true) '程序已自行結束時視為已關閉，交由重新判斷確認'

# 6. Invoke-SetupInit：拒絕時列出原因並寫紀錄；暫時狀態短暫重新檢查；Sysprep 對話框自動關閉。
$script:prompts=@();$script:writes=0;$script:contexts=@();$script:reads=0;$script:closeCalls=@();$script:closeResult=$true;$script:sleeps=@();$script:records=@()
function New-Context($facts,[string]$Sid=$sid,[string]$State=$state,[bool]$Desktop=$true){[pscustomobject]@{Sid=$Sid;UserSID=$Sid;IsAdministrator=$true;Is64Bit=$true;Architecture='AMD64';ImageState=$State;DesktopOwned=$Desktop;ModeFacts=$facts}}
function Assert-InitProvisioningAsset {param($AssetRoot);return @{PackageSHA256='fixture'}}
function Invoke-InitProvisioningEntry {return $false}
function Get-SetupInitContext {$i=[Math]::Min($script:reads,$script:contexts.Count-1);$script:reads++;return $script:contexts[$i]}
function Close-SetupInitSysprepDialog {param([int[]]$ProcessIds);$script:closeCalls+=,@($ProcessIds);return $script:closeResult}
function Write-SetupInitRejectRecord {param([string]$Root,$Context,[string]$Route,[string[]]$Reasons,[int]$Rechecks,[bool]$SysprepDialogClosed);$script:records+=,@{Root=$Root;Context=$Context;Reasons=$Reasons;Rechecks=$Rechecks;SysprepDialogClosed=$SysprepDialogClosed};return 'C:\ProgramData\windows_setup_init_diagnostics\init_reject_fixture.json'}
function Start-Sleep {param([int]$Seconds,[int]$Milliseconds);$script:sleeps+=$Seconds}
function Get-Process {return @()}
function Get-ItemProperty {return [pscustomobject]@{SkuPolicyRequired=0;UnattendFile=$null}}
function Test-Path {param($LiteralPath,$Path,$PathType);return [bool]($LiteralPath -like '*Sysprep.exe')}
function Test-SetupInitInteractiveHost {return $true}
function Read-Host {param($Prompt,[switch]$AsSecureString);$script:prompts+=@($Prompt);return 'NO'}
function New-Item {$script:writes++;throw 'SAFE_MUTATION_SENTINEL'}
function Start-Process {$script:writes++;throw 'SAFE_NATIVE_SENTINEL'}
function New-LocalUser {$script:writes++;throw 'SAFE_ACCOUNT_SENTINEL'}
function Stop-Process {$script:writes++;throw 'SAFE_KILL_SENTINEL'}
function Get-LocalUser {throw 'credentials must not be collected before consent'}
function Invoke-Case([object[]]$Contexts,[bool]$CloseResult=$true){
 $script:prompts=@();$script:writes=0;$script:contexts=$Contexts;$script:reads=0;$script:closeCalls=@();$script:closeResult=$CloseResult;$script:sleeps=@();$script:records=@()
 try{Invoke-SetupInit -EntryPath (Join-Path $root 'modules/init/initialize_nuc.ps1') -ModuleRoot (Join-Path $root 'modules/init');return ''}catch{return $_.Exception.Message}
}
function Reached{$script:prompts.Count -eq 1 -and $script:prompts[0] -match 'YES' -and $script:writes -eq 0}
$m=Invoke-Case @((New-Context $ready))
Assert ((Reached) -and $script:records.Count -eq 0 -and $script:sleeps.Count -eq 0) '現場事後診斷狀態直接進入同意提示，不重新檢查也不寫紀錄'
$m=Invoke-Case @((New-Context (Facts {param($f) $f.ProfileMatches=$false})))
Assert ($m -match '設定檔' -and $m -match [regex]::Escape($state) -and $m -notmatch 'S-1-5-' -and $m -match 'windows_setup_init_diagnostics' -and $script:sleeps.Count -eq 0 -and $script:prompts.Count -eq 0 -and $script:writes -eq 0) '非暫時條件不符時立即拒絕，訊息列出原因與紀錄位置'
Assert ($script:records.Count -eq 1 -and $script:records[0].Root -ceq $env:ProgramData -and $script:records[0].Context.ModeFacts.ProfileMatches -eq $false -and (@($script:records[0].Reasons) -join '') -match '設定檔' -and $script:records[0].Rechecks -eq 0) '拒絕時把當下 ModeFacts 與原因寫入本機 ProgramData 紀錄'
$m=Invoke-Case @((New-Context (Facts {param($f) $f.ReadSucceeded=$false})))
Assert ($m -match '無法讀取' -and $script:records.Count -eq 1 -and $script:sleeps.Count -eq 0) '讀取失敗時列出原因並寫紀錄'
$m=Invoke-Case @((New-Context $ready -Desktop $false))
Assert ($m -match '桌面' -and $script:records.Count -eq 1 -and $script:sleeps.Count -eq 0) '非擁有桌面時列出原因並寫紀錄'
$m=Invoke-Case @((New-Context (Facts $busyOobe)),(New-Context (Facts $busySetup)),(New-Context $ready))
Assert ((Reached) -and $script:reads -eq 3 -and $script:sleeps.Count -eq 2 -and $script:records.Count -eq 0) '開機初期 OOBE／安裝程序收尾後重新檢查通過並繼續'
$m=Invoke-Case @((New-Context (Facts $busyOobe)))
Assert ($script:sleeps.Count -ge 1 -and $script:sleeps.Count -le 10 -and (($script:sleeps|Measure-Object -Sum).Sum) -le 60 -and $script:prompts.Count -eq 0 -and $script:writes -eq 0) '重新檢查有次數與總時間上限'
Assert ($m -match 'msoobe\.exe' -and $m -match ('重新檢查 '+$script:sleeps.Count+' 次') -and $m -match ('約 '+(($script:sleeps|Measure-Object -Sum).Sum)+' 秒') -and $script:records.Count -eq 1 -and $script:records[0].Rechecks -eq $script:sleeps.Count) '重新檢查仍不符時說明次數與時間並寫紀錄'
$m=Invoke-Case @((New-Context (Facts $busyOobe) -Sid 'S-1-5-21-1-2-3-1001' -State 'IMAGE_STATE_COMPLETE'))
Assert ($script:sleeps.Count -eq 0 -and $script:records.Count -eq 1) '非稽核帳號情境不重新檢查'
$m=Invoke-Case @((New-Context (Facts $sysprepOnly)),(New-Context $ready))
Assert ($script:closeCalls.Count -eq 1 -and @($script:closeCalls[0]).Count -eq 1 -and @($script:closeCalls[0])[0] -eq 4242 -and (Reached) -and $script:sleeps.Count -eq 0) 'Sysprep 對話框只關閉同工作階段的 sysprep.exe 一次，重新判斷後繼續'
$m=Invoke-Case @((New-Context (Facts $sysprepOnly))) -CloseResult $false
Assert ($script:closeCalls.Count -eq 1 -and $m -match '取消' -and $m -match 'init\.cmd' -and $m -match 'windows_setup_init_diagnostics' -and $script:records.Count -eq 1 -and $script:prompts.Count -eq 0 -and $script:writes -eq 0) 'Sysprep 對話框關閉失敗時提示按取消後重跑並寫紀錄'
$m=Invoke-Case @((New-Context (Facts $sysprepOnly)),(New-Context (Facts $sysprepOnly)))
Assert ($script:closeCalls.Count -eq 1 -and $m -match 'sysprep\.exe' -and $m -match '取消' -and $script:records.Count -eq 1 -and $script:records[0].SysprepDialogClosed -eq $true -and $script:prompts.Count -eq 0) '關閉後重讀仍有 sysprep.exe 時不重複關閉並說明原因'
$m=Invoke-Case @((New-Context (Facts {param($f) & $sysprepOnly $f;$f.SetupProcessNames=@('sysprep.exe','setup.exe')})))
Assert ($script:closeCalls.Count -eq 0 -and $m -match 'setup\.exe' -and $script:writes -eq 0) 'setup.exe 並存時不關閉任何程序並說明原因'
$m=Invoke-Case @((New-Context (Facts {param($f) & $sysprepOnly $f;$f.OobeProcessInSession=$true;$f.OobeProcessNames=@('CloudExperienceHostBroker.exe')})))
Assert ($script:closeCalls.Count -eq 0 -and $m -match 'CloudExperienceHostBroker\.exe' -and $script:writes -eq 0) 'OOBE 程序並存時不關閉並說明原因'
$m=Invoke-Case @((New-Context (Facts {param($f) & $sysprepOnly $f;$f.ProfileMatches=$false})))
Assert ($script:closeCalls.Count -eq 0 -and $script:sleeps.Count -eq 0 -and $m -match '設定檔' -and $m -match 'sysprep\.exe') '其他條件不符時不關閉、不等待並列出全部不符條件'
$m=Invoke-Case @((New-Context (Facts $sysprepOnly) -State 'IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE'))
Assert ($script:closeCalls.Count -eq 0 -and $m -match 'sysprep\.exe' -and $script:writes -eq 0) '非稽核狀態不自動關閉 sysprep.exe'

if($script:failures.Count){throw ('FAIL '+$script:failures.Count+'：'+($script:failures -join ' | '))}
Write-Host 'ALL PASS: audit-mode Init reject reasons, local record, bounded recheck and Sysprep dialog; process, registry and account boundaries mocked'
