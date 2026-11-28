#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Message){Write-Host ('@@ASSERT@@'+(@{Name=$Message;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Message}}
function Reject([scriptblock]$Action,[string]$Name,[string]$Pattern=''){$caught=$false;$text='';try{& $Action|Out-Null}catch{$caught=$true;$text=$_.Exception.Message};Assert ($caught -and (-not $Pattern -or $text -match $Pattern)) $Name}
$library=Join-Path $root 'script/test/container_shards.ps1'
Assert (Test-Path -LiteralPath $library -PathType Leaf) '提供容器測試分片程式庫'
. $library

# 分片數：未設變數取預設 3；非整數或超出 1–6 直接失敗，不靜默改用其他值。
$plan=Get-CIContainerShardPlan -Value ''
Assert ($plan.Count -eq 3 -and $plan.Matrix -ceq '[0,1,2]') '未設定分片變數時預設三份'
$plan=Get-CIContainerShardPlan -Value $null
Assert ($plan.Count -eq 3) '分片變數為 null 時預設三份'
$plan=Get-CIContainerShardPlan -Value '1'
Assert ($plan.Count -eq 1 -and $plan.Matrix -ceq '[0]') '設定一份時維持單一容器工作'
$plan=Get-CIContainerShardPlan -Value ' 4 '
Assert ($plan.Count -eq 4 -and $plan.Matrix -ceq '[0,1,2,3]') '設定四份時產生四份矩陣'
foreach($bad in @('0','7','-1','2.5','abc','3a')){Reject {Get-CIContainerShardPlan -Value $bad} ('不合法的分片數 '+$bad+' 必須失敗') '分片數'}

# 以實際倉庫名冊與實測權重證明：每種分片數下各份互不重疊、聯集等於完整名冊，語法檢查只在第 0 份。
. (Join-Path $root 'script/test/ci_runner_library.ps1')
. (Join-Path $root 'script/test/ci_shard_library.ps1')
$roster=@(Get-SetupCISuiteRoster -PackageRoot $root)
$rosterNames=@($roster|ForEach-Object {[string]$_.Name})
Assert ($rosterNames.Count -gt 100) '實際名冊包含全部 unit 與 integration suite'
foreach($count in 1..6){
 $assigned=@(foreach($index in 0..($count-1)){Get-CIContainerShardSuites -PackageRoot $root -ShardIndex $index -ShardCount $count})
 $sorted=@($assigned|Sort-Object);$expected=@($rosterNames|Sort-Object)
 Assert ($assigned.Count -eq $rosterNames.Count -and @($assigned|Select-Object -Unique).Count -eq $assigned.Count -and (($sorted -join '|') -ceq ($expected -join '|'))) ("實際名冊分 $count 份：互不重疊且聯集等於完整名冊")
}
$again=@(Get-CIContainerShardSuites -PackageRoot $root -ShardIndex 1 -ShardCount 3)
$first=@(Get-CIContainerShardSuites -PackageRoot $root -ShardIndex 1 -ShardCount 3)
Assert ($first.Count -gt 0 -and (($first -join '|') -ceq ($again -join '|'))) '同一來源的分派可重現'
$runner=Get-Content -LiteralPath (Join-Path $root 'script/test/ci_runner_library.ps1') -Raw -Encoding UTF8
Assert ($runner -match [regex]::Escape("Select-CISuiteShard -Cases `$cases -ShardIndex `$ShardIndex -ShardCount `$ShardCount -Weights (Get-CISuiteWeights -Path (Join-Path `$PSScriptRoot 'ci_suite_weights.json')) -DefaultWeight 10")) '容器分片與 run_ci 使用同一個分派規則與權重'

# 合併閘門：只有矩陣結果為 success 才通過，失敗、取消、略過或空值都拒絕。
Assert-CIContainerShardsResult -Result 'success';Assert $true '全部分片成功時合併閘門通過'
foreach($state in @('failure','cancelled','skipped','',$null,'Success')){Reject {Assert-CIContainerShardsResult -Result $state} ('分片結果為「'+$state+'」時合併閘門必須失敗') '不能視為通過'}

