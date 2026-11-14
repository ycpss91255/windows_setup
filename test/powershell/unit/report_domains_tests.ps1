#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'script/test/test_report.ps1')
. (Join-Path $root 'script/report/portal.ps1')
$cases=Get-Content -LiteralPath (Join-Path $root 'test/fixtures/report_domains.json') -Raw -Encoding UTF8|ConvertFrom-Json
foreach($case in $cases){$actual=Get-ReportDomain $case.Name;if($actual -cne $case.Domain){throw ('分類不符 '+$case.Name+': '+$actual)}}
$reports=@{}
foreach($envName in @('native','container')){
 $rows=@(foreach($case in $cases|Where-Object Environment -eq $envName){[pscustomobject]@{Name=$case.Name;Layer='Unit';Status=$case.Status;Executed=($case.Status -ne 'NotRun');Passed=($case.Status -eq 'Passed');Assertions=@()}})
 $reports[$envName]=[pscustomobject]@{Success=$false;Commit=('a'*40);RefType='Branch';RefName='main';RunUrl='https://github.com/example/repo/actions/runs/1';MeasuredAt='2026-01-01T00:00:00Z';Environment=$envName;Checks=$rows;Totals=[pscustomobject]@{SuitesExecuted=6;AssertionsPassed=1;AssertionsExecuted=2;AssertionsFailed=1;UnexecutedSuites=1}}
}
$html=New-PairedOverviewHtml -Native $reports.native -Container $reports.container -Title '測試'
foreach($domain in @($cases.Domain|Select-Object -Unique)){if(([regex]::Matches($html,[regex]::Escape($domain))).Count -ne 1){throw ('領域不是恰一次 '+$domain)}}
foreach($case in $cases){if(([regex]::Matches($html,[regex]::Escape($case.Name))).Count -ne 1){throw ('原始名稱不是恰一次 '+$case.Name)}}
if($html.IndexOf('硬體與驅動包') -gt $html.IndexOf('網路與 SSH') -or $html.IndexOf('網路與 SSH') -gt $html.IndexOf('帳號與權限')){throw '失敗與未執行領域未優先'}
$expected=@('硬體與驅動包','網路與 SSH','帳號與權限','版本與來源準備','Windows 設定與清理','測試與交付工具','其他檢查');$prior=-1
foreach($domain in $expected){$position=$html.IndexOf($domain);if($position -le $prior){throw ('領域顯示順序不符 '+$domain)};$prior=$position}
if($html -notmatch '原生\s*2\s*組' -or $html -notmatch '容器\s*1\s*組（失敗\s*1、未執行\s*0）'){throw '環境計數必須分開'}
Write-Host '@@ASSERT@@{"Name":"領域分類、完整性、順序及獨立環境分母","Passed":true}'