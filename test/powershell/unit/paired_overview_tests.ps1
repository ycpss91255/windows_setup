#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'script/test/test_report.ps1')
. (Join-Path $root 'script/report/portal.ps1')
$checks=@([pscustomobject]@{Name='PASS-MARK';Layer='Unit';Status='Passed';Executed=$true;Passed=$true;ExitCode=0;DurationSeconds=1;Assertions=@([pscustomobject]@{Name='ok';Passed=$true})},[pscustomobject]@{Name='FAIL-MARK';Layer='Integration';Status='Failed';Executed=$true;Passed=$false;ExitCode=1;DurationSeconds=1;Assertions=@([pscustomobject]@{Name='bad';Passed=$false})})
$parent=Join-Path $env:TEMP ('issue201_pair_view_'+[guid]::NewGuid().ToString('N'))
$native=Write-TestReports -Checks $checks -OutputDirectory (Join-Path $parent 'native') -Commit ('a'*40) -RunUrl 'https://github.com/example/repo/actions/runs/42' -SourceState Clean -RefName main -Environment 'Windows synthetic native'
$container=Write-TestReports -Checks $checks -OutputDirectory (Join-Path $parent 'container') -Commit ('a'*40) -RunUrl 'https://github.com/example/repo/actions/runs/42' -SourceState Clean -RefName main -Environment 'Windows container / Windows synthetic'
$native.Checks=@($native.Checks|Where-Object Name -eq 'PASS-MARK')
$html=New-PairedOverviewHtml -Native $native -Container $container -Title '主線測試結果'
foreach($text in @('Windows 原生','Windows 容器','測試未通過','容器未量測','native/index.html','windows_container/index.html','summary.json','junit.xml')){if(-not $html.Contains($text)){throw ('missing '+$text)}}
if($html.IndexOf('FAIL-MARK') -gt $html.IndexOf('PASS-MARK')){throw '失敗必須先列'}
if($html.IndexOf('2 組測試') -gt $html.IndexOf('<details>')){throw '關鍵數字不可隱藏'}
Write-Host '@@ASSERT@@{"Name":"雙環境分開呈現，失敗優先且關鍵數字可見","Passed":true}'
