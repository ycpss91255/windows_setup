#Requires -Version 5.1
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
 param($Snapshot,[string]$OutputDirectory,[switch]$OmitGoProfileLink)
 Write-TestReports -OmitGoProfileLink:$OmitGoProfileLink -SchemaVersion $Snapshot.SchemaVersion -Checks @($Snapshot.Checks) -OutputDirectory $OutputDirectory -Layer $Snapshot.RequestedLayer -Commit $Snapshot.Commit -RunUrl $Snapshot.RunUrl -SourceState $Snapshot.SourceState -Version $Snapshot.Version -Environment $Snapshot.Environment -RefType $Snapshot.RefType -RefName $Snapshot.RefName -MeasuredAt $Snapshot.MeasuredAt -Changes $Snapshot.Changes -RepoCoverage $(if($Snapshot.PSObject.Properties['RepoCoverage']){$Snapshot.RepoCoverage}else{$null}) -GoCoverage $(if($Snapshot.PSObject.Properties['GoCoverage']){$Snapshot.GoCoverage}else{$null})|Out-Null
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
