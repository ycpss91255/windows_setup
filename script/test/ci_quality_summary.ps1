#Requires -Version 5.1
function New-CIQualitySummary {
 param($Report,[string]$AggregationState)
 $lines=@('## 同次品質摘要','')
 if($AggregationState -cne 'success' -or $null -eq $Report -or $null -eq $Report.RepoCoverage -or -not $Report.RepoCoverage.Result.Complete){return ($lines+@('**失敗或未提供完整量測。**') -join "`n")}
 $t=$Report.Totals
 $lines+=('斷言：'+$t.AssertionsPassed+'/'+$t.AssertionsExecuted+'；失敗 '+$t.AssertionsFailed)
 if(-not $Report.Success){$lines+='**測試失敗**'}
 $lines+=@('','| 範圍 | 覆蓋率 | 可執行行 |','| --- | ---: | ---: |')
 $r=$Report.RepoCoverage.Result
 $scope='整體'
 if($Report.RepoCoverage.SchemaVersion -eq 2 -and $Report.RepoCoverage.Metric -ceq 'runtime-powershell-csharp-executable-lines-v2' -and $Report.RepoCoverage.Scope -ceq 'core-modules-powershell-and-modules-native-csharp'){$scope='PowerShell/C# runtime（core/modules 自有；不含 Go/CMD）'}
 $items=@([pscustomobject]@{Name=$scope;Covered=$r.Covered;Executable=$r.Executable})+@($r.Languages.PSObject.Properties | Sort-Object Name | ForEach-Object {[pscustomobject]@{Name=$_.Name;Covered=$_.Value.Covered;Executable=$_.Value.Executable}})
 foreach($item in $items){$pct=if($item.Executable -gt 0){(100.0*$item.Covered/$item.Executable).ToString('0.0',[Globalization.CultureInfo]::InvariantCulture)+'%'}else{'未量測'};$lines+='| '+$item.Name+' | '+$pct+' | '+$item.Covered+'/'+$item.Executable+' |'}
 if($Report.GoCoverage){$g=$Report.GoCoverage;$lines+=@('',('Go 分項：'+([double]$g.Percent).ToString('0.0',[Globalization.CultureInfo]::InvariantCulture)+'%（'+$g.Covered+'/'+$g.TotalStatements+' statements；門檻 80%，與可執行行不同）'))}
 return ($lines -join "`n")
}
function Invoke-CIShardTimed {
 param([Parameter(Mandatory=$true)][int]$ShardIndex,[Parameter(Mandatory=$true)][string]$SummaryPath,[Parameter(Mandatory=$true)][scriptblock]$Action)
 $timer=[Diagnostics.Stopwatch]::StartNew();$completed=$false
 try { & $Action; $completed=$true } finally {
  $timer.Stop()
  $state=if($completed){'success'}else{'failure；未提供完整量測'}
  try {Add-Content -LiteralPath $SummaryPath -Encoding UTF8 -Value ("## PowerShell 分片 $ShardIndex`n`n分片量測階段耗時：$([Math]::Round($timer.Elapsed.TotalSeconds,1)) 秒；結果：$state。") } catch {if($completed){throw}}
 }
}
function Write-CIQualityFailureSummary {
 param([Parameter(Mandatory=$true)][hashtable]$States,[Parameter(Mandatory=$true)][string]$SummaryPath)
 if(@($States.Values | Where-Object {$_ -cne 'success'}).Count){
  Add-Content -LiteralPath $SummaryPath -Encoding UTF8 -Value '## 品質檢查失敗或未完成'
  foreach($key in @($States.Keys | Sort-Object)){Add-Content -LiteralPath $SummaryPath -Encoding UTF8 -Value ("- ${key}: $($States[$key])")}
  if($States.Coverage -cne 'success'){Add-Content -LiteralPath $SummaryPath -Encoding UTF8 -Value '**未提供完整量測。**'}
 }
}
