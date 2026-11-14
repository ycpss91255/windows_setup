#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$CatalogPath,[Parameter(Mandatory=$true)][string]$OutputDirectory,[string]$MainSnapshotPath,[switch]$RequireGoCoverage,[string]$CoverageToolPath=$env:WINDOWS_SETUP_COVERAGE_TOOL,[switch]$Preview)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../test/test_report.ps1')
. (Join-Path $PSScriptRoot 'portal.ps1')
$output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if(Test-Path -LiteralPath $output){throw 'Portal 輸出必須是新目錄，避免混入過期版本頁。'}
New-Item -ItemType Directory $output|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
$catalog=Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8|ConvertFrom-Json
$snapshots=@{};$versions=New-Object Collections.Generic.List[object]
foreach($entry in $catalog){
 if($entry.Version -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?$'){continue}
 if(@($versions|Where-Object Version -ceq $entry.Version).Count){throw '重複版本，拒絕覆寫。'}
 $dir=Join-Path $output ('versions/'+$entry.Version)
 $state='Unknown';$reason='此舊版本未提供可驗證品質快照；不以目前 CI 回填。';$evidence=$null
 if(($entry.SnapshotPath -and $entry.ManifestPath) -or ($entry.PSObject.Properties['ArchivePath'] -and $entry.ArchivePath)){
  try{$evidence=Test-PortalReleaseEvidence -Entry $entry -CoverageToolPath $CoverageToolPath}catch{$reason='品質證據未通過驗證：'+(Protect-ReportText $_.Exception.Message);$state='Invalid'}
 }
 try {
 if($evidence){
  Write-SnapshotView $evidence.Snapshot $dir -OmitGoProfileLink:(-not $evidence.HasGoProfile)
  foreach($file in $evidence.Manifest.Files){
   if($file.Name -eq 'index.html'){continue}
   $source=if($evidence.PSObject.Properties['AssetDirectory']){Join-Path $evidence.AssetDirectory $file.Name}elseif($file.Name -eq 'summary.json'){$entry.SnapshotPath}else{Join-Path $entry.AssetDirectory $file.Name}
   Copy-Item -LiteralPath $source -Destination (Join-Path $dir $file.Name)
  }
  $rendered=Join-Path $dir 'index.html'
  $releaseLink=[Net.WebUtility]::HtmlEncode($entry.ReleaseUrl)
  $notice='<p>此頁依原始版本紀錄整理；<a href="'+$releaseLink+'">不可變原始附件見 Release</a>。</p>'
  [IO.File]::WriteAllText($rendered,([IO.File]::ReadAllText($rendered)).Replace('</body>',$notice+'</body>'),$utf8)
  $snapshots[$entry.Version]=$evidence.Snapshot;$state='Verified';$reason='原始量測與不可變 Release digest 已核對。'
 }else{
  New-Item -ItemType Directory $dir -Force|Out-Null
  $safeVersion=[Net.WebUtility]::HtmlEncode($entry.Version);$safeReason=[Net.WebUtility]::HtmlEncode($reason)
  [IO.File]::WriteAllText((Join-Path $dir 'index.html'),('<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><title>'+ $safeVersion +' · 測試紀錄</title><h1>'+ $safeVersion +'</h1><p>'+ $safeReason +'</p><p>這個版本未保存可用的測試紀錄，無法判斷當時的測試結果。</p><a href="../../index.html">版本索引</a></html>'),$utf8)
 }
 $versions.Add([pscustomobject]@{Version=$entry.Version;Commit=$entry.Commit;Status=$state;Reason=$reason;Path=('versions/'+$entry.Version+'/index.html');ReleaseUrl=$entry.ReleaseUrl;MeasuredAt=$(if($evidence){$evidence.Snapshot.MeasuredAt}else{'Unknown'});Digest=$(if($evidence -and $evidence.PSObject.Properties['SnapshotDigest']){$evidence.SnapshotDigest}else{$entry.SnapshotDigest});ArchiveDigest=$(if($evidence -and $evidence.PSObject.Properties['ArchiveDigest']){$evidence.ArchiveDigest}else{''})})
 } finally {if($evidence -and $evidence.PSObject.Properties['TemporaryOwner']){Remove-ReportOwnedTemp -Handle $evidence.TemporaryOwner}}
}
$mainStatus='Unknown'
 if(-not $Preview -and (-not $MainSnapshotPath -or -not(Test-Path -LiteralPath $MainSnapshotPath -PathType Leaf))){throw '正式Pages需要本次完整報告。'}
if($RequireGoCoverage -and (-not $MainSnapshotPath -or -not(Test-Path -LiteralPath $MainSnapshotPath -PathType Leaf))){throw 'main 發布必須提供 Go 覆蓋率報告。'}
if($MainSnapshotPath -and (Test-Path -LiteralPath $MainSnapshotPath)){
 $main=Get-Content -LiteralPath $MainSnapshotPath -Raw -Encoding UTF8|ConvertFrom-Json
 Assert-TestReportSnapshot -Report $main
 if($main.RefType -cne 'Branch' -or $main.RefName -cne 'main' -or $main.SourceState -cne 'Clean' -or $main.RequestedLayer -cne 'All'){throw 'main 品質來源標記不符。'}
 if(-not $Preview){
  if(-not $main.PSObject.Properties['RepoCoverage'] -or $main.RepoCoverage.SchemaVersion -ne 2 -or $main.RepoCoverage.Metric -cne 'runtime-powershell-csharp-executable-lines-v2' -or $main.RepoCoverage.Scope -cne 'core-modules-powershell-and-modules-native-csharp'){throw '正式主線必須使用 PowerShell/C# runtime 覆蓋範圍。'}
  Assert-RepoCoverageArtifacts -Report $main -Directory (Split-Path -Parent $MainSnapshotPath) -CoverageToolPath $CoverageToolPath -RequireComplete
 }
 $hasRepo=$null -ne $main.PSObject.Properties['RepoCoverage']
 if($Preview -and $hasRepo){Assert-RepoCoverageArtifacts -Report $main -Directory (Split-Path -Parent $MainSnapshotPath) -CoverageToolPath $CoverageToolPath}
 $hasGo=$null -ne $main.PSObject.Properties['GoCoverage']
 if($RequireGoCoverage -and -not $hasGo){throw 'main 發布缺少 Go 覆蓋率。'}
 if($hasGo){Assert-GoCoverageProfile -Coverage $main.GoCoverage -Directory (Split-Path -Parent $MainSnapshotPath)}
 Write-SnapshotView $main (Join-Path $output 'main');$mainStatus='Available'
 if($hasRepo){foreach($name in @('repo_coverage.json','coverage_inventory.json','coverage.xml')){Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $MainSnapshotPath) $name) -Destination (Join-Path $output ('main/'+$name))}}
 if($hasGo){Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $MainSnapshotPath) 'go_coverage.out') -Destination (Join-Path $output 'main/go_coverage.out')}
}
[IO.File]::WriteAllText((Join-Path $output 'versions.json'),(ConvertTo-Json -InputObject @($versions.ToArray()) -Depth 6),$utf8)
$links=(@($versions|ForEach-Object {
 $label=if($_.Status -eq 'Verified'){'已保存測試紀錄'}elseif($_.Status -eq 'Invalid'){'測試紀錄無法驗證'}else{'未保存測試紀錄'}
 '<li><a href="'+$_.Path+'">'+[Net.WebUtility]::HtmlEncode($_.Version)+'</a> · '+$label+'</li>'
}) -join '')
if(-not $links){$links='<li>目前沒有已發布版本。</li>'}
$mainLink='<h2>尚無本次報告</h2><p>目前沒有可核對的最新程式檢查結果，請稍後查看或開啟執行紀錄。</p>'
if($mainStatus -eq 'Available'){
 $headline=if($main.Success){'目前程式檢查通過'}else{'目前程式檢查未通過'}
 $stamp=([DateTimeOffset]::Parse($main.MeasuredAt)).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss')+' UTC'
 $shortCommit=if($main.Commit.Length -ge 7){$main.Commit.Substring(0,7)}else{$main.Commit}
 $mainLink='<h2>'+$headline+'</h2><p>檢查對象：開發主線 main · 提交 <code>'+[Net.WebUtility]::HtmlEncode($shortCommit)+'</code><br>檢查時間：'+[Net.WebUtility]::HtmlEncode($stamp)+'</p><p>已執行程式邏輯檢查（單元測試），以及隔離環境中的模組配合檢查（整合測試）。</p><p><a class="button" href="main/index.html">查看本次檢查明細</a></p>'
}
$coverageNotice='尚未提供完整量測。'
$coverageHeading='整體覆蓋率'
 if($mainStatus -eq 'Available' -and $hasRepo){$coverageNotice=[Net.WebUtility]::HtmlEncode((Get-RepoCoverageSummary $main.RepoCoverage))}
 if($mainStatus -eq 'Available' -and $hasRepo -and (Get-RepoCoverageScopeLabel $main.RepoCoverage) -eq 'PowerShell/C# runtime'){$coverageHeading='PowerShell/C# runtime 覆蓋率'}
