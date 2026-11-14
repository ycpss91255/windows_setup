#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'script/test/run_repo_coverage.ps1')
function Assert([bool]$Condition,[string]$Message){Write-Host ('@@ASSERT@@'+(@{Name=$Message;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Message}}
function Reject([scriptblock]$Action,[string]$Name){$caught=$false;try{& $Action|Out-Null}catch{$caught=$true};Assert $caught $Name}
$temp=Join-Path $env:TEMP ('repo_pipeline_'+[guid]::NewGuid().ToString('N'));$public=Join-Path $temp 'public';[void][IO.Directory]::CreateDirectory($public)
[IO.File]::WriteAllText((Join-Path $public 'summary.json'),('{"Commit":"'+('a'*40)+'","RunUrl":"https://github.com/example/repo/actions/runs/1"}'))
$script:calls=New-Object Collections.Generic.List[object]
function Invoke-CINative {param($File,$Arguments) $script:calls.Add(@{File=$File;Arguments=@($Arguments)});if($script:failAt -and @($Arguments) -contains $script:failAt){throw 'fixture failure'}}
try {
 $output=Join-Path $temp 'result'
 Invoke-RepoCoveragePipeline -SourceRoot $root -PublicDirectory $public -GoCoverageDirectory (Join-Path $temp 'go') -ManagedEvidencePath (Join-Path $temp 'managed/evidence.json') -OutputDirectory $output
 $workers=@($script:calls|Where-Object {$_.Arguments -contains (Join-Path $root 'script/test/powershell_coverage.ps1')})
 Assert ($workers.Count -eq 1 -and $workers[0].Arguments -contains '-ThrottleLimit' -and $workers[0].Arguments[[Array]::IndexOf($workers[0].Arguments,'-ThrottleLimit')+1] -eq '2') '正式整體收集明確只開兩個worker而非預設序列'
 $collect=@($script:calls|Where-Object {$_.Arguments -contains 'collect'})
 Assert ($collect.Count -eq 1 -and ($collect[0].Arguments -contains '--runtime') -and ($collect[0].Arguments -notcontains '--go-evidence') -and ($collect[0].Arguments -contains '--powershell-evidence') -and ($collect[0].Arguments -notcontains '--cmd-evidence') -and ($collect[0].Arguments -contains '--managed-evidence') -and @($script:calls|Where-Object {$_.Arguments -contains 'cmd-measure'}).Count -eq 0) 'runtime 聚合不依賴 Go 或 CMD 覆蓋率'
 $verify=@($script:calls|Where-Object {$_.Arguments -contains 'verify'})
 Assert ($verify.Count -eq 1 -and ($verify[0].Arguments -contains '--runtime') -and ($verify[0].Arguments -contains '--require-complete') -and ($verify[0].Arguments -contains '--minimum-percent') -and ($verify[0].Arguments -contains '80')) '正式門檻要求完整與八成'
 Assert ($script:calls[-1].Arguments -contains (Join-Path $root 'script/test/attach_repo_coverage.ps1')) '通過門檻才附加正式報告'
 $script:calls.Clear();$script:failAt=''
 $shards=Join-Path $temp 'shards'
 Invoke-RepoCoveragePipeline -SourceRoot $root -PublicDirectory $public -GoCoverageDirectory (Join-Path $temp 'go') -ManagedEvidencePath (Join-Path $temp 'managed/evidence.json') -OutputDirectory (Join-Path $temp 'sharded') -PowerShellShardDirectory $shards -PowerShellTimingDirectory (Join-Path $temp 'timings') -RunAttempt 2
 $merge=@($script:calls|Where-Object {$_.Arguments -contains 'powershell-shard-merge'})
 Assert ($merge.Count -eq 1 -and $merge[0].Arguments -contains $shards -and $merge[0].Arguments -contains '--expected-sha' -and $merge[0].Arguments -contains '--expected-run-url') '同job從完整分片聚合並重新核對原提交與執行身分'
 Assert ($merge[0].Arguments -contains '--timing-input-dir' -and $merge[0].Arguments -contains '--timing-output-dir') '分片聚合同時核對完整同次計時收據'
 Assert ($merge[0].Arguments[[Array]::IndexOf($merge[0].Arguments,'--run-attempt')+1] -eq '2' -and $merge[0].Arguments[[Array]::IndexOf($merge[0].Arguments,'--shard-count')+1] -eq '4') '正式聚合要求同attempt與四片完整集合'
 Assert (@($script:calls|Where-Object {$_.Arguments -contains (Join-Path $root 'script/test/powershell_coverage.ps1')}).Count -eq 0) '分片路線不在host重跑整輪量測或退回部分清單'
 Assert (@($script:calls|Where-Object {$_.Arguments -contains 'collect' -and $_.Arguments -contains '--managed-evidence'}).Count -eq 1) 'managed 證據仍於同 host 驗證後收集'
 $script:calls.Clear();$script:failAt='powershell-shard-merge'
 Reject {Invoke-RepoCoveragePipeline -SourceRoot $root -PublicDirectory $public -GoCoverageDirectory 'go' -ManagedEvidencePath 'managed' -OutputDirectory (Join-Path $temp 'missing_shards') -PowerShellShardDirectory $shards -PowerShellTimingDirectory (Join-Path $temp 'timings') -RunAttempt 2} '分片不足或不合法不得產生整體成功'
 Assert (@($script:calls|Where-Object {$_.Arguments -contains 'collect' -or $_.Arguments -contains (Join-Path $root 'script/test/attach_repo_coverage.ps1')}).Count -eq 0) '分片驗證失敗時不可用其他語言掩蓋缺少的PowerShell'
 Reject {Invoke-RepoCoveragePipeline -SourceRoot $root -PublicDirectory $public -GoCoverageDirectory 'go' -ManagedEvidencePath 'managed' -OutputDirectory $output} '不得混入已有量測目錄'
 $script:calls.Clear();$script:failAt='verify'
 Reject {Invoke-RepoCoveragePipeline -SourceRoot $root -PublicDirectory $public -GoCoverageDirectory 'go' -ManagedEvidencePath 'managed' -OutputDirectory (Join-Path $temp 'failed')} 'strict失敗必須停止'
 Assert (@($script:calls|Where-Object {$_.Arguments -contains (Join-Path $root 'script/test/attach_repo_coverage.ps1')}).Count -eq 0) '缺量測或低覆蓋率不附加發布報告'
 Reject {Invoke-RepoCoveragePipeline -SourceRoot $root -PublicDirectory $public -GoCoverageDirectory 'go' -ManagedEvidencePath 'managed' -OutputDirectory (Join-Path $root 'coverage_invalid')} '產物不得寫入版本來源'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
