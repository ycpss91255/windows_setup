#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Passed,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Passed}|ConvertTo-Json -Compress));if(-not $Passed){throw $Name}}
$producer=Join-Path $root 'script/test/powershell_coverage_shard.ps1'
Assert (Test-Path -LiteralPath $producer -PathType Leaf) '提供可保留全源分母的獨立原生PowerShell分片入口'
$temp=Join-Path $env:TEMP ('coverage_shards_'+[guid]::NewGuid().ToString('N'))
$source=Join-Path $temp '來源 中文';[void][IO.Directory]::CreateDirectory($source)
foreach($dir in @('core','test/powershell/unit','test/powershell/integration','test/powershell/coverage')){[void][IO.Directory]::CreateDirectory((Join-Path $source $dir))}
$utf8=[Text.UTF8Encoding]::new($true)
[IO.File]::WriteAllText((Join-Path $source 'core/example.ps1'),"function Choose([bool]`$Side){if(`$Side){return 1}else{return 2}}`nfunction Never {return 3}`n",$utf8)
foreach($index in @(0,1)){
 $side=if($index -eq 0){'$true'}else{'$false'}
 [IO.File]::WriteAllText((Join-Path $source ('test/powershell/unit/side_'+$index+'_tests.ps1')),(". (Join-Path ([IO.Path]::GetFullPath((Join-Path `$PSScriptRoot '../../..'))) 'core/example.ps1');if((Choose $side) -ne "+(1+$index)+"){throw 'wrong native branch'}"),$utf8)
}
Copy-Item -LiteralPath (Join-Path $root 'test/powershell/coverage/safe_suite.ps1') -Destination (Join-Path $source 'test/powershell/coverage/safe_suite.ps1')
& git -C $source init --quiet
& git -C $source add .
& git -C $source -c user.name=CoverageFixture -c user.email=fixture@example.invalid commit --quiet -m fixture
if($LASTEXITCODE -ne 0){throw 'cannot prepare isolated source fixture'}
$commit=(& git -C $source rev-parse HEAD).Trim();$run='https://github.com/example/repo/actions/runs/123'
$tool=Join-Path $temp 'repo_coverage_tool.exe'
Push-Location $root
try{& go.exe build -mod=vendor -o $tool ./script/test/repo_coverage_tool;if($LASTEXITCODE -ne 0){throw 'cannot build coverage CLI'}}finally{Pop-Location}
$parts=Join-Path $temp 'parts';[void][IO.Directory]::CreateDirectory($parts)
$timingParts=Join-Path $temp 'timing_parts';[void][IO.Directory]::CreateDirectory($timingParts)
foreach($index in @(0,1)){
 $part=Join-Path $parts ('powershell-shard-123-1-'+$index);$private=Join-Path $temp ('private_'+$index);$timing=Join-Path $timingParts ('powershell-timing-123-1-'+$index)
 & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $producer -SourceRoot $source -OutputDirectory $part -PrivateDirectory $private -TimingDirectory $timing -ShardIndex $index -ShardCount 2 -Commit $commit -RunUrl $run -RunAttempt 1 -CoverageToolPath $tool *> (Join-Path $temp ('shard_'+$index+'.private.log'))
 Assert ($LASTEXITCODE -eq 0) ('真Pester原始來源分片成功：'+$index)
 Assert (Test-Path -LiteralPath (Join-Path $timing 'timing.json')) '真實分片安全匯出獨立計時收據'
 $proof=Get-Content -LiteralPath (Join-Path $part 'shard.json') -Raw -Encoding UTF8|ConvertFrom-Json
 Assert ($proof.Workers.Count -eq 1 -and $proof.Tests.Count -eq 2 -and $proof.Sources.Count -eq 1) '每片保留完整canonical清單但僅執行自己的suite'
 Assert (-not ((Get-ChildItem -LiteralPath $part -Recurse -File|ForEach-Object {[IO.File]::ReadAllText($_.FullName)}) -join "`n").Contains($source)) '上傳證據沒有絕對來源路徑或私有stdout'
}
$manifest=Join-Path $temp 'canonical.json'
& (Join-Path $root 'test/powershell/coverage/create_baseline_manifest.ps1') -SourceRoot $source -OutputPath $manifest
$merged=Join-Path $temp 'merged'
& $tool powershell-shard-merge --source-root $source --manifest $manifest --input-dir $parts --output-dir $merged --timing-input-dir $timingParts --timing-output-dir (Join-Path $temp 'merged_timing') --expected-sha $commit --expected-run-url $run --run-attempt 1 --shard-count 2 *> (Join-Path $temp 'merge.private.log')
Assert ($LASTEXITCODE -eq 0) '跨分片真Pester命令證據通過完整聚合'
$timings=Get-Content -LiteralPath (Join-Path $temp 'merged_timing/timing.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert (@($timings).Count -eq 2 -and @($timings|Select-Object -ExpandProperty Context|Select-Object -ExpandProperty TestFile -Unique).Count -eq 2) '計時收據跨片逐一核對完整 suite'
$result=Get-Content -LiteralPath (Join-Path $merged 'evidence.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert ($result.Workers.Count -eq 2 -and $result.Total -eq 2 -and $result.Covered -eq 1) '先union同一行互補命令，再保留nevercall完整零命中分母'
$file=Join-Path $parts 'powershell-shard-123-1-1/shard.json';$old=[IO.File]::ReadAllText($file);$bad=Get-Content $file -Raw|ConvertFrom-Json;$bad.RunAttempt=2;[IO.File]::WriteAllText($file,($bad|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$previous=$ErrorActionPreference
try{$ErrorActionPreference='Continue';& $tool powershell-shard-merge --source-root $source --manifest $manifest --input-dir $parts --output-dir (Join-Path $temp 'wrong_attempt') --expected-sha $commit --expected-run-url $run --run-attempt 1 --shard-count 2 *> (Join-Path $temp 'bad.private.log');$exitCode=$LASTEXITCODE}finally{$ErrorActionPreference=$previous}
Assert ($exitCode -ne 0 -and -not(Test-Path (Join-Path $temp 'wrong_attempt/evidence.json'))) '跨attempt證據不能合併或發布完整結論'
[IO.File]::WriteAllText($file,$old,[Text.UTF8Encoding]::new($false))
$global:LASTEXITCODE=0
