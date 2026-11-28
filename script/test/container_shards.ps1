#Requires -Version 5.1
# 容器測試分片：分片數由 repo 變數決定，分派沿用 run_ci 的 Select-CISuiteShard 與實測權重；
# 合併時以同一份 suite 名冊核對各份互不重疊、聯集完整，再重寫一份完整容器報告。
$script:ContainerShardStaticName='PowerShell 5.1 語法'
function Get-CIContainerShardPlan {
 param([AllowNull()][AllowEmptyString()][string]$Value)
 $text=if($null -eq $Value){''}else{$Value.Trim()}
 if(-not $text){$count=3}
 elseif($text -cmatch '^[0-9]{1,2}$' -and [int]$text -ge 1 -and [int]$text -le 6){$count=[int]$text}
 else{throw ('容器測試分片數必須是 1 到 6 的整數：'+$Value)}
 [pscustomobject]@{Count=$count;Matrix=('['+((0..($count-1)) -join ',')+']')}
}
function Assert-CIContainerShardIdentity {
 param([int]$ShardIndex,[int]$ShardCount)
 if($ShardCount -lt 1 -or $ShardCount -gt 6 -or $ShardIndex -lt 0 -or $ShardIndex -ge $ShardCount){throw ('容器測試分片超出範圍：'+$ShardIndex+'/'+$ShardCount)}
}
function Get-CIContainerShardSuites {
 param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][int]$ShardIndex,[Parameter(Mandatory=$true)][int]$ShardCount)
 Assert-CIContainerShardIdentity -ShardIndex $ShardIndex -ShardCount $ShardCount
 . (Join-Path $PSScriptRoot 'ci_runner_library.ps1')
 . (Join-Path $PSScriptRoot 'ci_shard_library.ps1')
 $cases=@(Get-SetupCISuiteRoster -PackageRoot $PackageRoot)
 if($ShardCount -eq 1){return @($cases|ForEach-Object {[string]$_.Name})}
 return @(Select-CISuiteShard -Cases $cases -ShardIndex $ShardIndex -ShardCount $ShardCount -Weights (Get-CISuiteWeights -Path (Join-Path $PSScriptRoot 'ci_suite_weights.json')) -DefaultWeight 10|ForEach-Object {[string]$_.Name})
}
# 分片清單放在 public 報告旁邊，不混入 Go 驗收逐檔讀取的 public 目錄；
# Acceptance 只在第 0 份於容器內完成 Go 驗收與需求閘門後才寫成 true。
function Write-CIContainerShardManifest {
 param([Parameter(Mandatory=$true)][string]$Directory,[Parameter(Mandatory=$true)][int]$ShardIndex,[Parameter(Mandatory=$true)][int]$ShardCount,[switch]$Acceptance)
 Assert-CIContainerShardIdentity -ShardIndex $ShardIndex -ShardCount $ShardCount
 if($Acceptance -and $ShardIndex -ne 0){throw '只有第 0 份分片會在容器內執行 Go 驗收與需求閘門。'}
 New-Item -ItemType Directory -Path $Directory -Force|Out-Null
 $manifest=[ordered]@{SchemaVersion=1;ShardIndex=$ShardIndex;ShardCount=$ShardCount;Acceptance=[bool]$Acceptance}
 [IO.File]::WriteAllText((Join-Path $Directory 'shard.json'),($manifest|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
}
function Assert-CIContainerShardsResult {
 param([AllowNull()][AllowEmptyString()][string]$Result)
 # 矩陣工作只有全部分片成功時結果才是 success；failure、cancelled、skipped 或空值一律不能通過。
 if($Result -cne 'success'){throw ('容器測試分片結果為「'+$Result+'」，不能視為通過。')}
}
function Merge-CIContainerShardReports {
 param([Parameter(Mandatory=$true)][string]$ShardRoot,[Parameter(Mandatory=$true)][int]$ShardCount,[Parameter(Mandatory=$true)][string]$OutputDirectory,[string]$PackageRoot,[object[]]$Roster)
 if($ShardCount -lt 1 -or $ShardCount -gt 6){throw ('容器測試分片數超出範圍：'+$ShardCount)}
 . (Join-Path $PSScriptRoot 'test_report.ps1')
 if(-not $Roster){
  if(-not $PackageRoot){throw '合併容器分片需要來源根目錄以取得完整 suite 名冊。'}
  . (Join-Path $PSScriptRoot 'ci_runner_library.ps1')
  $Roster=@(Get-SetupCISuiteRoster -PackageRoot $PackageRoot)
 }
 $rosterLayers=[ordered]@{}
 foreach($case in $Roster){$rosterLayers[[string]$case.Name]=[string]$case.Layer}
 if(Test-Path -LiteralPath $OutputDirectory){throw '合併輸出目錄必須是新目錄，避免混用不同執行。'}
 if(-not(Test-Path -LiteralPath $ShardRoot -PathType Container)){throw ('找不到容器分片報告目錄：'+$ShardRoot)}
 $shards=@{}
 $accepted=0
 foreach($directory in @(Get-ChildItem -LiteralPath $ShardRoot -Directory|Sort-Object Name)){
  $manifestPath=Join-Path $directory.FullName 'shard.json'
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw ('分片目錄缺少分片清單：'+$directory.Name)}
  $manifest=[IO.File]::ReadAllText($manifestPath,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json
  if($manifest.SchemaVersion -ne 1 -or ($manifest.ShardIndex -isnot [int] -and $manifest.ShardIndex -isnot [long]) -or ($manifest.ShardCount -isnot [int] -and $manifest.ShardCount -isnot [long]) -or $manifest.Acceptance -isnot [bool]){throw ('分片清單格式不合法：'+$directory.Name)}
  if([int]$manifest.ShardCount -ne $ShardCount){throw ('分片宣稱的總份數 '+$manifest.ShardCount+' 與預期 '+$ShardCount+' 不符：'+$directory.Name)}
  $index=[int]$manifest.ShardIndex
  if($index -lt 0 -or $index -ge $ShardCount){throw ('分片索引超出範圍：'+$directory.Name)}
  if($shards.ContainsKey($index)){throw ('同一分片索引出現兩次：'+$index)}
  if($manifest.Acceptance -and $index -ne 0){throw ('容器內 Go 驗收只能由第 0 份分片宣稱：'+$directory.Name)}
  if($manifest.Acceptance){$accepted++}
  $summaryPath=Join-Path $directory.FullName 'public/summary.json'
  if(-not(Test-Path -LiteralPath $summaryPath -PathType Leaf)){throw ('分片目錄缺少 public 報告：'+$directory.Name)}
  $summary=[IO.File]::ReadAllText($summaryPath,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json
  Assert-TestReportSnapshot -Report $summary
  if([string]$summary.Environment -notmatch '^Windows container'){throw ('分片報告未標示實際 Windows 容器環境：'+$directory.Name)}
  $shards[$index]=$summary
 }
 for($index=0;$index -lt $ShardCount;$index++){if(-not $shards.ContainsKey($index)){throw ('缺少容器分片報告：'+$index+'/'+$ShardCount)}}
 if($accepted -ne 1){throw '第 0 份分片未完成容器內 Go 驗收與需求閘門，不能合併成通過的完整報告。'}
 $first=$shards[0]
 $labels=[ordered]@{Commit='提交';RunUrl='執行來源';Version='版本';RefType='版本類型';RefName='分支或標籤';SourceState='來源狀態';SchemaVersion='報表版本'}
 for($index=1;$index -lt $ShardCount;$index++){
  foreach($field in $labels.Keys){if([string]$shards[$index].$field -cne [string]$first.$field){throw ('各分片的'+$labels[$field]+'不一致：'+$index)}}
 }
 $static=New-Object Collections.Generic.List[object]
 $byName=@{}
 for($index=0;$index -lt $ShardCount;$index++){
  foreach($check in @($shards[$index].Checks)){
   $name=[string]$check.Name
   if($name -ceq $script:ContainerShardStaticName -and $check.Layer -ceq 'Static'){$static.Add($check);continue}
   if(-not $rosterLayers.Contains($name)){throw ('分片報告含名冊外的 suite：'+$name)}
   if($byName.ContainsKey($name)){throw ('同一 suite 被兩份分片重複執行：'+$name)}
   if([string]$check.Layer -cne $rosterLayers[$name]){throw ('suite 層級與名冊不符：'+$name)}
   if(-not $check.Executed){throw ('分片報告含未執行的 suite：'+$name)}
   $byName[$name]=$check
  }
 }
 if($static.Count -ne 1){throw ('合併報告必須恰好含一次 PowerShell 5.1 語法檢查，實際 '+$static.Count+' 次。')}
 $missing=@($rosterLayers.Keys|Where-Object {-not $byName.ContainsKey($_)})
 if($missing.Count){throw ('分片聯集缺少 suite：'+($missing -join ', '))}
 $checks=@($static[0])+@(foreach($name in $rosterLayers.Keys){$byName[$name]})
 $environments=@(for($index=0;$index -lt $ShardCount;$index++){[string]$shards[$index].Environment})|Select-Object -Unique
 $measured=@(for($index=0;$index -lt $ShardCount;$index++){[DateTimeOffset]::Parse([string]$shards[$index].MeasuredAt,[Globalization.CultureInfo]::InvariantCulture)})|Sort-Object|Select-Object -Last 1
 $null=Write-TestReports -Checks $checks -OutputDirectory $OutputDirectory -Layer All -Commit ([string]$first.Commit) -RunUrl ([string]$first.RunUrl) -SourceState ([string]$first.SourceState) -Version ([string]$first.Version) -Environment (@($environments) -join ' ; ') -RefType ([string]$first.RefType) -RefName ([string]$first.RefName) -MeasuredAt ($measured.UtcDateTime.ToString('o')) -Changes @($first.Changes) -SchemaVersion ([int]$first.SchemaVersion)
 $merged=[IO.File]::ReadAllText((Join-Path $OutputDirectory 'summary.json'),[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json
 Write-Host ('已合併 '+$ShardCount+' 份容器分片：'+$checks.Count+' 項（含一次語法檢查），名冊 '+$rosterLayers.Count+' 個 suite 全數到齊且互不重疊。')
 if(-not $merged.Success){throw '容器分片測試未通過；已寫出合併後的完整診斷報告。'}
 return $merged
}
