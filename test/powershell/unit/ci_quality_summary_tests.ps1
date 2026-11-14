#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'script/test/ci_quality_summary.ps1')
function Assert([bool]$Condition,[string]$Message){Write-Host ('@@ASSERT@@'+(@{Name=$Message;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Message}}
$report=[pscustomobject]@{Success=$false;Totals=[pscustomobject]@{AssertionsExecuted=10;AssertionsPassed=9;AssertionsFailed=1};RepoCoverage=[pscustomobject]@{Result=[pscustomobject]@{Complete=$true;Covered=9;Executable=10;Languages=[pscustomobject]@{go=[pscustomobject]@{Covered=1;Executable=2};powershell=[pscustomobject]@{Covered=8;Executable=8}}}};GoCoverage=[pscustomobject]@{Covered=8;TotalStatements=10;Percent=80}}
$text=New-CIQualitySummary -Report $report -AggregationState 'success'
Assert ($text -match '9/10' -and $text -match '失敗 1') '顯示測試斷言總數與失敗'
Assert ($text -match '90\.0%' -and $text -match '50\.0%' -and $text -match '100\.0%') '整體及各語言按各自分母計算'
Assert ($text -match 'statements' -and $text -match '80\.0%') 'Go statement 分項標明單位'
Assert ($text.Contains('| 整體 |') -and $text.Contains('Go 分項')) '舊口徑保留原整體與 Go 分項標示'
$runtime=[pscustomobject]@{Success=$true;Totals=[pscustomobject]@{AssertionsExecuted=10;AssertionsPassed=10;AssertionsFailed=0};RepoCoverage=[pscustomobject]@{SchemaVersion=2;Metric='runtime-powershell-csharp-executable-lines-v2';Scope='core-modules-powershell-and-modules-native-csharp';Result=[pscustomobject]@{Complete=$true;Covered=9;Executable=10;Languages=[pscustomobject]@{powershell=[pscustomobject]@{Covered=8;Executable=8};csharp=[pscustomobject]@{Covered=1;Executable=2}}}};GoCoverage=$null}
$runtimeText=New-CIQualitySummary -Report $runtime -AggregationState 'success'
Assert ($runtimeText.Contains('| PowerShell/C# runtime（core/modules 自有；不含 Go/CMD） | 90.0% | 9/10 |') -and -not $runtimeText.Contains('| 整體 |')) '新版摘要明示 runtime 範圍與排除語言'
$failed=New-CIQualitySummary -Report $null -AggregationState 'failure'
Assert ($failed -match '失敗' -and $failed -match '未提供完整量測' -and $failed -notmatch '80\.0%') '失敗或資料缺失不假稱覆蓋率'