$html=@"
<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Windows 設定工具｜測試結果</title><style>body{font:16px/1.65 system-ui;max-width:880px;margin:32px auto;padding:0 20px;color:#17202a}h1{font-size:28px}h2{font-size:22px}section{border-top:1px solid #dce3ea;padding:16px 0}a{color:#1558ad}li{margin:8px 0}code{font-size:14px}</style><body><h1>Windows 設定工具｜測試結果</h1><section>$mainLink</section><section><h2>整體覆蓋率</h2><p>$coverageNotice</p></section><section><h2>使用與下載</h2><p><a href="https://github.com/ycpss91255/windows_setup/blob/main/readme.md">USB 安裝與使用步驟</a> · <a href="https://github.com/ycpss91255/windows_setup/releases">下載 Release</a> · <a href="https://github.com/ycpss91255/windows_setup/actions/workflows/windows_tests.yml">Actions 執行紀錄</a></p></section><section><h2>版本紀錄</h2><ul>$links</ul></section></body></html>
"@
$html=$html.Replace('<h2>整體覆蓋率</h2>','<h2>'+[Net.WebUtility]::HtmlEncode($coverageHeading)+'</h2>')
[IO.File]::WriteAllText((Join-Path $output 'index.html'),$html,$utf8)
[pscustomobject]@{OutputDirectory=$output;Versions=$versions.Count;MainStatus=$mainStatus}
