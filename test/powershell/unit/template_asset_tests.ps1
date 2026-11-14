#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$fixture=Join-Path $env:TEMP ('issue201_asset_test_'+[guid]::NewGuid().ToString('N'))
$test=Join-Path $fixture 'script/test';$report=Join-Path $fixture 'script/report';$asset=Join-Path $test 'report_bundle_tool'
[void][IO.Directory]::CreateDirectory($asset);[void][IO.Directory]::CreateDirectory($report)
foreach($name in @('test_report.ps1','go_coverage.ps1')){Copy-Item -LiteralPath (Join-Path $root ('script/test/'+$name)) -Destination (Join-Path $test $name)}
Copy-Item -LiteralPath (Join-Path $root 'script/report/repo_coverage.ps1') -Destination (Join-Path $report 'repo_coverage.ps1')
. (Join-Path $test 'test_report.ps1')
$checks=@([pscustomobject]@{Name='Unit';Layer='Unit';Status='Passed';Executed=$true;Passed=$true;ExitCode=0;DurationSeconds=1;Assertions=@([pscustomobject]@{Name='ok';Passed=$true})})
$failed=$false;try{Write-TestReports -Checks $checks -OutputDirectory (Join-Path $fixture 'missing') -Commit ('a'*40) -RefName main -Layer Unit|Out-Null}catch{$failed=$_.Exception.Message -match 'overview.html'}
if(-not $failed){throw '缺模板不得產生新版報表'}
Copy-Item -LiteralPath (Join-Path $root 'script/test/report_bundle_tool/overview.html') -Destination (Join-Path $asset 'overview.html')
Write-TestReports -Checks $checks -OutputDirectory (Join-Path $fixture 'present') -Commit ('a'*40) -RefName main -Layer Unit|Out-Null
if(-not(Test-Path -LiteralPath (Join-Path $fixture 'present/index.html') -PathType Leaf)){throw '模板完整時未產生報表'}
Write-Host '@@ASSERT@@{"Name":"隔離封裝缺少模板時拒絕，含模板時可產生","Passed":true}'
