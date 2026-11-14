#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'script/test/test_report.ps1')
function Assert([bool]$Condition,[string]$Message){Write-Host ('@@ASSERT@@'+(@{Name=$Message;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Message}}
function Refuse([scriptblock]$Action,[string]$Message){$caught=$false;try{& $Action|Out-Null}catch{$caught=$true};Assert $caught $Message}
$fixture=Join-Path $env:TEMP ('complete_publication_'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $fixture|Out-Null
$tool=Join-Path $fixture 'repo_coverage_tool.exe'
Push-Location $root
try{& go.exe build -mod=vendor -o $tool ./script/test/repo_coverage_tool;if($LASTEXITCODE -ne 0){throw 'coverage CLI build failed'}}finally{Pop-Location}
$checks=@(foreach($layer in @('Unit','Integration')){[pscustomobject]@{Name=$layer;Layer=$layer;Status='Passed';Executed=$true;Passed=$true;ExitCode=0;DurationSeconds=1;Assertions=@([pscustomobject]@{Name='real assertion';Passed=$true})}})
$identity=@{Commit=('a'*40);RunUrl='https://github.com/example/repo/actions/runs/1';MeasuredAt='2026-11-08T00:00:00Z';SourceState='Clean'}
$public=Join-Path $fixture 'public';Write-TestReports -Checks $checks -OutputDirectory $public @identity -RefName main -Environment 'Windows synthetic native'|Out-Null
$evidence=Join-Path $fixture 'evidence';New-Item -ItemType Directory $evidence|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
$inventory=[ordered]@{Sources=@([ordered]@{Path='core/example.ps1';Language='powershell';SHA256=('b'*64);ExpectedLines=@(1,2,3,4,5)});Excluded=$null;Blockers=$null}
[IO.File]::WriteAllText((Join-Path $evidence 'coverage_inventory.json'),($inventory|ConvertTo-Json -Depth 8),$utf8)
$xml='<coverage coverage-schema="1" coverage-metric="complete-executable-lines-v1"><packages><package><classes><class filename="core/example.ps1"><lines><line number="1" hits="1"/><line number="2" hits="1"/><line number="3" hits="1"/><line number="4" hits="1"/><line number="5" hits="0"/></lines></class></classes></package></packages></coverage>'
[IO.File]::WriteAllText((Join-Path $evidence 'coverage.xml'),$xml,$utf8)
$c=[ordered]@{SchemaVersion=2;Metric='runtime-powershell-csharp-executable-lines-v2';Scope='core-modules-powershell-and-modules-native-csharp';Commit=$identity.Commit;RunUrl=$identity.RunUrl;MeasuredAt=$identity.MeasuredAt;SourceState='Clean';InventorySHA256=(Get-FileHash (Join-Path $evidence 'coverage_inventory.json')).Hash.ToLowerInvariant();NormalizedSHA256=(Get-FileHash (Join-Path $evidence 'coverage.xml')).Hash.ToLowerInvariant();Result=[ordered]@{SchemaVersion=1;Metric='complete-executable-lines-v1';Complete=$true;Covered=4;Executable=5;Percent=80.0;Missing=$null;Blockers=$null;Languages=@{powershell=@{Covered=4;Executable=5}}}}
[IO.File]::WriteAllText((Join-Path $evidence 'repo_coverage.json'),($c|ConvertTo-Json -Depth 8),$utf8)
& (Join-Path $root 'script/test/attach_repo_coverage.ps1') -PublicDirectory $public -CoverageDirectory $evidence -CoverageToolPath $tool
$report=Get-Content (Join-Path $public 'summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert ($report.Coverage -ceq 'Measured' -and $report.RepoCoverage.SchemaVersion -eq 2 -and $report.RepoCoverage.Scope -ceq 'core-modules-powershell-and-modules-native-csharp' -and $report.RepoCoverage.Result.Percent -eq 80) '真CLI重算後附加完整runtime覆蓋率'
foreach($name in @('repo_coverage.json','coverage_inventory.json','coverage.xml')){Assert ((Get-FileHash (Join-Path $public $name)).Hash -eq (Get-FileHash (Join-Path $evidence $name)).Hash) ('永久證據逐位元保存：'+$name)}
$catalog=Join-Path $fixture 'catalog.json';[IO.File]::WriteAllText($catalog,'[]')
$portalContainer=Join-Path $fixture 'portal_container'
Write-TestReports -Checks $checks -OutputDirectory $portalContainer @identity -RefName main -Environment 'Windows container / Windows synthetic'|Out-Null
$bundleTool=Join-Path $fixture 'report_bundle_tool.exe'
Push-Location $root
try{& go.exe build -mod=vendor -o $bundleTool ./script/test/report_bundle_tool;if($LASTEXITCODE -ne 0){throw 'bundle CLI build failed'}}finally{Pop-Location}
$portal=Join-Path $fixture 'portal'
& (Join-Path $root 'script/report/build_portal.ps1') -CatalogPath $catalog -OutputDirectory $portal -MainSnapshotPath (Join-Path $public 'summary.json') -CoverageToolPath $tool -ContainerSnapshotPath (Join-Path $portalContainer 'summary.json') -BundleToolPath $bundleTool|Out-Null
$landingPage=[IO.File]::ReadAllText((Join-Path $portal 'index.html'))
Assert ($landingPage.Contains('PowerShell/C# runtime 覆蓋率') -and $landingPage.Contains('80.0%') -and $landingPage.Contains('4/5 可執行行')) 'Pages首頁顯示runtime共同計量'
foreach($name in @('repo_coverage.json','coverage_inventory.json','coverage.xml')){Assert ((Get-FileHash (Join-Path $portal ('main/'+$name))).Hash -eq (Get-FileHash (Join-Path $evidence $name)).Hash) ('Pages保留可重算證據：'+$name)}
$missing=Join-Path $fixture 'missing';Write-TestReports -Checks $checks -OutputDirectory $missing @identity -RefName main|Out-Null
Refuse {& (Join-Path $root 'script/report/build_portal.ps1') -CatalogPath $catalog -OutputDirectory (Join-Path $fixture 'missing_portal') -MainSnapshotPath (Join-Path $missing 'summary.json') -ContainerSnapshotPath (Join-Path $portalContainer 'summary.json') -BundleToolPath $bundleTool -CoverageToolPath $tool} '正式Pages缺整體量測必須拒絕'
$legacyDirectory=Join-Path $fixture 'legacy_publish'
Write-TestReports -Checks $checks -OutputDirectory $legacyDirectory @identity -SchemaVersion 1 -Version v1.0.0 -RefType Release -RefName v1.0.0 -Environment 'Synthetic historical fixture'|Out-Null
$global:repoPublicationRemoteCalled=$false
function gh {$global:repoPublicationRemoteCalled=$true;$global:LASTEXITCODE=1;throw 'unexpected remote operation'}
Assert ((Get-Command gh).CommandType -eq 'Function') '歷史發布負例必須使用 mock gh'
Refuse {& (Join-Path $root 'script/report/publish_quality_release.ps1') -PublicDirectory $legacyDirectory -Version v1.0.0 -Commit $identity.Commit -NotesPath (Join-Path $legacyDirectory 'summary.md') -Repository example/repo} '本輪publisher不得降級legacy契約'
Assert (-not $global:repoPublicationRemoteCalled) 'legacy只能讀歷史，發布前禁止遠端操作'
Remove-Item Function:\gh
$report.RefType='Release';$report.RefName='v1.0.0';$report.Version='v1.0.0';$report.Environment='Synthetic publication fixture'
. (Join-Path $root 'script/report/portal.ps1')
Write-SnapshotView $report $public
$archive=Join-Path $fixture 'windows_setup_report_v1.0.0.zip'
[IO.File]::WriteAllText($archive,'mock report archive')
$containerFixture=Join-Path $fixture 'container';New-Item -ItemType Directory $containerFixture|Out-Null
foreach($name in @('index.html','summary.json','summary.md','junit.xml','unit.svg','integration.svg','coverage.svg')){Copy-Item (Join-Path $public $name) -Destination (Join-Path $containerFixture $name)}
function Test-FixtureBundleVerifier {
 $words=@($args)
 $valid=$words[0] -ceq 'verify' -and $words[[Array]::IndexOf($words,'--archive')+1] -ceq $archive -and $words[[Array]::IndexOf($words,'--version')+1] -ceq 'v1.0.0' -and $words[[Array]::IndexOf($words,'--commit')+1] -ceq $identity.Commit -and $words[[Array]::IndexOf($words,'--run-url')+1] -ceq $identity.RunUrl -and $words[[Array]::IndexOf($words,'--run-attempt')+1] -eq 1
 if($words -contains '--output-dir'){
  $dest=$words[[Array]::IndexOf($words,'--output-dir')+1];$global:fixturePrivateParent=Split-Path -Parent $dest
  Assert ((Test-Path -LiteralPath $global:fixturePrivateParent -PathType Container) -and @(Get-ChildItem -LiteralPath $global:fixturePrivateParent -Force).Count -eq 0 -and -not (Test-Path -LiteralPath $dest)) '驗證輸出使用自建空白 parent 與尚不存在的 child'
  New-Item -ItemType Directory (Join-Path $dest 'native'),(Join-Path $dest 'windows_container') -Force|Out-Null
  foreach($name in @('index.html','summary.json','summary.md','junit.xml','unit.svg','integration.svg','coverage.svg','repo_coverage.json','coverage_inventory.json','coverage.xml')){Copy-Item (Join-Path $public $name) -Destination (Join-Path $dest ('native/'+$name))}
  foreach($name in @('index.html','summary.json','summary.md','junit.xml','unit.svg','integration.svg','coverage.svg')){Copy-Item (Join-Path $containerFixture $name) -Destination (Join-Path $dest ('windows_container/'+$name))}
  if($global:fixtureBundleMismatch){[IO.File]::AppendAllText((Join-Path $dest 'native/summary.md'),'different validated report')}
  if($global:fixtureBundleReparse){New-Item -ItemType Junction -Path (Join-Path $dest 'foreign') -Target $global:fixtureProtectedDirectory -ErrorAction Stop|Out-Null}
  $digest=if($global:fixtureBundleReceiptMismatch){'f'*64}else{(Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant()}
  @{context_origin='explicit';archive_sha256=$digest;archive_size=(Get-Item -LiteralPath $archive).Length;version='v1.0.0';commit=$identity.Commit;run_url=$identity.RunUrl;run_attempt=1;summary_sha256=(Get-FileHash -LiteralPath (Join-Path $dest 'native/summary.json')).Hash.ToLowerInvariant();coverage_scope='core-modules-powershell-and-modules-native-csharp'}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $dest 'verified.json') -Encoding UTF8
 }
 $global:LASTEXITCODE=if($global:fixtureBundleFailure -or -not $valid){1}else{0}
}
function gh {
 $words=@($args);$global:LASTEXITCODE=0
 if($words[0] -eq 'api' -and $words -contains '--paginate'){
  if(($words -join ' ') -match '@json' -and $global:repoPublicationCreated){return (@{id=42;tag_name='v1.0.0';draft=$true;immutable=$false}|ConvertTo-Json -Compress)}
  return
 }
 if($words[0] -eq 'release' -and $words[1] -eq 'create'){
  $global:repoPublicationTitle=$words[[Array]::IndexOf($words,'--title')+1]
  $global:repoPublicationDraft=$words -contains '--draft'
  $global:repoPublicationCreated++
  $global:repoPublicationBody=[IO.File]::ReadAllText((Join-Path $public 'summary.md'))
  $global:repoPublicationAssets=@($words|Where-Object {Test-Path -LiteralPath ([string]$_) -PathType Leaf}|Where-Object {[IO.Path]::GetExtension($_) -eq '.zip'}|Select-Object -Unique|ForEach-Object {@{name=[IO.Path]::GetFileName($_);size=(Get-Item -LiteralPath $_).Length;digest=('sha256:'+(Get-FileHash -LiteralPath $_).Hash.ToLowerInvariant())}})
  return
 }
 if($words[0] -eq 'api' -and $words[1] -eq 'repos/example/repo/releases/42' -and $words -notcontains '--method'){
  if($global:repoPublicationMode -eq 'bad-digest'){$global:repoPublicationAssets[0].digest='sha256:'+('0'*64)}
  $json=@{id=42;immutable=$false;draft=$true;prerelease=$false;tag_name='v1.0.0';name='v1.0.0';target_commitish=$identity.Commit;body=$global:repoPublicationBody;assets=$global:repoPublicationAssets}|ConvertTo-Json -Depth 8 -Compress
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
 }
 if($words[0] -eq 'api' -and $words[1] -eq 'repos/example/repo/releases/42' -and $words -contains '--method'){
  $inputPath=$words[[Array]::IndexOf($words,'--input')+1];$bytes=[IO.File]::ReadAllBytes($inputPath)
  Assert (-not($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'ID PATCH 使用無 BOM UTF8 JSON'
  $payload=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)|ConvertFrom-Json
  Assert ($words[[Array]::IndexOf($words,'--method')+1] -ceq 'PATCH') '只對已選中的 release ID PATCH'
  Assert ($payload.tag_name -is [string] -and $payload.tag_name -ceq 'v1.0.0' -and $payload.target_commitish -is [string] -and $payload.target_commitish -ceq $identity.Commit -and $payload.name -is [string] -and $payload.name -ceq 'v1.0.0' -and $payload.prerelease -is [bool] -and $payload.prerelease -ceq $false -and $payload.draft -is [bool]) '每次固定 ID PATCH 明確保留標籤、來源、名稱與布林狀態'
  if(-not $payload.draft){
   Assert ($payload.draft -is [bool] -and $payload.draft -ceq $false -and $global:repoPublicationNotesApplied) '完整核對後最後一步才以 JSON false 發布'
   $global:repoPublicationPublished++
  }else{
   Assert ($payload.name -ceq 'v1.0.0' -and $payload.body -ceq [IO.File]::ReadAllText((Join-Path $public 'summary.md'))) '中文 notes 以原字串寫入固定 ID'
   $global:repoPublicationBody=$payload.body;$global:repoPublicationNotesApplied=$true
  }
  return '{}'
 }
 if($words[0] -eq 'api' -and $words[1] -like '*/releases/tags/*'){
  $assets=if($global:repoPublicationMode -eq 'missing-asset'){@($global:repoPublicationAssets|Select-Object -Skip 1)}else{$global:repoPublicationAssets}
  if(-not $global:repoPublicationPublished){$global:LASTEXITCODE=1;return}
  return (@{id=42;immutable=$(if($global:repoPublicationMode -eq 'string-immutable'){'true'}else{$global:repoPublicationMode -ne 'mutable'});draft=$false;tag_name='v1.0.0';assets=$assets;html_url='https://github.com/example/repo/releases/tag/v1.0.0'}|ConvertTo-Json -Depth 5)
 }
 if($words[0] -eq 'api' -and $words[1] -like '*/commits/*'){return $(if($global:repoPublicationMode -eq 'wrong-sha'){'c'*40}else{'a'*40})}
 throw ('Unexpected mock call: '+($words -join ' '))
}
foreach($mode in @('success','bad-digest','missing-asset','mutable','string-immutable','wrong-sha')){
 $global:repoPublicationMode=$mode;$global:repoPublicationPublished=0;$global:repoPublicationCreated=0;$global:repoPublicationNotesApplied=$false;$global:repoPublicationAssets=@()
 Assert ((Get-Command gh).CommandType -eq 'Function') '發布測試必須使用 mock gh'
 $accepted=$true;try{& (Join-Path $root 'script/report/publish_quality_release.ps1') -PublicDirectory $public -ContainerDirectory $containerFixture -Version v1.0.0 -Commit $identity.Commit -NotesPath (Join-Path $public 'summary.md') -Repository example/repo -CoverageToolPath $tool -ReportArchive $archive -BundleToolPath Test-FixtureBundleVerifier -RunAttempt 1 -RunUrl $identity.RunUrl|Out-Null}catch{$accepted=$false;Write-Host ('Fixture publication error: '+$_.Exception.Message)}
 Assert (-not (Test-Path -LiteralPath $global:fixturePrivateParent)) ('驗證完成只清理自建目錄 '+$mode)
 Assert ($accepted -eq ($mode -eq 'success')) ('Schema2只發布真完整不可變證據：'+$mode)
 Assert ($global:repoPublicationCreated -eq $(if($mode -eq 'wrong-sha'){0}else{1})) ('來源在建立草稿前核對：'+$mode)
 if($mode -ne 'wrong-sha'){Assert ($global:repoPublicationTitle -ceq 'v1.0.0' -and $global:repoPublicationDraft) ('版本標題及草稿先行：'+$mode)}
 Assert ($global:repoPublicationAssets.Count -eq $(if($mode -eq 'wrong-sha'){0}else{1})) ('新 Release 只含一個完整報表 ZIP：'+$mode)
 Assert ($global:repoPublicationPublished -eq $(if($mode -in @('bad-digest','wrong-sha')){0}else{1})) ('草稿驗證失敗不得提前發布：'+$mode)
}
$global:fixtureProtectedDirectory=Join-Path $fixture 'protected';New-Item -ItemType Directory -Path $global:fixtureProtectedDirectory|Out-Null
[IO.File]::WriteAllText((Join-Path $global:fixtureProtectedDirectory 'sentinel.txt'),'preserve')
foreach($invalid in @('missing-archive','bad-run','bad-attempt','wrong-attempt','verify-failed','different-input','reparse-output','different-archive')){
 $global:repoPublicationMode='success';$global:repoPublicationCreated=0;$global:repoPublicationPublished=0;$global:fixtureBundleFailure=($invalid -eq 'verify-failed');$global:fixtureBundleMismatch=($invalid -eq 'different-input');$global:fixtureBundleReparse=($invalid -eq 'reparse-output');$global:fixtureBundleReceiptMismatch=($invalid -eq 'different-archive')
 $argsForPublisher=@{PublicDirectory=$public;ContainerDirectory=$containerFixture;Version='v1.0.0';Commit=$identity.Commit;NotesPath=(Join-Path $public 'summary.md');Repository='example/repo';CoverageToolPath=$tool;ReportArchive=$archive;BundleToolPath='Test-FixtureBundleVerifier';RunAttempt=1;RunUrl=$identity.RunUrl}
 if($invalid -eq 'missing-archive'){$argsForPublisher.ReportArchive=Join-Path $fixture 'missing/windows_setup_report_v1.0.0.zip'}
 if($invalid -eq 'bad-run'){$argsForPublisher.RunUrl='https://github.com/example/repo/actions/runs/2'}
 if($invalid -eq 'bad-attempt'){$argsForPublisher.RunAttempt=0}
 if($invalid -eq 'wrong-attempt'){$argsForPublisher.RunAttempt=2}
 Assert ((Get-Command gh).CommandType -eq 'Function') '失敗案例必須使用 mock gh'
 Refuse {& (Join-Path $root 'script/report/publish_quality_release.ps1') @argsForPublisher} ('報表驗證失敗拒絕發布 '+$invalid)
 Assert ($global:repoPublicationCreated -eq 0 -and $global:repoPublicationPublished -eq 0) ('報表驗證失敗沒有建立或發布 '+$invalid)
 if($invalid -eq 'reparse-output'){Assert ((Test-Path -LiteralPath (Join-Path $global:fixtureProtectedDirectory 'sentinel.txt') -PathType Leaf) -and (Test-Path -LiteralPath $global:fixturePrivateParent -PathType Container)) '清理遇重新解析點時保留自建目錄及外部內容'}
}
$global:fixtureBundleFailure=$false;$global:fixtureBundleMismatch=$false;$global:fixtureBundleReparse=$false;$global:fixtureBundleReceiptMismatch=$false
Remove-Item Function:\gh
function New-LocalEntry {
 $manifestPath=Join-Path $public 'quality-manifest.json'
 $manifest=Get-Content $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
 foreach($file in $manifest.Files){$file.SHA256=(Get-FileHash (Join-Path $public $file.Name)).Hash.ToLowerInvariant()}
 [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 10),$utf8)
 [pscustomobject]@{Version='v1.0.0';Commit=$identity.Commit;ReleaseUrl='https://github.com/example/repo/releases/tag/v1.0.0';Immutable=$true;SnapshotPath=(Join-Path $public 'quality.json');ManifestPath=$manifestPath;SnapshotDigest=('sha256:'+(Get-FileHash (Join-Path $public 'quality.json')).Hash.ToLowerInvariant());ManifestDigest=('sha256:'+(Get-FileHash $manifestPath).Hash.ToLowerInvariant());AssetDirectory=$public;AssetDigests=@(Get-ChildItem $public -File|ForEach-Object {[pscustomobject]@{Name=$_.Name;Digest=('sha256:'+(Get-FileHash $_.FullName).Hash.ToLowerInvariant())}})}
}
$entry=New-LocalEntry
$verified=Test-PortalReleaseEvidence -Entry $entry -CoverageToolPath $tool
Assert ($verified.Snapshot.RepoCoverage.SchemaVersion -eq 2 -and $verified.Snapshot.RepoCoverage.Result.Percent -eq 80) 'manifest2合成新版來源同樣重算runtime量測'
$xmlOriginal=[IO.File]::ReadAllText((Join-Path $public 'coverage.xml'))
[IO.File]::AppendAllText((Join-Path $public 'coverage.xml'),' ')
$forged=New-LocalEntry
Refuse {Test-PortalReleaseEvidence -Entry $forged -CoverageToolPath $tool} '即使外層digest重簽仍拒絕與coverage內層hash不同的附件'
[IO.File]::WriteAllText((Join-Path $public 'coverage.xml'),$xmlOriginal,$utf8)
$entry=New-LocalEntry
$global:repoDownloadSource=$public
$global:repoDownloadRelease=[pscustomobject]@{draft=$false;tag_name='v1.0.0';immutable=$true;html_url=$entry.ReleaseUrl;assets=@($entry.AssetDigests|ForEach-Object {@{name=$_.Name;digest=$_.Digest}})}
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
 throw ('Unexpected download call: '+($words -join ' '))
}
$inputs=& (Join-Path $root 'script/report/get_portal_inputs.ps1') -Repository example/repo -OutputDirectory (Join-Path $fixture 'download')
$downloaded=@(Get-Content $inputs.CatalogPath -Raw -Encoding UTF8|ConvertFrom-Json)[0]
foreach($name in @('repo_coverage.json','coverage_inventory.json','coverage.xml')){Assert (Test-Path -LiteralPath (Join-Path $downloaded.AssetDirectory $name)) ('實際Release匯入完整覆蓋率附件：'+$name)}
$null=Test-PortalReleaseEvidence -Entry $downloaded -CoverageToolPath $tool
Remove-Item Function:\gh
Refuse {& (Join-Path $root 'script/test/attach_repo_coverage.ps1') -PublicDirectory $public -CoverageDirectory $evidence -CoverageToolPath (Join-Path $fixture 'missing_cli.exe')} '缺少驗證CLI不得略過門檻'
$lowDirectory=Join-Path $fixture 'below_threshold';New-Item -ItemType Directory $lowDirectory|Out-Null
Copy-Item -LiteralPath (Join-Path $evidence 'coverage_inventory.json') -Destination $lowDirectory
$lowXml=([regex]'hits="1"').Replace($xml,'hits="0"',1)
[IO.File]::WriteAllText((Join-Path $lowDirectory 'coverage.xml'),$lowXml,$utf8)
$lowCoverage=Get-Content (Join-Path $evidence 'repo_coverage.json') -Raw -Encoding UTF8|ConvertFrom-Json
$lowCoverage.Result.Covered=3;$lowCoverage.Result.Percent=60;$lowCoverage.Result.Languages.powershell.Covered=3
$lowCoverage.NormalizedSHA256=(Get-FileHash (Join-Path $lowDirectory 'coverage.xml')).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $lowDirectory 'repo_coverage.json'),($lowCoverage|ConvertTo-Json -Depth 10),$utf8)
Refuse {& (Join-Path $root 'script/test/attach_repo_coverage.ps1') -PublicDirectory $public -CoverageDirectory $lowDirectory -CoverageToolPath $tool} '完整但低於八成的真證據不得附加發布'
$lowReport=$report|ConvertTo-Json -Depth 20|ConvertFrom-Json;$lowReport.RepoCoverage=$lowCoverage;$lowReport.RefType='Branch';$lowReport.RefName='main'
Write-SnapshotView $lowReport $lowDirectory
Refuse {& (Join-Path $root 'script/report/build_portal.ps1') -CatalogPath $catalog -OutputDirectory (Join-Path $fixture 'low_portal') -MainSnapshotPath (Join-Path $lowDirectory 'summary.json') -ContainerSnapshotPath (Join-Path $portalContainer 'summary.json') -BundleToolPath $bundleTool -CoverageToolPath $tool} '正式Pages逐行重算拒絕低於八成'
$lowReport.RefType='Release';$lowReport.RefName='v1.0.0';Write-SnapshotView $lowReport $lowDirectory
$global:repoPublicationRemoteCalled=$false
function gh {$global:repoPublicationRemoteCalled=$true;throw 'unexpected remote call'}
Assert ((Get-Command gh).CommandType -eq 'Function') '覆蓋率負例必須使用 mock gh'
Refuse {& (Join-Path $root 'script/report/publish_quality_release.ps1') -PublicDirectory $lowDirectory -Version v1.0.0 -Commit $identity.Commit -NotesPath (Join-Path $lowDirectory 'summary.md') -Repository example/repo -CoverageToolPath $tool} '新版publisher拒絕完整但低於八成'
Assert (-not $global:repoPublicationRemoteCalled) '八成門檻失敗在任何遠端操作前停止'
Remove-Item Function:\gh
$before=(Get-FileHash (Join-Path $public 'summary.json')).Hash
[IO.File]::AppendAllText((Join-Path $evidence 'coverage.xml'),'tampered')
Refuse {& (Join-Path $root 'script/test/attach_repo_coverage.ps1') -PublicDirectory $public -CoverageDirectory $evidence -CoverageToolPath $tool} '篡改逐行證據不得附加'
Assert ((Get-FileHash (Join-Path $public 'summary.json')).Hash -eq $before) '驗證失敗不改原始報告'
