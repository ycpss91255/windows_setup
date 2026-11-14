#Requires -Version 5.1
function New-PairedOverviewHtml {
 param($Native,$Container,[string]$Title='主線測試結果')
 $encode={param($v) [Net.WebUtility]::HtmlEncode([string]$v)}
 $passed=$Native.Success -and $Container.Success -and $Native.Totals.UnexecutedSuites -eq 0 -and $Container.Totals.UnexecutedSuites -eq 0
 $status=if($passed){'目前程式檢查通過'}else{'目前程式檢查未通過'};$stamp=([DateTimeOffset]::Parse($Native.MeasuredAt)).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss')+' UTC';$tag=if($passed){'tag'}else{'tag failed'}
 $coverage=if($Native.PSObject.Properties['RepoCoverage']){(Get-RepoCoverageScopeLabel $Native.RepoCoverage)+' 覆蓋率：'+(Get-RepoCoverageSummary $Native.RepoCoverage)}else{'尚未完整量測'}
 $body='<section class="hero"><span class="'+$tag+'">'+$status+'</span><h2>這份版本的自動檢查結果</h2><p>來源：'+(& $encode ($Native.RefType+' / '+$Native.RefName))+' · 提交 <code>'+(& $encode $Native.Commit)+'</code><br>量測時間（UTC）：'+(& $encode $stamp)+'</p><div class="nav"><a class="btn" href="https://github.com/ycpss91255/windows_setup/blob/'+(& $encode $Native.Commit)+'/readme.md">查看本次來源的使用說明</a><a class="secondary" href="https://github.com/ycpss91255/windows_setup/blob/main/readme.md">主線使用說明</a><a class="secondary" href="main/index.html">主線完整報告</a><a class="secondary" href="'+(& $encode $Native.RunUrl)+'">查看執行紀錄</a></div></section>'
 $body+='<div class="grid"><article class="card"><h3>測試狀態</h3><div class="big">'+$status+'</div><p class="muted">靜態、單元及隔離整合測試</p></article><article class="card"><h3>原生檢查項目（斷言）</h3><div class="big">'+$Native.Totals.AssertionsPassed+' / '+$Native.Totals.AssertionsExecuted+'</div><p class="muted">'+$Native.Totals.SuitesExecuted+' 組測試 · 失敗 '+$Native.Totals.AssertionsFailed+'</p></article><article class="card"><h3>原生整體覆蓋率</h3><div class="big">'+(& $encode $coverage)+'</div><p class="muted">容器未量測，不合併分母。</p></article></div>'
 $pairs=@([pscustomobject]@{Label='Windows 原生';Path='native';Report=$Native},[pscustomobject]@{Label='Windows 容器';Path='windows_container';Report=$Container})
 $body+='<section class="section"><h2>分環境查看</h2><div class="envs">'
 foreach($pair in $pairs){
  $r=$pair.Report;$good=$r.Success -and $r.Totals.UnexecutedSuites -eq 0;$state=if($good){'測試通過'}else{'測試未通過'};$class=if($good){'tag'}else{'tag failed'}
  $measure=if($pair.Path -eq 'native'){$coverage}else{'容器未量測'}
  $extra=if($pair.Path -eq 'native'){'<p><a href="native/repo_coverage.json">整體量測證據</a> · <a href="native/coverage_inventory.json">來源清單</a> · <a href="native/coverage.xml">逐行結果</a></p>'}else{''}
  $body+='<article class="env"><span class="'+$class+'">'+$state+'</span><h3>'+(& $encode $pair.Label)+'</h3><div class="row"><span>測試組數</span><strong>'+$r.Totals.SuitesExecuted+' 組測試</strong></div><div class="row"><span>檢查項目（斷言）</span><strong>'+$r.Totals.AssertionsPassed+' / '+$r.Totals.AssertionsExecuted+' · 失敗 '+$r.Totals.AssertionsFailed+'</strong></div><div class="row"><span>覆蓋率</span><strong>'+(& $encode $measure)+'</strong></div><p class="muted">'+(& $encode $r.Environment)+'</p><p><a href="'+$pair.Path+'/index.html">查看完整報表與證據</a></p><p><a href="'+$pair.Path+'/summary.json">JSON</a> · <a href="'+$pair.Path+'/junit.xml">JUnit</a> · <a href="'+$pair.Path+'/summary.md">文字摘要</a></p>'+$extra+'</article>'
 }
 $body+='</div></section><section class="section"><h2>這次檢查了什麼</h2>'
 $rows=@(foreach($pair in $pairs){foreach($check in @($pair.Report.Checks)){[pscustomobject]@{Label=$pair.Label;Check=$check}}})
 foreach($row in @($rows|Sort-Object @{Expression={if($_.Check.Status -eq 'Failed'){0}elseif($_.Check.Status -eq 'NotRun'){1}else{2}}})){
  $check=$row.Check;$state=if($check.Status -eq 'Failed'){'失敗'}elseif($check.Status -eq 'NotRun'){'未執行'}else{'通過'}
  $body+='<details><summary>'+(& $encode ($row.Label+' · '+$check.Layer+' · '+$check.Name+' · '+$state))+'</summary><ul>'
  foreach($assertion in @($check.Assertions)){$assertionState=if(-not $check.Executed){'未執行'}elseif($assertion.Passed){'通過'}else{'失敗'};$body+='<li>'+(& $encode ($assertion.Name+' · '+$assertionState))+'</li>'}
  $body+='</ul></details>'
 }
 $body+='</section>'
 $template=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../test/report_bundle_tool/overview.html'),[Text.Encoding]::UTF8).TrimStart([char]0xfeff)
 return $template.Replace('{{TITLE}}',(& $encode $Title)).Replace('{{BODY}}',$body)
}
function Get-TestReportArtifactNames {
 param([ValidateSet(1,2)][int]$SchemaVersion,[switch]$IncludeGoProfile)
 $files=@('index.html','summary.json','summary.md','junit.xml','unit.svg','integration.svg','coverage.svg')
 if($SchemaVersion -eq 1){$files+=@('system.svg')}else{$files+=@('repo_coverage.json','coverage_inventory.json','coverage.xml')}
 if($IncludeGoProfile){$files+=@('go_coverage.out')}
 return $files
}
function Get-TestIdentityMap {
 param($Snapshot)
 $map=@{}
 foreach($suite in @($Snapshot.Checks)){
  $suiteId=$suite.Layer+' / '+$suite.Name+' / [suite execution]'
  if($map.ContainsKey($suiteId)){throw ('重複測試識別：'+$suiteId)}
  $map[$suiteId]=if(-not $suite.Executed){'NotRun'}elseif($suite.Passed){'Passed'}else{'Failed'}
  $items=@($suite.Assertions)
  if(-not $items.Count){$items=@([pscustomobject]@{Name='[suite]';Passed=$suite.Passed})}
  foreach($item in $items){
   $id=$suite.Layer+' / '+$suite.Name+' / '+$item.Name
   if($map.ContainsKey($id)){throw ('重複測試識別：'+$id)}
   $status=if(-not $suite.Executed){'NotRun'}elseif(-not $suite.Passed -and $item.Name -eq '[suite]'){'Failed'}elseif($item.Passed){'Passed'}else{'Failed'}
   $map[$id]=$status
  }
 }
 return $map
}
function Compare-TestSnapshots {
 param($Baseline,$Candidate)
 if($null -eq $Baseline -or $null -eq $Candidate){return [pscustomobject]@{Status='Unknown';Reason='至少一個版本沒有可驗證的品質快照。';CoverageDelta='Unknown / NotMeasured';Added=@();Removed=@();NewFailures=@();Fixed=@();NotRun=@()}}
 if($Baseline.SchemaVersion -ne $Candidate.SchemaVersion -or $Baseline.RequestedLayer -cne 'All' -or $Candidate.RequestedLayer -cne 'All' -or $Baseline.Environment -cne $Candidate.Environment -or -not $Baseline.Environment -or $Baseline.Environment -eq 'Unknown'){
  return [pscustomobject]@{Status='Unknown';Reason='測試範圍、schema 或量測環境不相容，不能推論測試差異。';CoverageDelta='Unknown / NotMeasured';Added=@();Removed=@();NewFailures=@();Fixed=@();NotRun=@()}
 }
 try{$a=Get-TestIdentityMap $Baseline;$b=Get-TestIdentityMap $Candidate}catch{
  if(-not $_.Exception.Message.StartsWith('重複測試識別：')){throw}
  return [pscustomobject]@{Status='Unknown';Reason=($_.Exception.Message+'；無法唯一對應測試，不能推論版本差異。');CoverageDelta='Unknown / NotMeasured';Added=@();Removed=@();NewFailures=@();Fixed=@();NotRun=@()}
 }
 [pscustomobject]@{Status='Compared';BaselineVersion=$Baseline.Version;CandidateVersion=$Candidate.Version;BaselineCommit=$Baseline.Commit;CandidateCommit=$Candidate.Commit;BaselineMeasuredAt=$Baseline.MeasuredAt;CandidateMeasuredAt=$Candidate.MeasuredAt;CoverageDelta='Unknown / NotMeasured';Added=@($b.Keys|Where-Object {-not $a.ContainsKey($_)}|Sort-Object);Removed=@($a.Keys|Where-Object {-not $b.ContainsKey($_)}|Sort-Object);NewFailures=@($b.Keys|Where-Object {$b[$_] -eq 'Failed' -and (-not $a.ContainsKey($_) -or $a[$_] -ne 'Failed')}|Sort-Object);Fixed=@($b.Keys|Where-Object {$b[$_] -eq 'Passed' -and $a.ContainsKey($_) -and $a[$_] -eq 'Failed'}|Sort-Object);NotRun=@($b.Keys|Where-Object {$b[$_] -eq 'NotRun'}|Sort-Object)}
}
function Write-SnapshotView {
 param($Snapshot,[string]$OutputDirectory,[switch]$OmitGoProfileLink,[switch]$OverviewPresentation)
 Write-TestReports -LegacyPresentation:(-not $OverviewPresentation) -OmitGoProfileLink:$OmitGoProfileLink -SchemaVersion $Snapshot.SchemaVersion -Checks @($Snapshot.Checks) -OutputDirectory $OutputDirectory -Layer $Snapshot.RequestedLayer -Commit $Snapshot.Commit -RunUrl $Snapshot.RunUrl -SourceState $Snapshot.SourceState -Version $Snapshot.Version -Environment $Snapshot.Environment -RefType $Snapshot.RefType -RefName $Snapshot.RefName -MeasuredAt $Snapshot.MeasuredAt -Changes $Snapshot.Changes -RepoCoverage $(if($Snapshot.PSObject.Properties['RepoCoverage']){$Snapshot.RepoCoverage}else{$null}) -GoCoverage $(if($Snapshot.PSObject.Properties['GoCoverage']){$Snapshot.GoCoverage}else{$null})|Out-Null
}
. (Join-Path $PSScriptRoot 'owned_temp.ps1')
function Test-PortalZipEvidence {
 param($Entry,[string]$BundleToolPath=$env:WINDOWS_SETUP_REPORT_BUNDLE_TOOL,[string]$ExpectedRepository=$env:GH_REPO)
 if($Entry.Immutable -isnot [bool] -or -not $Entry.Immutable){throw 'Release 未鎖定。'}
 if($Entry.Version -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?$' -or $Entry.Commit -cnotmatch '^[a-f0-9]{40}$'){throw '版本或提交不合法。'}
 if($ExpectedRepository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Entry.Repository -cne $ExpectedRepository -or $Entry.ArchiveDigest -cnotmatch '^sha256:[a-f0-9]{64}$' -or $Entry.ArchiveSize -le 0){throw '儲存庫或附件摘要不合法。'}
 if($Entry.ReleaseUrl -cne ('https://github.com/'+$ExpectedRepository+'/releases/tag/'+$Entry.Version)){throw 'Release 網址與可信儲存庫或版本不符。'}
 if(-not (Test-Path -LiteralPath $Entry.ArchivePath -PathType Leaf) -or -not (Test-Path -LiteralPath $Entry.SourcePath -PathType Container) -or -not (Test-Path -LiteralPath $BundleToolPath -PathType Leaf)){throw '缺少 ZIP、精確來源或驗證工具。'}
 $owner=New-ReportOwnedTemp -Purpose Portal
 $parent=$owner.Path
 $output=Join-Path $parent 'verified'
 $oldGlobal=$env:GIT_CONFIG_GLOBAL;$oldSystem=$env:GIT_CONFIG_NOSYSTEM
 try {
  $env:GIT_CONFIG_GLOBAL='NUL';$env:GIT_CONFIG_NOSYSTEM='1'
  & $BundleToolPath verify --historical --archive $Entry.ArchivePath --archive-sha256 $Entry.ArchiveDigest.Substring(7) --archive-size ([string]$Entry.ArchiveSize) --source-root $Entry.SourcePath --version $Entry.Version --commit $Entry.Commit --output-dir $output | Out-Null
  if($LASTEXITCODE -ne 0){throw 'ZIP 驗證失敗。'}
  $metadata=Get-Content -LiteralPath (Join-Path $output 'verified.json') -Raw -Encoding UTF8|ConvertFrom-Json
  if($metadata.context_origin -cne 'immutable_archive_manifest' -or $metadata.version -cne $Entry.Version -or $metadata.commit -cne $Entry.Commit -or ('sha256:'+$metadata.archive_sha256) -cne $Entry.ArchiveDigest -or $metadata.archive_size -ne $Entry.ArchiveSize){throw '驗證結果與 Release 不符。'}
  if($metadata.run_url -cnotmatch ('^https://github\.com/'+[regex]::Escape($Entry.Repository)+'/actions/runs/[1-9][0-9]*$')){throw '執行紀錄不屬於可信儲存庫。'}
  $native=Join-Path $output 'native';$summary=Join-Path $native 'summary.json'
  if((Get-FileHash -LiteralPath $summary -Algorithm SHA256).Hash.ToLowerInvariant() -cne $metadata.summary_sha256){throw '驗證輸出摘要不符。'}
  $snapshot=Get-Content -LiteralPath $summary -Raw -Encoding UTF8|ConvertFrom-Json
  Assert-TestReportSnapshot -Report $snapshot -Release
  $scope='core-modules-powershell-and-modules-native-csharp';$runtime=$metadata.PSObject.Properties['coverage_scope'] -and $metadata.coverage_scope -ceq $scope
  if($runtime){
   if(-not $snapshot.PSObject.Properties['RepoCoverage'] -or $snapshot.RepoCoverage.SchemaVersion -ne 2 -or $snapshot.RepoCoverage.Scope -cne $scope -or $metadata.PSObject.Properties['profile_sha256'] -or (Test-Path -LiteralPath (Join-Path $native 'go_coverage.out'))){throw 'runtime 收據與報告範圍不符。'}
  }else{
   if($metadata.PSObject.Properties['coverage_scope'] -or ($snapshot.PSObject.Properties['RepoCoverage'] -and $snapshot.RepoCoverage.SchemaVersion -eq 2) -or -not $metadata.PSObject.Properties['profile_sha256'] -or (Get-FileHash -LiteralPath (Join-Path $native 'go_coverage.out') -Algorithm SHA256).Hash.ToLowerInvariant() -cne $metadata.profile_sha256){throw '歷史收據與 Go profile 不符。'}
  }
  $files=@(Get-TestReportArtifactNames $snapshot.SchemaVersion -IncludeGoProfile:(-not $runtime)|ForEach-Object {[pscustomobject]@{Name=$_}})
  return [pscustomobject]@{Snapshot=$snapshot;Manifest=[pscustomobject]@{Files=$files};HasGoProfile=(-not $runtime);AssetDirectory=$native;SnapshotPath=$summary;SnapshotDigest=('sha256:'+$metadata.summary_sha256);ArchiveDigest=$Entry.ArchiveDigest;TemporaryOwner=$owner}
 } catch {Remove-ReportOwnedTemp -Handle $owner;throw} finally {$env:GIT_CONFIG_GLOBAL=$oldGlobal;$env:GIT_CONFIG_NOSYSTEM=$oldSystem}
}
function Test-PortalReleaseEvidence {
 param($Entry,[string]$CoverageToolPath=$env:WINDOWS_SETUP_COVERAGE_TOOL)
 if($Entry.PSObject.Properties['ArchivePath'] -and $Entry.ArchivePath){
  if($Entry.SnapshotPath -or $Entry.ManifestPath){throw 'ZIP 與舊品質附件不可混合。'}
  return Test-PortalZipEvidence -Entry $Entry
 }
 if($Entry.Version -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?$'){throw '版本名稱不合法。'}
 if($Entry.Immutable -isnot [bool] -or $Entry.Immutable -cne $true){throw 'Release 未鎖定，不能作為不可變版本證據。'}
 if($Entry.Commit -notmatch '^[a-fA-F0-9]{40}$'){throw '缺少標籤來源提交。'}
 foreach($key in @('SnapshotPath','ManifestPath')){if(-not(Test-Path -LiteralPath $Entry.$key -PathType Leaf)){throw '缺少品質證據附件。'}}
 $actual=(Get-FileHash -LiteralPath $Entry.SnapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
 if($Entry.SnapshotDigest -cne ('sha256:'+$actual)){throw 'GitHub 品質附件 digest 不符。'}
 $manifestActual=(Get-FileHash -LiteralPath $Entry.ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
 if($Entry.ManifestDigest -cne ('sha256:'+$manifestActual)){throw 'GitHub manifest digest 不符。'}
 $snapshot=Get-Content -LiteralPath $Entry.SnapshotPath -Raw -Encoding UTF8|ConvertFrom-Json
 $manifest=Get-Content -LiteralPath $Entry.ManifestPath -Raw -Encoding UTF8|ConvertFrom-Json
 if($manifest.SchemaVersion -notin @(1,2) -or $manifest.SchemaVersion -ne $snapshot.SchemaVersion){throw '品質 manifest 與報告 schema 不相符。'}
 Assert-TestReportSnapshot -Report $snapshot -Release
 if($snapshot.Version -cne $Entry.Version -or $snapshot.Commit -cne $Entry.Commit -or $manifest.Version -cne $Entry.Version -or $manifest.Commit -cne $Entry.Commit -or $manifest.SnapshotSHA256 -cne $actual){throw '版本、來源提交或品質 digest 不一致。'}
 $profileDeclared=@($manifest.Files|Where-Object Name -ceq 'go_coverage.out').Count -gt 0
 if(-not $profileDeclared -and @($Entry.AssetDigests|Where-Object Name -ceq 'go_coverage.out').Count){throw 'GitHub Go profile 附件沒有列入不可變 manifest。'}
 if($profileDeclared -and -not $snapshot.PSObject.Properties['GoCoverage']){throw '原始 Go profile 缺少來源量測資料。'}
 $required=@(Get-TestReportArtifactNames $snapshot.SchemaVersion -IncludeGoProfile:$profileDeclared)
 if(@($manifest.Files).Count -ne $required.Count){throw '品質 manifest 不完整。'}
 foreach($name in $required){
  $items=@($manifest.Files|Where-Object {$_.Name -ceq $name});if($items.Count -ne 1 -or $items[0].SHA256 -cnotmatch '^[a-f0-9]{64}$'){throw '品質 manifest 缺少或重複必要檔案。'}
  $local=if($name -eq 'summary.json'){$Entry.SnapshotPath}else{Join-Path $Entry.AssetDirectory $name}
  if(-not(Test-Path -LiteralPath $local -PathType Leaf)){throw '缺少不可變品質附件。'}
  $hash=(Get-FileHash -LiteralPath $local).Hash.ToLowerInvariant()
  $assetName=if($name -eq 'summary.json'){'quality.json'}else{$name}
  $metadata=@($Entry.AssetDigests|Where-Object Name -ceq $assetName)
  if($metadata.Count -ne 1 -or $metadata[0].Digest -cne ('sha256:'+$hash) -or $items[0].SHA256 -cne $hash){throw '不可變品質附件與 GitHub／manifest digest 不符。'}
  if($name -match '\.(html|svg)$'){
   $content=[IO.File]::ReadAllText($local)
   if($content -match '(?is)<script\b|\bon[a-z]+\s*=|javascript\s*:|<iframe\b|<object\b|<embed\b'){throw '版本附件含可執行內容，拒絕發布。'}
  }
 }
 if($profileDeclared){Assert-GoCoverageProfile -Coverage $snapshot.GoCoverage -Directory $Entry.AssetDirectory}
 if($snapshot.SchemaVersion -eq 2){Assert-RepoCoverageArtifacts -Report $snapshot -Directory $Entry.AssetDirectory -CoverageToolPath $CoverageToolPath -RequireComplete}
 [pscustomobject]@{Snapshot=$snapshot;Manifest=$manifest;HasGoProfile=$profileDeclared}
}