# 合併：以小型名冊建立分片報告，驗證完整合併與各種缺漏、重疊、身分不符都失敗。
. (Join-Path $root 'script/test/test_report.ps1')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('container_shard_'+[guid]::NewGuid().ToString('N'))
$sha='a'*40
$run='https://github.com/example/repo/actions/runs/42'
$small=@(@{Name='Unit.alpha';Layer='Unit'},@{Name='Unit.beta';Layer='Unit'},@{Name='Integration.gamma';Layer='Integration'},@{Name='Integration.delta';Layer='Integration'})
function New-Check([string]$Name,[string]$Layer,[bool]$Passed=$true){[pscustomobject]@{Name=$Name;Layer=$Layer;Status=$(if($Passed){'Passed'}else{'Failed'});Executed=$true;Passed=$Passed;ExitCode=$(if($Passed){0}else{1});DurationSeconds=1.5;Assertions=@([pscustomobject]@{Name=($Name+' ok');Passed=$Passed})}}
$static=[pscustomobject]@{Name='PowerShell 5.1 語法';Layer='Static';Status='Passed';Executed=$true;Passed=$true;ExitCode=0;DurationSeconds=0;Assertions=@()}
function New-Shard([string]$Root,[int]$Index,[int]$Count,[object[]]$Checks,[string]$Commit=$sha,[string]$Environment='Windows container / Windows 10.0.20348.0 / PowerShell 5.1',[switch]$NoManifest,[switch]$NoAcceptance){
 # 與 CI 下載後的結構相同：每份一個目錄，內含 public 報告與旁邊的 shard.json。
 $directory=Join-Path $Root ('docker-shard-reports-42-1-'+$Index)
 $layers=@($Checks|Where-Object {$_.Layer -ne 'Static'}|ForEach-Object Layer|Select-Object -Unique)
 $layer=if($layers.Count -eq 1){$layers[0]}else{'All'}
 $null=Write-TestReports -Checks $Checks -OutputDirectory (Join-Path $directory 'public') -Layer $layer -Commit $Commit -RunUrl $run -SourceState Clean -Version 'v0.0.0' -Environment $Environment -RefType Branch -RefName 'feature' -Changes @('變更')
 if(-not $NoManifest){Write-CIContainerShardManifest -Directory $directory -ShardIndex $Index -ShardCount $Count -Acceptance:($Index -eq 0 -and -not $NoAcceptance)}
 return $directory
}
function New-Case([string]$Name){$case=Join-Path $temp $Name;New-Item -ItemType Directory -Path $case -Force|Out-Null;return $case}
try{
 $ok=New-Case 'ok'
 $null=New-Shard $ok 0 3 @($static,(New-Check 'Unit.alpha' 'Unit'),(New-Check 'Integration.delta' 'Integration'))
 $null=New-Shard $ok 1 3 @((New-Check 'Unit.beta' 'Unit'))
 $null=New-Shard $ok 2 3 @((New-Check 'Integration.gamma' 'Integration'))
 $out=Join-Path $temp 'ok_out'
 $merged=Merge-CIContainerShardReports -ShardRoot $ok -ShardCount 3 -OutputDirectory $out -Roster $small
 $summary=Get-Content -LiteralPath (Join-Path $out 'summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
 Assert ((@($summary.Checks.Name) -join '|') -ceq 'PowerShell 5.1 語法|Unit.alpha|Unit.beta|Integration.gamma|Integration.delta') '合併報告依名冊順序含全部 suite 與一次語法檢查'
 Assert ($summary.RequestedLayer -ceq 'All' -and $summary.Success -eq $true -and $summary.Totals.SuitesExecuted -eq 5 -and $summary.Totals.AssertionsExecuted -eq 4) '合併報告宣稱完整範圍且統計由逐項重算'
 Assert ($summary.Commit -ceq $sha -and $summary.RunUrl -ceq $run -and $summary.SourceState -ceq 'Clean' -and $summary.Environment -match 'Windows container') '合併報告保留同一提交、執行來源與容器環境'
 Assert ($merged.Success -eq $true) '合併結果回傳整體成功'
 $names=@(Get-ChildItem -LiteralPath $out -File|ForEach-Object Name|Sort-Object)
 Assert (($names -join ',') -ceq 'coverage.svg,index.html,integration.svg,junit.xml,summary.json,summary.md,unit.svg') '合併目錄只含發布所需的七個報告檔，不帶分片清單'
 $snapshot=$summary;Assert-TestReportSnapshot -Report $snapshot;Assert $true '合併報告通過報表結構驗證'
 Reject {Merge-CIContainerShardReports -ShardRoot $ok -ShardCount 3 -OutputDirectory $out -Roster $small} '輸出目錄已存在時拒絕混用' '輸出'

 $missing=New-Case 'missing'
 $null=New-Shard $missing 0 3 @($static,(New-Check 'Unit.alpha' 'Unit'),(New-Check 'Integration.delta' 'Integration'))
 $null=New-Shard $missing 1 3 @((New-Check 'Unit.beta' 'Unit'))
 Reject {Merge-CIContainerShardReports -ShardRoot $missing -ShardCount 3 -OutputDirectory (Join-Path $temp 'missing_out') -Roster $small} '缺少一份分片報告必須失敗' '分片'

 $gap=New-Case 'gap'
 $null=New-Shard $gap 0 2 @($static,(New-Check 'Unit.alpha' 'Unit'),(New-Check 'Integration.delta' 'Integration'))
 $null=New-Shard $gap 1 2 @((New-Check 'Unit.beta' 'Unit'))
 Reject {Merge-CIContainerShardReports -ShardRoot $gap -ShardCount 2 -OutputDirectory (Join-Path $temp 'gap_out') -Roster $small} '聯集少了名冊中的 suite 必須失敗' 'Integration\.gamma'

 $overlap=New-Case 'overlap'
 $null=New-Shard $overlap 0 2 @($static,(New-Check 'Unit.alpha' 'Unit'),(New-Check 'Integration.delta' 'Integration'))
 $null=New-Shard $overlap 1 2 @((New-Check 'Unit.alpha' 'Unit'),(New-Check 'Unit.beta' 'Unit'),(New-Check 'Integration.gamma' 'Integration'))
 Reject {Merge-CIContainerShardReports -ShardRoot $overlap -ShardCount 2 -OutputDirectory (Join-Path $temp 'overlap_out') -Roster $small} '兩份重複執行同一 suite 必須失敗' 'Unit\.alpha'

 $extra=New-Case 'extra'
 $null=New-Shard $extra 0 1 @($static,(New-Check 'Unit.alpha' 'Unit'),(New-Check 'Unit.beta' 'Unit'),(New-Check 'Integration.gamma' 'Integration'),(New-Check 'Integration.delta' 'Integration'),(New-Check 'Unit.unknown' 'Unit'))
 Reject {Merge-CIContainerShardReports -ShardRoot $extra -ShardCount 1 -OutputDirectory (Join-Path $temp 'extra_out') -Roster $small} '名冊外的 suite 必須失敗' 'Unit\.unknown'

 $nostatic=New-Case 'nostatic'
 $null=New-Shard $nostatic 0 2 @((New-Check 'Unit.alpha' 'Unit'),(New-Check 'Integration.delta' 'Integration'))
 $null=New-Shard $nostatic 1 2 @((New-Check 'Unit.beta' 'Unit'),(New-Check 'Integration.gamma' 'Integration'))
 Reject {Merge-CIContainerShardReports -ShardRoot $nostatic -ShardCount 2 -OutputDirectory (Join-Path $temp 'nostatic_out') -Roster $small} '缺少語法檢查必須失敗' '語法'

 $count=New-Case 'count'
 $null=New-Shard $count 0 2 @($static,(New-Check 'Unit.alpha' 'Unit'),(New-Check 'Integration.delta' 'Integration'))
 $null=New-Shard $count 1 3 @((New-Check 'Unit.beta' 'Unit'),(New-Check 'Integration.gamma' 'Integration'))
 Reject {Merge-CIContainerShardReports -ShardRoot $count -ShardCount 2 -OutputDirectory (Join-Path $temp 'count_out') -Roster $small} '分片宣稱的總份數不一致必須失敗' '分片'

 $twice=New-Case 'twice'
 $null=New-Shard $twice 0 2 @($static,(New-Check 'Unit.alpha' 'Unit'),(New-Check 'Integration.delta' 'Integration'))
 $second=New-Shard (New-Case 'twice_b') 0 2 @((New-Check 'Unit.beta' 'Unit'),(New-Check 'Integration.gamma' 'Integration'))
 Move-Item -LiteralPath $second -Destination (Join-Path $twice 'docker-shard-reports-42-1-1')
 Reject {Merge-CIContainerShardReports -ShardRoot $twice -ShardCount 2 -OutputDirectory (Join-Path $temp 'twice_out') -Roster $small} '同一分片索引出現兩次必須失敗' '分片'

 $nomanifest=New-Case 'nomanifest'
 $null=New-Shard $nomanifest 0 2 @($static,(New-Check 'Unit.alpha' 'Unit'),(New-Check 'Integration.delta' 'Integration'))
 $null=New-Shard $nomanifest 1 2 @((New-Check 'Unit.beta' 'Unit'),(New-Check 'Integration.gamma' 'Integration')) -NoManifest
 Reject {Merge-CIContainerShardReports -ShardRoot $nomanifest -ShardCount 2 -OutputDirectory (Join-Path $temp 'nomanifest_out') -Roster $small} '分片目錄缺少分片清單必須失敗' '分片'

 $commit=New-Case 'commit'
 $null=New-Shard $commit 0 2 @($static,(New-Check 'Unit.alpha' 'Unit'),(New-Check 'Integration.delta' 'Integration'))
 $null=New-Shard $commit 1 2 @((New-Check 'Unit.beta' 'Unit'),(New-Check 'Integration.gamma' 'Integration')) -Commit ('b'*40)
 Reject {Merge-CIContainerShardReports -ShardRoot $commit -ShardCount 2 -OutputDirectory (Join-Path $temp 'commit_out') -Roster $small} '各份提交不同必須失敗' '提交'

 $host_=New-Case 'host'
 $null=New-Shard $host_ 0 2 @($static,(New-Check 'Unit.alpha' 'Unit'),(New-Check 'Integration.delta' 'Integration'))
 $null=New-Shard $host_ 1 2 @((New-Check 'Unit.beta' 'Unit'),(New-Check 'Integration.gamma' 'Integration')) -Environment 'Windows 10.0.20348.0 / PowerShell 5.1'
 Reject {Merge-CIContainerShardReports -ShardRoot $host_ -ShardCount 2 -OutputDirectory (Join-Path $temp 'host_out') -Roster $small} '非容器環境的分片報告必須失敗' '容器'

 $unaccepted=New-Case 'unaccepted'
 $null=New-Shard $unaccepted 0 2 @($static,(New-Check 'Unit.alpha' 'Unit'),(New-Check 'Integration.delta' 'Integration')) -NoAcceptance
 $null=New-Shard $unaccepted 1 2 @((New-Check 'Unit.beta' 'Unit'),(New-Check 'Integration.gamma' 'Integration'))
 Reject {Merge-CIContainerShardReports -ShardRoot $unaccepted -ShardCount 2 -OutputDirectory (Join-Path $temp 'unaccepted_out') -Roster $small} '第 0 份未完成容器內 Go 驗收時合併必須失敗' 'Go 驗收'
 Reject {Write-CIContainerShardManifest -Directory (Join-Path $temp 'bad_manifest') -ShardIndex 1 -ShardCount 2 -Acceptance} '非第 0 份不能宣稱完成容器內 Go 驗收' 'Go 驗收'
 $forged=New-Case 'forged'
 $null=New-Shard $forged 0 2 @($static,(New-Check 'Unit.alpha' 'Unit'),(New-Check 'Integration.delta' 'Integration'))
 $forgedShard=New-Shard $forged 1 2 @((New-Check 'Unit.beta' 'Unit'),(New-Check 'Integration.gamma' 'Integration'))
 [IO.File]::WriteAllText((Join-Path $forgedShard 'shard.json'),'{"SchemaVersion":1,"ShardIndex":1,"ShardCount":2,"Acceptance":true}')
 Reject {Merge-CIContainerShardReports -ShardRoot $forged -ShardCount 2 -OutputDirectory (Join-Path $temp 'forged_out') -Roster $small} '非第 0 份的清單宣稱 Go 驗收時合併必須失敗' 'Go 驗收'
 $inside=New-Case 'inside'
 $insideShard=New-Shard $inside 0 1 @($static,(New-Check 'Unit.alpha' 'Unit'),(New-Check 'Unit.beta' 'Unit'),(New-Check 'Integration.gamma' 'Integration'),(New-Check 'Integration.delta' 'Integration'))
 Assert (-not (Test-Path -LiteralPath (Join-Path $insideShard 'public/shard.json')) -and (Test-Path -LiteralPath (Join-Path $insideShard 'shard.json'))) '分片清單寫在 public 報告旁邊，不混入 Go 驗收讀取的 public 目錄'

 $failed=New-Case 'failed'
 $null=New-Shard $failed 0 2 @($static,(New-Check 'Unit.alpha' 'Unit'),(New-Check 'Integration.delta' 'Integration'))
 $null=New-Shard $failed 1 2 @((New-Check 'Unit.beta' 'Unit' $false),(New-Check 'Integration.gamma' 'Integration'))
 $failedOut=Join-Path $temp 'failed_out'
 Reject {Merge-CIContainerShardReports -ShardRoot $failed -ShardCount 2 -OutputDirectory $failedOut -Roster $small} '任一份測試失敗時合併必須失敗' '未通過'
 $failedSummary=Get-Content -LiteralPath (Join-Path $failedOut 'summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
 Assert ($failedSummary.Success -eq $false -and @($failedSummary.Checks).Count -eq 5) '失敗時仍寫出完整診斷報告且標示未通過'
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}

# 容器入口：多份時把分片傳給 run_ci 並寫出分片清單；單一份維持原本完整四個階段。
$container=Get-Content -LiteralPath (Join-Path $root 'script/docker/container_test.ps1') -Raw -Encoding UTF8
Assert ($container -match [regex]::Escape('run_ci.ps1 -Layer All -ReportDirectory C:/reports -Parallelism 2 -ShardIndex $shardIndex -ShardCount $shardCount') -and $container -match [regex]::Escape('Write-CIContainerShardManifest -Directory C:/reports -ShardIndex $shardIndex -ShardCount $shardCount')) '容器入口把分片傳給 run_ci 並在 public 旁寫出分片清單'
$stop=$container.IndexOf('if($shardIndex -ne 0)');$goPhase=$container.IndexOf('Invoke-ContainerGoTestPhase -Plan');$gatePhase=$container.IndexOf("'./script/test/requirements_gate','--tests-only'");$accepted=$container.IndexOf('-ShardCount $shardCount -Acceptance')
Assert ($stop -gt 0 -and $goPhase -gt $stop -and $gatePhase -gt $goPhase -and $accepted -gt $gatePhase) '第 0 份在容器內續跑 Go 驗收與需求閘門，完成後才標記驗收'
$compose=Get-Content -LiteralPath (Join-Path $root 'compose.yaml') -Raw -Encoding UTF8
Assert ($compose -match [regex]::Escape('WINDOWS_SETUP_SHARD_INDEX: ${WINDOWS_SETUP_SHARD_INDEX:-0}') -and $compose -match [regex]::Escape('WINDOWS_SETUP_SHARD_COUNT: ${WINDOWS_SETUP_SHARD_COUNT:-1}')) 'compose 只傳入分片索引與份數，預設等於單一完整執行'
$entry=Get-Content -LiteralPath (Join-Path $root 'script/docker/docker.ps1') -Raw -Encoding UTF8
Assert ($entry -match '\[int\]\$ShardIndex=0' -and $entry -match '\[int\]\$ShardCount=1' -and $entry -match 'WINDOWS_SETUP_SHARD_INDEX=\$ShardIndex' -and $entry -match 'WINDOWS_SETUP_SHARD_COUNT=\$ShardCount') 'Docker 入口接受分片參數並傳給 compose'
$previousPreference=$ErrorActionPreference
try{$ErrorActionPreference='Continue';$entryOutput=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'script/docker/docker.ps1') -Action doctor -ShardIndex 3 -ShardCount 3 2>&1}finally{$ErrorActionPreference=$previousPreference}
Assert ($LASTEXITCODE -ne 0 -and (($entryOutput|Out-String) -match '分片')) 'Docker 入口在呼叫 docker 前拒絕超出範圍的分片'
