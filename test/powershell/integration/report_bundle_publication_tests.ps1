#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Name}}
. (Join-Path $root 'test/powershell/helpers/report_bundle_fixture.ps1')
$fixturePath=Join-Path ([IO.Path]::GetTempPath()) ('publisher_bundle_fixture_'+[guid]::NewGuid().ToString('N'))
$bundleFixture=New-TestReportBundleFixture -RepositoryRoot $root -Destination $fixturePath -Runtime
$data=$bundleFixture.Metadata
Assert ($data.kind -ceq 'Synthetic') '僅使用標明 Synthetic 的受控工件'
$source=$bundleFixture.Source
$fixtureNative=Join-Path $bundleFixture.Root 'windows-test-reports-1-1'
$container=Join-Path $bundleFixture.Root 'docker-test-reports-1-1'
$work=Join-Path ([IO.Path]::GetTempPath()) ('publisher_bundle_replay_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -ErrorAction Stop|Out-Null
$baselineRoot=Join-Path $work 'baseline';New-Item -ItemType Directory -Path $baselineRoot|Out-Null
$native=Join-Path $baselineRoot 'windows-test-reports-1-1'
Copy-Item -LiteralPath $fixtureNative -Destination $native -Recurse
$archive=Join-Path $baselineRoot $data.archive
$bundleTool=$bundleFixture.BundleTool;$coverageTool=$bundleFixture.CoverageTool
$identity=@('--source-root',$source,'--version',$data.version,'--commit',$data.commit,'--run-url',$data.run_url,'--run-attempt',[string]$data.run_attempt)
& $bundleTool export --native-dir $native --container-dir $container @identity --output $archive
Assert ($LASTEXITCODE -eq 0) 'PS5 可比較摘要與附件的第一份報告可真實封裝'
$alternateRoot=Join-Path $work 'alternate';New-Item -ItemType Directory -Path $alternateRoot|Out-Null
$alternateNative=Join-Path $alternateRoot 'windows-test-reports-1-1'
Copy-Item -LiteralPath $native -Destination $alternateNative -Recurse
[IO.File]::AppendAllText((Join-Path $alternateNative 'summary.md'),"`n")
$alternateArchive=Join-Path $alternateRoot $data.archive
& $bundleTool export --native-dir $alternateNative --container-dir $container @identity --output $alternateArchive
Assert ($LASTEXITCODE -eq 0) '不同原始 bytes 的同身份第二份報告可真實封裝'
& $bundleTool verify --archive $alternateArchive @identity
Assert ($LASTEXITCODE -eq 0) '同身份第二份封裝通過真實驗證'
Assert ((Get-FileHash -LiteralPath $archive).Hash -cne (Get-FileHash -LiteralPath $alternateArchive).Hash) '兩份合法封裝的 bytes 不同'
$notes=Join-Path $work 'notes.md';[IO.File]::WriteAllText($notes,'synthetic test notes')
$drivers=Join-Path $work 'drivers.json';[IO.File]::WriteAllText($drivers,'{"SchemaVersion":1,"Releases":[]}')
$global:mockCreate=0
function gh {
 $words=@($args);$global:LASTEXITCODE=0
 if($words[0] -ceq 'api' -and $words[1] -like '*/commits/*'){return $data.commit}
 if($words[0] -ceq 'api' -and $words -contains '--paginate'){return}
 if($words[0] -ceq 'release' -and $words[1] -ceq 'create'){$global:mockCreate++;throw 'MOCK_CREATE_AFTER_VERIFICATION'}
 throw ('Unexpected mock gh call: '+($words -join ' '))
}
$arguments=@{PublicDirectory=$alternateNative;ContainerDirectory=$container;Version=$data.version;Commit=$data.commit;NotesPath=$notes;Repository='example/windows_setup';CoverageToolPath=$coverageTool;DriverAssetManifestPath=$drivers;ReportArchive=$archive;BundleToolPath=$bundleTool;RunAttempt=[int]$data.run_attempt;RunUrl=$data.run_url;SourceRoot=$source}
Assert ((Get-Command gh).CommandType -eq 'Function') '使用 mock gh，不執行實際發布'
$caught='';try{& (Join-Path $root 'script/report/publish_quality_release.ps1') @arguments}catch{$caught=$_.Exception.Message}
Write-Host ('Synthetic mismatch result: '+$caught)
Assert ($caught -ceq '封裝與同次原始報表不一致。' -and $global:mockCreate -eq 0) '同身份不同原始 bytes 在建立草稿前拒絕'
$arguments.PublicDirectory=$native
Assert ((Get-Command gh).CommandType -eq 'Function') '正例同樣使用 mock gh'
$caught='';try{& (Join-Path $root 'script/report/publish_quality_release.ps1') @arguments}catch{$caught=$_.Exception.Message}
Assert ($caught -ceq 'MOCK_CREATE_AFTER_VERIFICATION' -and $global:mockCreate -eq 1) '原始 bytes 一致才到達受控建立草稿邊界'
Remove-Item Function:\gh
$helperRoot=Join-Path $work 'helper';New-Item -ItemType Directory -Path $helperRoot|Out-Null
Copy-Item -LiteralPath $fixtureNative -Destination (Join-Path $helperRoot 'windows-test-reports-1-1') -Recurse
Copy-Item -LiteralPath $container -Destination (Join-Path $helperRoot 'docker-test-reports-1-1') -Recurse
$saved=@{};foreach($name in @('RUNNER_TEMP','GITHUB_REF_NAME','GITHUB_SHA','GITHUB_REPOSITORY','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT')){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try{
 $env:RUNNER_TEMP=$helperRoot;$env:GITHUB_REF_NAME=$data.version;$env:GITHUB_SHA=$data.commit;$env:GITHUB_REPOSITORY='example/windows_setup';$env:GITHUB_RUN_ID='1';$env:GITHUB_RUN_ATTEMPT='1'
 $helperPassed=$true
 Push-Location $root
 try{& (Join-Path $root 'script/report/build_release_bundle.ps1') -SourceRoot $source}catch{$helperPassed=$false}finally{Pop-Location}
 Assert ($helperPassed -and (Test-Path -LiteralPath (Join-Path $helperRoot $data.archive) -PathType Leaf)) 'CD 工具實際封裝及驗證同次工件'
 $env:GITHUB_RUN_ATTEMPT='2';$wrongAttemptRejected=$false
 Push-Location $root
 try{& (Join-Path $root 'script/report/build_release_bundle.ps1') -SourceRoot $source}catch{$wrongAttemptRejected=$true}finally{Pop-Location}
 Assert $wrongAttemptRejected 'CD 工具拒絕不同 attempt 或缺少同次工件'
}finally{foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}}
Write-Host 'ALL PASS: synthetic bundle publication boundary; mocked gh'
