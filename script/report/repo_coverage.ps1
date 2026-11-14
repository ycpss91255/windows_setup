#Requires -Version 5.1
function Assert-RepoCoverage {
 param($Coverage,$Report)
 foreach($name in @('SchemaVersion','Metric','Commit','RunUrl','MeasuredAt','SourceState','InventorySHA256','NormalizedSHA256','Result')){if(-not $Coverage.PSObject.Properties[$name]){throw ('整體覆蓋率缺欄位：'+$name)}}
 $legacy=$Coverage.SchemaVersion -eq 1 -and $Coverage.Metric -ceq 'complete-executable-lines-v1' -and -not $Coverage.PSObject.Properties['Scope']
 $runtime=$Coverage.SchemaVersion -eq 2 -and $Coverage.Metric -ceq 'runtime-powershell-csharp-executable-lines-v2' -and $Coverage.Scope -ceq 'core-modules-powershell-and-modules-native-csharp'
 if((-not $legacy -and -not $runtime) -or $Coverage.SourceState -cne 'Clean' -or $Coverage.Commit -cnotmatch '^[a-f0-9]{40}$' -or $Coverage.InventorySHA256 -cnotmatch '^[a-f0-9]{64}$' -or $Coverage.NormalizedSHA256 -cnotmatch '^[a-f0-9]{64}$'){throw '整體覆蓋率結構或來源不符。'}
 if($Report -and ($Report.SchemaVersion -ne 2 -or $Report.Commit -cne $Coverage.Commit -or $Report.RunUrl -cne $Coverage.RunUrl -or $Report.SourceState -cne $Coverage.SourceState)){throw '整體覆蓋率與測試報告來源不一致。'}
 $stamp=[DateTimeOffset]::MinValue
 if(-not [DateTimeOffset]::TryParse($Coverage.MeasuredAt,[ref]$stamp) -or $Coverage.MeasuredAt -cnotmatch 'Z$'){throw '整體覆蓋率必須使用UTC量測時間。'}
 $r=$Coverage.Result
 foreach($name in @('SchemaVersion','Metric','Complete','Covered','Executable','Percent','Missing','Blockers','Languages')){if(-not $r.PSObject.Properties[$name]){throw ('覆蓋率結果缺欄位：'+$name)}}
 if($r.SchemaVersion -ne 1 -or $r.Metric -cne 'complete-executable-lines-v1' -or $r.Complete -isnot [bool]){throw '覆蓋率計量或完整狀態不符。'}
 $covered=0L;$executable=0L
 foreach($item in $r.Languages.PSObject.Properties){
  if($runtime -and $item.Name -cnotin @('powershell','csharp')){throw 'runtime 覆蓋率包含範圍外語言。'}
  $count=$item.Value
  foreach($name in @('Covered','Executable')){if(-not $count.PSObject.Properties[$name] -or $count.$name -isnot [ValueType] -or $count.$name -is [bool] -or $count.$name -lt 0 -or [Math]::Floor([double]$count.$name) -ne $count.$name){throw '覆蓋率計數必須是非負整數。'}}
  if($count.Covered -gt $count.Executable){throw '覆蓋行數不能超過總行數。'}
  $covered+=$count.Covered;$executable+=$count.Executable
 }
 if($r.Covered -ne $covered -or $r.Executable -ne $executable){throw '整體與語言計數不一致。'}
 if($r.Complete){
  if(@($r.Missing|Where-Object {$null -ne $_}).Count -or @($r.Blockers|Where-Object {$null -ne $_}).Count -or $executable -le 0 -or $null -eq $r.Percent -or [Math]::Abs([double]$r.Percent-100.0*$covered/$executable) -gt 0.0000001){throw '完整覆蓋率缺來源或百分比不符。'}
 }elseif($null -ne $r.Percent){throw '不完整量測不能顯示總率。'}
}
function Get-RepoCoverageScopeLabel {
 param($Coverage)
 if($null -ne $Coverage -and $Coverage.SchemaVersion -eq 2 -and $Coverage.Scope -ceq 'core-modules-powershell-and-modules-native-csharp'){return 'PowerShell/C# runtime'}
 return '整體'
}
function Get-RepoCoveragePercentText {
 param($Coverage)
 if($null -eq $Coverage -or -not $Coverage.Result.Complete){return 'not measured'}
 return ([double]$Coverage.Result.Percent).ToString('0.0',[Globalization.CultureInfo]::InvariantCulture)+'%'
}
function Get-RepoCoverageSummary {
 param($Coverage)
 if($null -eq $Coverage -or -not $Coverage.Result.Complete){return '尚未提供完整量測。'}
 return (Get-RepoCoveragePercentText $Coverage)+'（'+$Coverage.Result.Covered+'/'+$Coverage.Result.Executable+' 可執行行）'
}
function Get-RepoCoverageLanguages {
 param($Coverage)
 if($null -eq $Coverage){return @()}
 return @(foreach($item in @($Coverage.Result.Languages.PSObject.Properties|Sort-Object Name)){$item.Name+'：'+$item.Value.Covered+'/'+$item.Value.Executable+' 可執行行'})
}
function Assert-RepoCoverageArtifacts {
 param([Parameter(Mandatory=$true)]$Report,[Parameter(Mandatory=$true)][string]$Directory,[string]$CoverageToolPath=$env:WINDOWS_SETUP_COVERAGE_TOOL,[string]$SourceRoot,[switch]$RequireComplete)
 if(-not $Report.PSObject.Properties['RepoCoverage']){throw '缺少整體覆蓋率，拒絕發布。'}
 Assert-RepoCoverage $Report.RepoCoverage $Report
 $published=Get-Content -LiteralPath (Join-Path $Directory 'repo_coverage.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if(($published|ConvertTo-Json -Depth 20 -Compress) -cne ($Report.RepoCoverage|ConvertTo-Json -Depth 20 -Compress)){throw '摘要與整體覆蓋率附件不一致。'}
 if(-not $CoverageToolPath){$CoverageToolPath='repo_coverage_tool.exe'}
 $arguments=@('verify','--artifact-dir',$Directory,'--expected-sha',$Report.Commit,'--expected-run-url',$Report.RunUrl)
 if($Report.RepoCoverage.SchemaVersion -eq 2){$arguments+=@('--runtime')}
 if($SourceRoot){$arguments+=@('--source-root',$SourceRoot)}
 if($RequireComplete){$arguments+=@('--require-complete','--minimum-percent','80')}
 & $CoverageToolPath @arguments | Write-Host
 if($LASTEXITCODE -ne 0){throw ('整體覆蓋率證據驗證失敗：'+$LASTEXITCODE)}
}
