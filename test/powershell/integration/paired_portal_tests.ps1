#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'script/test/test_report.ps1')
. (Join-Path $root 'test/powershell/helpers/report_bundle_fixture.ps1')
$parent=Join-Path $env:TEMP ('issue201_paired_portal_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($parent)
$fixture=New-TestReportBundleFixture -RepositoryRoot $root -Destination (Join-Path $parent 'fixture') -Runtime
$nativeSource=Join-Path $fixture.Root 'windows-test-reports-1-1';$containerSource=Join-Path $fixture.Root 'docker-test-reports-1-1'
$native=Get-Content -LiteralPath (Join-Path $nativeSource 'summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
$container=Get-Content -LiteralPath (Join-Path $containerSource 'summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
$nativeDir=Join-Path $parent 'native';$containerDir=Join-Path $parent 'container'
foreach($pair in @(@($native,$nativeDir),@($container,$containerDir))){$r=$pair[0];$args=@{Checks=@($r.Checks);OutputDirectory=$pair[1];Layer='All';Commit=$r.Commit;RunUrl=$r.RunUrl;SourceState='Clean';Version=$r.Version;Environment=$r.Environment;RefType='Branch';RefName='main';MeasuredAt=$r.MeasuredAt;Changes=$r.Changes};if($r.PSObject.Properties['RepoCoverage']){$args.RepoCoverage=$r.RepoCoverage};Write-TestReports @args|Out-Null}
foreach($name in @('repo_coverage.json','coverage_inventory.json','coverage.xml')){Copy-Item -LiteralPath (Join-Path $nativeSource $name) -Destination (Join-Path $nativeDir $name)}
$catalog=Join-Path $parent 'catalog.json';[IO.File]::WriteAllText($catalog,'[]')
$out=Join-Path $parent 'portal'
& (Join-Path $root 'script/report/build_portal.ps1') -CatalogPath $catalog -OutputDirectory $out -MainSnapshotPath (Join-Path $nativeDir 'summary.json') -ContainerSnapshotPath (Join-Path $containerDir 'summary.json') -CoverageToolPath $fixture.CoverageTool -BundleToolPath $fixture.BundleTool|Out-Null
$oldPortal=$env:WINDOWS_SETUP_PORTAL_FIXTURE_DIR
Push-Location -LiteralPath $root
try{$env:WINDOWS_SETUP_PORTAL_FIXTURE_DIR=$out;& go.exe test -count=1 -mod=vendor ./test/go/integration -run '^TestActualPortalFixturePassesAcceptance$';if($LASTEXITCODE -ne 0){throw '實際產出未通過現有 Pages 驗收器。'}}finally{$env:WINDOWS_SETUP_PORTAL_FIXTURE_DIR=$oldPortal;Pop-Location}
$html=[IO.File]::ReadAllText((Join-Path $out 'index.html'))
foreach($text in @('Windows 原生','Windows 容器','native/index.html','windows_container/index.html','容器未量測')){if(-not $html.Contains($text)){throw ('missing '+$text)}}
foreach($relative in @('native/summary.json','native/junit.xml','windows_container/summary.json','windows_container/junit.xml')){if(-not(Test-Path -LiteralPath (Join-Path $out $relative))){throw ('missing '+$relative)}}
Write-Host '@@ASSERT@@{"Name":"正式 Pages 驗證並呈現同次雙環境及證據","Passed":true}'

$missingRejected=$false
try {& (Join-Path $root 'script/report/build_portal.ps1') -CatalogPath $catalog -OutputDirectory (Join-Path $parent 'missing') -MainSnapshotPath (Join-Path $nativeDir 'summary.json') -CoverageToolPath $fixture.CoverageTool -BundleToolPath $fixture.BundleTool|Out-Null}catch{$missingRejected=$true}
if(-not $missingRejected){throw '缺少容器報告仍接受'}
$badDir=Join-Path $parent 'badcontainer';Copy-Item -LiteralPath $containerDir -Destination $badDir -Recurse
$bad=Get-Content -LiteralPath (Join-Path $badDir 'summary.json') -Raw -Encoding UTF8|ConvertFrom-Json;$bad.RunUrl='https://github.com/example/windows_setup/actions/runs/999';[IO.File]::WriteAllText((Join-Path $badDir 'summary.json'),($bad|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
$badRejected=$false
try {& (Join-Path $root 'script/report/build_portal.ps1') -CatalogPath $catalog -OutputDirectory (Join-Path $parent 'wrongrun') -MainSnapshotPath (Join-Path $nativeDir 'summary.json') -ContainerSnapshotPath (Join-Path $badDir 'summary.json') -CoverageToolPath $fixture.CoverageTool -BundleToolPath $fixture.BundleTool|Out-Null}catch{$badRejected=$true}
if(-not $badRejected){throw '不同 run 仍接受'}
Write-Host '@@ASSERT@@{"Name":"缺少容器及不同執行均拒絕","Passed":true}'