#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'script/test/test_report.ps1')
. (Join-Path $root 'script/report/portal.ps1')
$report=[pscustomobject]@{Success=$true;Commit=('a'*40);RefType='Branch';RefName='main';RunUrl='https://github.com/example/repo/actions/runs/1';MeasuredAt='2026-01-01T00:00:00Z';Environment='Windows synthetic';Checks=@();Totals=[pscustomobject]@{SuitesExecuted=1;AssertionsPassed=1;AssertionsExecuted=1;AssertionsFailed=0;UnexecutedSuites=0}}
foreach($case in @(@{Name='runtime';Schema=2;Scope='core-modules-powershell-and-modules-native-csharp';Covered=17;Total=23;Percent=73.9;Label='PowerShell/C# runtime 覆蓋率'},@{Name='historical';Schema=1;Scope='';Covered=51;Total=67;Percent=76.1;Label='整體覆蓋率'})){
 $report|Add-Member -Force -NotePropertyName RepoCoverage -NotePropertyValue ([pscustomobject]@{SchemaVersion=$case.Schema;Scope=$case.Scope;Result=[pscustomobject]@{Complete=$true;Covered=$case.Covered;Executable=$case.Total;Percent=$case.Percent}})
 $html=New-PairedOverviewHtml -Native $report -Container $report
 $headline=[regex]::Match($html,'<h3>原生整體覆蓋率</h3><div class="big">([^<]+)</div>').Groups[1].Value
 $percent=([double]$case.Percent).ToString('0.0',[Globalization.CultureInfo]::InvariantCulture)+'%'
 if($headline -cne $percent){throw ('headline '+$case.Name+': '+$headline)}
 if(-not $html.Contains($case.Label) -or -not $html.Contains(($case.Covered.ToString()+'/'+$case.Total.ToString()+' 可執行行'))){throw ('可見範圍或計數缺失 '+$case.Name)}
}
$report.PSObject.Properties.Remove('RepoCoverage');$html=New-PairedOverviewHtml -Native $report -Container $report
$headline=[regex]::Match($html,'<h3>原生整體覆蓋率</h3><div class="big">([^<]+)</div>').Groups[1].Value
if($headline -cne '尚未完整量測'){throw '未量測不可顯示百分比'}
Write-Host '@@ASSERT@@{"Name":"覆蓋率主數值與可見範圍、原始分母","Passed":true}'