#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'script/test/test_report.ps1')
$path=Join-Path $env:TEMP ('issue201_view_'+[guid]::NewGuid().ToString('N'))
$checks=@(
 [pscustomobject]@{Name='PASS-MARK';Layer='Unit';Status='Passed';Executed=$true;Passed=$true;ExitCode=0;DurationSeconds=1;Assertions=@([pscustomobject]@{Name='ok';Passed=$true})},
 [pscustomobject]@{Name='FAIL-MARK';Layer='Integration';Status='Failed';Executed=$true;Passed=$false;ExitCode=1;DurationSeconds=1;Assertions=@([pscustomobject]@{Name='bad';Passed=$false})})
Write-TestReports -Checks $checks -OutputDirectory $path -Commit ('a'*40) -SourceState Clean -RefName main|Out-Null
$html=[IO.File]::ReadAllText((Join-Path $path 'index.html'))
if($html.IndexOf('FAIL-MARK') -lt 0 -or $html.IndexOf('FAIL-MARK') -gt $html.IndexOf('PASS-MARK')){throw '失敗測試必須先於通過測試'}
if($html -notmatch '本次測試未通過'){throw '真實失敗不能標示通過'}
Write-Host '@@ASSERT@@{"Name":"失敗優先及真實狀態","Passed":true}'
