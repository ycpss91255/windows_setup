#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Message){Write-Host ('@@ASSERT@@'+(@{Name=$Message;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Message}}
$workflow=[IO.File]::ReadAllText((Join-Path $root '.github/workflows/windows_tests.yml'))
Assert ($workflow -match '(?m)^  pull_request:\s*$' -and $workflow -match '(?m)^    branches: \[main\]\s*$') 'workflow 由 PR 與 main 觸發'
$aggregation=[regex]::Match($workflow,'(?ms)^  coverage-aggregation:\s*\r?\n(.*?)(?=^  requirements-gate:)').Groups[1].Value
Assert ($aggregation -match 'needs: \[isolated-tests, powershell-coverage\]' -and $aggregation -match 'run_repo_coverage\.ps1' -and $aggregation -match 'New-CIQualitySummary -Report \$report -AggregationState ''success''' -and $aggregation -notmatch '(?m)^    if:') 'PR 與 main 共用聚合且驗證完成才輸出摘要'
$shards=[regex]::Match($workflow,'(?ms)^  powershell-coverage:\s*\r?\n(.*?)(?=^  [a-z][a-z0-9-]*:\s*$)').Groups[1].Value
Assert ($shards -match '-TimingDirectory \(Join-Path \$env:RUNNER_TEMP ''powershell-timing-public''\)' -and $shards -match 'name: powershell-timing-\$\{\{ github.run_id \}\}-\$\{\{ github.run_attempt \}\}-\$\{\{ matrix.shard \}\}' -and $shards -match 'path: \$\{\{ runner.temp \}\}/powershell-timing-public/') '每片執行與同次同 attempt 的獨立計時 artifact 相連'
Assert ($aggregation -match 'pattern: powershell-timing-\$\{\{ github.run_id \}\}-\$\{\{ github.run_attempt \}\}-\*' -and $aggregation -match '-PowerShellTimingDirectory \(Join-Path \$env:RUNNER_TEMP ''powershell-timings''\)' -and $aggregation -match 'repo-coverage/timing/timing.json') '聚合下載完整同次計時並保留核對後結果'
$rollup=[regex]::Match($workflow,'(?ms)^  ci-rollup:\s*\r?\n(.*?)(?=^  release:)').Groups[1].Value
Assert ($rollup -match 'if: always\(\)' -and $rollup -match 'needs: \[isolated-tests, requirements-gate, docker-tests, oobe_payload_inspection, powershell-coverage, coverage-aggregation\]') 'rollup 在失敗時仍取得必要工作的狀態'
$step=[regex]::Match($rollup,'(?ms)^      - name: 確認全部必要測試成功\s*\r?\n.*?^        run: \|\s*\r?\n((?:^          .*\r?\n)+)').Groups[1].Value
Assert ([bool]$step) '擷取實際 rollup 步驟'
$script=[scriptblock]::Create(($step -replace '(?m)^          ',''))
$temp=Join-Path $env:TEMP ('ci_summary_rollup_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temp)
try {
 $env:GITHUB_STEP_SUMMARY=Join-Path $temp 'summary.md'
 foreach($name in @('TEST_RESULT','REQUIREMENTS_RESULT','DOCKER_RESULT','OOBE_PAYLOAD_RESULT','POWERSHELL_COVERAGE_RESULT')){[Environment]::SetEnvironmentVariable($name,'success','Process')}
 $env:COVERAGE_RESULT='failure';$caught=$false
 Push-Location $root;try{try{& $script}catch{$caught=$true}}finally{Pop-Location}
 $text=[IO.File]::ReadAllText($env:GITHUB_STEP_SUMMARY)
 Assert ($caught -and $text -match 'Coverage: failure' -and $text -match '未提供完整量測' -and $text -notmatch '\d+\.\d+%') '實際 rollup 失敗時明示未完整量測且保留失敗'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
