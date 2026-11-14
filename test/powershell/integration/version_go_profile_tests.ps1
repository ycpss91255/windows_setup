#Requires -Version 5.1
$ErrorActionPreference='Stop'
# Reuse the real complete-coverage CLI fixture and mock publish/download flow.
. (Join-Path $PSScriptRoot 'repo_publication_tests.ps1')
Assert (-not (Test-Path -LiteralPath (Join-Path $downloaded.AssetDirectory 'go_coverage.out')) -and (Get-FileHash (Join-Path $downloaded.AssetDirectory 'coverage.xml')).Hash -eq (Get-FileHash (Join-Path $public 'coverage.xml')).Hash) '新版附件經下載保留原 runtime 證據且不含 Go profile'
$legacyPublic=Join-Path $fixture 'legacy_go_public';New-Item -ItemType Directory $legacyPublic|Out-Null
$legacyCoverage=$c|ConvertTo-Json -Depth 20|ConvertFrom-Json;$legacyCoverage.SchemaVersion=1;$legacyCoverage.Metric='complete-executable-lines-v1';$legacyCoverage.PSObject.Properties.Remove('Scope')
$legacyReport=$report|ConvertTo-Json -Depth 20|ConvertFrom-Json;$legacyReport.RepoCoverage=$legacyCoverage
$goProfileText="mode: set`nwindows_setup/script/test/example/value.go:1.1,1.2 8 1`nwindows_setup/script/test/example/value.go:2.1,2.2 2 0`n"
[IO.File]::WriteAllText((Join-Path $legacyPublic 'go_coverage.out'),$goProfileText,$utf8)
$go=[pscustomobject]@{SchemaVersion=1;Scope='all-owned-go-including-cli';Metric='statements';Covered=8;TotalStatements=10;Percent=80.0;Threshold=80;Commit=$identity.Commit;RunUrl=$identity.RunUrl;MeasuredAt=$identity.MeasuredAt;SourceState='Clean';GoVersion='go1.27.3';Environment='Synthetic legacy fixture';ProfileSHA256=(Get-FileHash (Join-Path $legacyPublic 'go_coverage.out')).Hash.ToLowerInvariant();Packages=@('windows_setup/script/test/example')}
$legacyReport|Add-Member -NotePropertyName GoCoverage -NotePropertyValue $go
Write-SnapshotView $legacyReport $legacyPublic
foreach($name in @('coverage_inventory.json','coverage.xml')){Copy-Item -LiteralPath (Join-Path $public $name) -Destination $legacyPublic}
[IO.File]::WriteAllText((Join-Path $legacyPublic 'repo_coverage.json'),($legacyCoverage|ConvertTo-Json -Depth 20),$utf8)
$public=$legacyPublic;$report=$legacyReport
function New-GoVersionEvidence {
 param([string]$Directory,$Snapshot,[switch]$WithProfile)
 New-Item -ItemType Directory $Directory|Out-Null
 foreach($name in @('repo_coverage.json','coverage_inventory.json','coverage.xml')){if($Snapshot.SchemaVersion -eq 2){Copy-Item -LiteralPath (Join-Path $public $name) -Destination $Directory}}
 Write-SnapshotView $Snapshot $Directory
 Copy-Item -LiteralPath (Join-Path $Directory 'summary.json') -Destination (Join-Path $Directory 'quality.json')
 if($WithProfile){[IO.File]::WriteAllText((Join-Path $Directory 'go_coverage.out'),$goProfileText,$utf8)}
 $names=@(Get-TestReportArtifactNames -SchemaVersion $Snapshot.SchemaVersion -IncludeGoProfile:$WithProfile)
 $mf=[ordered]@{SchemaVersion=$Snapshot.SchemaVersion;Version=$Snapshot.Version;Commit=$Snapshot.Commit;SnapshotSHA256=(Get-FileHash (Join-Path $Directory 'quality.json')).Hash.ToLowerInvariant();Files=@($names|ForEach-Object {@{Name=$_;SHA256=(Get-FileHash (Join-Path $Directory $_)).Hash.ToLowerInvariant()}})}
 $mp=Join-Path $Directory 'quality-manifest.json';[IO.File]::WriteAllText($mp,($mf|ConvertTo-Json -Depth 8),$utf8)
 [pscustomobject]@{Version=$Snapshot.Version;Commit=$Snapshot.Commit;ReleaseUrl=('https://github.com/example/repo/releases/tag/'+$Snapshot.Version);Immutable=$true;SnapshotPath=(Join-Path $Directory 'quality.json');ManifestPath=$mp;SnapshotDigest=('sha256:'+$mf.SnapshotSHA256);ManifestDigest=('sha256:'+(Get-FileHash $mp).Hash.ToLowerInvariant());AssetDirectory=$Directory;AssetDigests=@(Get-ChildItem $Directory -File|ForEach-Object {[pscustomobject]@{Name=$_.Name;Digest=('sha256:'+(Get-FileHash $_.FullName).Hash.ToLowerInvariant())}})}
}
$versionFixture=Join-Path $fixture 'go_versions';New-Item -ItemType Directory $versionFixture|Out-Null
$current=New-GoVersionEvidence -Directory (Join-Path $versionFixture 'current') -Snapshot $report -WithProfile
$verified=Test-PortalReleaseEvidence -Entry $current -CoverageToolPath $tool
Assert $verified.HasGoProfile '原始Go覆蓋率只在manifest、GitHub digest與真內容皆驗證後可用'
$global:repoDownloadSource=$current.AssetDirectory
$global:repoDownloadRelease=[pscustomobject]@{draft=$false;tag_name='v1.0.0';immutable=$true;html_url=$current.ReleaseUrl;assets=@($current.AssetDigests|ForEach-Object {@{name=$_.Name;digest=$_.Digest}})}
function gh {
 $words=@($args);$global:LASTEXITCODE=0
 if($words[0] -eq 'api' -and $words -contains '--paginate'){return ($global:repoDownloadRelease|ConvertTo-Json -Depth 10 -Compress)}
 if($words[0] -eq 'api' -and $words[1] -like '*/commits/*'){return 'a'*40}
 if($words[0] -eq 'api' -and $words[1] -like '*/actions/workflows/*'){return}
 if($words[0] -eq 'release' -and $words[1] -eq 'download'){
  $destination=$words[[Array]::IndexOf($words,'--dir')+1]
  for($i=0;$i -lt $words.Count;$i++){if($words[$i] -eq '--pattern'){Copy-Item -LiteralPath (Join-Path $global:repoDownloadSource $words[$i+1]) -Destination (Join-Path $destination $words[$i+1])}}
  return
 }
 throw ('Unexpected historical mock download call: '+($words -join ' '))
}
try{
 Assert ((Get-Command gh).CommandType -eq 'Function') '歷史附件下載只使用 mock gh'
 $legacyInputs=& (Join-Path $root 'script/report/get_portal_inputs.ps1') -Repository example/repo -OutputDirectory (Join-Path $versionFixture 'historical_download')
 $legacyDownloaded=@(Get-Content $legacyInputs.CatalogPath -Raw -Encoding UTF8|ConvertFrom-Json)[0]
 $legacyDownloadedEvidence=Test-PortalReleaseEvidence -Entry $legacyDownloaded -CoverageToolPath $tool
 Assert ($legacyDownloadedEvidence.HasGoProfile -and (Get-FileHash (Join-Path $legacyDownloaded.AssetDirectory 'go_coverage.out')).Hash -eq (Get-FileHash (Join-Path $public 'go_coverage.out')).Hash) '歷史不可變附件經下載驗證仍保留同一 Go 原始 profile'
}finally{Remove-Item Function:\gh}
$cat=Join-Path $versionFixture 'catalog.json';[IO.File]::WriteAllText($cat,(ConvertTo-Json -InputObject @($current) -Depth 10),$utf8)
$out=Join-Path $versionFixture 'current_portal'
& (Join-Path $root 'script/report/build_portal.ps1') -Preview -CatalogPath $cat -OutputDirectory $out -CoverageToolPath $tool|Out-Null
$page=Join-Path $out 'versions/v1.0.0/index.html';$html=[IO.File]::ReadAllText($page)
Assert ($html.Contains('href="go_coverage.out"') -and (Test-Path (Join-Path (Split-Path $page) 'go_coverage.out'))) '實際版本頁原始Go連結有對應本地資源'
Assert ((Get-FileHash (Join-Path (Split-Path $page) 'go_coverage.out')).Hash -eq (Get-FileHash (Join-Path $public 'go_coverage.out')).Hash) '版本頁保留實際不可變profile位元組'
$rawPath=Join-Path $current.AssetDirectory 'go_coverage.out';$original=[IO.File]::ReadAllText($rawPath)
Remove-Item -LiteralPath $rawPath
Refuse {Test-PortalReleaseEvidence -Entry $current -CoverageToolPath $tool} '已聲明的原始profile缺失不能退回legacy'
[IO.File]::WriteAllText($rawPath,$original+' ',$utf8)
Refuse {Test-PortalReleaseEvidence -Entry $current -CoverageToolPath $tool} '原始profile被篡改時不得產生可下載結論'
[IO.File]::WriteAllText($rawPath,$original,$utf8)
$originalHash=$report.GoCoverage.ProfileSHA256
foreach($bad in @('C:/Users/private/file.go:1.1,1.2 10 1','windows_setup/script/test/../private.go:1.1,1.2 10 1','https://example.invalid/private.go:1.1,1.2 10 1','<script>alert(1)</script>','windows_setup/script/test/example/value.go:1.1,1.2 10 1','windows_setup/script/test/other/value.go:1.1,1.2 10 1','windows_setup/script/test/example/value_test.go:1.1,1.2 10 1','windows_setup/script/test/example/value.go:1.1,1.2 0 1',"windows_setup/script/test/example/value.go:1.1,1.2 10 1`nwindows_setup/script/test/example/value.go:1.1,1.2 10 1")){
 $badText="mode: set`n$bad`n";[IO.File]::WriteAllText($rawPath,$badText,$utf8)
 $badCoverage=$report.GoCoverage|ConvertTo-Json -Depth 8|ConvertFrom-Json;$badCoverage.ProfileSHA256=(Get-FileHash $rawPath).Hash.ToLowerInvariant()
 Refuse {Assert-GoCoverageProfile -Coverage $badCoverage -Directory $current.AssetDirectory} '即使hash同步也拒絕私人路徑、注入或與真量測計數矛盾的profile'
}
[IO.File]::WriteAllText($rawPath,$original,$utf8)
$profileItem=$current.AssetDigests|Where-Object Name -eq 'go_coverage.out';$saveDigest=$profileItem.Digest;$profileItem.Digest='sha256:'+('0'*64)
Refuse {Test-PortalReleaseEvidence -Entry $current -CoverageToolPath $tool} 'manifest與GitHub原始profile digest不一致必須拒絕';$profileItem.Digest=$saveDigest
$mf=Get-Content $current.ManifestPath -Raw -Encoding UTF8|ConvertFrom-Json;$savedFiles=$mf.Files;$mf.Files+=@($mf.Files|Where-Object Name -eq 'go_coverage.out')
[IO.File]::WriteAllText($current.ManifestPath,($mf|ConvertTo-Json -Depth 10),$utf8);$current.ManifestDigest='sha256:'+(Get-FileHash $current.ManifestPath).Hash.ToLowerInvariant()
Refuse {Test-PortalReleaseEvidence -Entry $current -CoverageToolPath $tool} '重複原始profile的manifest不能通過'
$mf.Files=$savedFiles|Where-Object Name -ne 'go_coverage.out';[IO.File]::WriteAllText($current.ManifestPath,($mf|ConvertTo-Json -Depth 10),$utf8);$current.ManifestDigest='sha256:'+(Get-FileHash $current.ManifestPath).Hash.ToLowerInvariant()
Refuse {Test-PortalReleaseEvidence -Entry $current -CoverageToolPath $tool} 'GitHub存在未聲明profile附件不能偽裝legacy'
foreach($schema in @(1,2)){
 $legacy=$report|ConvertTo-Json -Depth 20|ConvertFrom-Json;$legacy.SchemaVersion=$schema;$legacy.Version='v1.0.'+$schema;$legacy.RefName=$legacy.Version
 if($schema -eq 1){$legacy.PSObject.Properties.Remove('RepoCoverage');$legacy.Coverage='NotMeasured';$legacy|Add-Member ComparisonStatus Unknown;$legacy|Add-Member FlakyStatus Unknown}
 $entry=New-GoVersionEvidence -Directory (Join-Path $versionFixture ('legacy'+$schema)) -Snapshot $legacy
 $legacyVerified=Test-PortalReleaseEvidence -Entry $entry -CoverageToolPath $tool
 Assert (-not $legacyVerified.HasGoProfile) ('歷史manifest不必追補不可變附件：schema'+$schema)
 $legacyCat=Join-Path $versionFixture ('legacy'+$schema+'.json');[IO.File]::WriteAllText($legacyCat,(ConvertTo-Json -InputObject @($entry) -Depth 10),$utf8)
 $legacyOut=Join-Path $versionFixture ('legacy_portal'+$schema)
 & (Join-Path $root 'script/report/build_portal.ps1') -Preview -CatalogPath $legacyCat -OutputDirectory $legacyOut -CoverageToolPath $tool|Out-Null
 $legacyHtml=[IO.File]::ReadAllText((Join-Path $legacyOut ('versions/'+$legacy.Version+'/index.html')))
 Assert (-not $legacyHtml.Contains('href="go_coverage.out"') -and $legacyHtml.Contains('href="go_coverage.json"') -and $legacyHtml.Contains('80.0%')) ('歷史頁保留真Go量測但不生成未保存profile的死連結：schema'+$schema)
}
$global:repoPublicationRemoteCalled=$false
function gh {$global:repoPublicationRemoteCalled=$true;throw 'unexpected remote call'}
$profile=Join-Path $public 'go_coverage.out';$savedProfile=[IO.File]::ReadAllText($profile);Remove-Item -LiteralPath $profile
Assert ((Get-Command gh).CommandType -eq 'Function') '缺 profile 負例必須使用 mock gh'
Refuse {& (Join-Path $root 'script/report/publish_quality_release.ps1') -PublicDirectory $public -Version v1.0.0 -Commit $identity.Commit -NotesPath (Join-Path $public 'summary.md') -Repository example/repo -CoverageToolPath $tool} '現版publisher拒絕缺profile的legacy口徑'
Assert (-not $global:repoPublicationRemoteCalled) '缺profile在任何遠端操作前停止'
[IO.File]::WriteAllText($profile,$savedProfile,$utf8)
Remove-Item Function:\gh
$noGo=Join-Path $versionFixture 'current_without_go';New-Item -ItemType Directory $noGo|Out-Null
foreach($name in @('repo_coverage.json','coverage_inventory.json','coverage.xml')){Copy-Item -LiteralPath (Join-Path $public $name) -Destination $noGo}
$noGoReport=$report|ConvertTo-Json -Depth 20|ConvertFrom-Json;$noGoReport.PSObject.Properties.Remove('GoCoverage');Write-SnapshotView $noGoReport $noGo
$global:repoPublicationRemoteCalled=$false
function gh {$global:repoPublicationRemoteCalled=$true;throw 'unexpected remote call'}
Assert ((Get-Command gh).CommandType -eq 'Function') '缺 Go 負例必須使用 mock gh'
Refuse {& (Join-Path $root 'script/report/publish_quality_release.ps1') -PublicDirectory $noGo -Version v1.0.0 -Commit $identity.Commit -NotesPath (Join-Path $noGo 'summary.md') -Repository example/repo -CoverageToolPath $tool} '現版publisher不得將無Go的legacy口徑當成runtime'
Assert (-not $global:repoPublicationRemoteCalled) 'legacy來源量測在任何遠端操作前停止'
Remove-Item Function:\gh
$lowGoDirectory=Join-Path $versionFixture 'low_go';New-Item -ItemType Directory $lowGoDirectory|Out-Null
$lowGoProfile="mode: set`nwindows_setup/script/test/example/value.go:1.1,1.2 7 1`nwindows_setup/script/test/example/value.go:2.1,2.2 3 0`n"
[IO.File]::WriteAllText((Join-Path $lowGoDirectory 'go_coverage.out'),$lowGoProfile,$utf8)
$lowGoReport=$report|ConvertTo-Json -Depth 20|ConvertFrom-Json;$lowGoReport.GoCoverage.Covered=7;$lowGoReport.GoCoverage.Percent=70;$lowGoReport.GoCoverage.ProfileSHA256=(Get-FileHash (Join-Path $lowGoDirectory 'go_coverage.out')).Hash.ToLowerInvariant()
Assert-GoCoverageProfile -Coverage $lowGoReport.GoCoverage -Directory $lowGoDirectory
Assert $true '原始profile讀取保留低於八成的真量測，發布政策另行執行'
foreach($name in @('repo_coverage.json','coverage_inventory.json','coverage.xml')){Copy-Item -LiteralPath (Join-Path $public $name) -Destination $lowGoDirectory}
Write-SnapshotView $lowGoReport $lowGoDirectory
$global:repoPublicationRemoteCalled=$false
function gh {$global:repoPublicationRemoteCalled=$true;throw 'unexpected remote call'}
$lowRefused=$false
Assert ((Get-Command gh).CommandType -eq 'Function') '低覆蓋率負例必須使用 mock gh'
try{& (Join-Path $root 'script/report/publish_quality_release.ps1') -PublicDirectory $lowGoDirectory -Version v1.0.0 -Commit $identity.Commit -NotesPath (Join-Path $lowGoDirectory 'summary.md') -Repository example/repo -CoverageToolPath $tool}catch{$lowRefused=$_.Exception.Message -like '*舊口徑僅供歷史讀取*'}
Assert ($lowRefused -and -not $global:repoPublicationRemoteCalled) '低Go歷史口徑保留可讀但不能作為新runtime發布'
Remove-Item Function:\gh
