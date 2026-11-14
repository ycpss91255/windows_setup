#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'test/powershell/helpers/report_bundle_fixture.ps1')
$parent=Join-Path ([IO.Path]::GetTempPath()) ('publish_runtime_fixture_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($parent)
$fixture=New-TestReportBundleFixture -RepositoryRoot $root -Destination (Join-Path $parent 'fixture') -Runtime
$f=$fixture.Metadata;$public=Join-Path $fixture.Root 'windows-test-reports-1-1'
$drivers=Join-Path $parent 'drivers.json';[IO.File]::WriteAllText($drivers,'{"SchemaVersion":1,"Releases":[]}')
function gh {
 $global:LASTEXITCODE=0
 if(($args -join '|') -ceq ('api|repos/example/windows_setup/commits/'+$f.version+'|--jq|.sha')){return $f.commit}
 if(($args -join '|') -ceq 'api|--paginate|repos/example/windows_setup/releases?per_page=100|--jq|.[].tag_name'){return}
 if($args[0] -ceq 'release' -and $args[1] -ceq 'create'){throw 'LOCAL_GH_BOUNDARY_ONLY'}
 throw 'unexpected fixture GitHub call'
}
$reached=$false
try {
 $params=@{PublicDirectory=$public;Version=$f.version;Commit=$f.commit;NotesPath=(Join-Path $public 'summary.md');Repository='example/windows_setup';CoverageToolPath=$fixture.CoverageTool;DriverAssetManifestPath=$drivers;ReportArchive=$fixture.Archive;BundleToolPath=$fixture.BundleTool;RunAttempt=1;RunUrl=$f.run_url;SourceRoot=$fixture.Source;ContainerDirectory=(Join-Path $fixture.Root 'docker-test-reports-1-1')}
 try {& (Join-Path $root 'script/report/publish_quality_release.ps1') @params} catch {$reached=$_.Exception.Message -ceq 'LOCAL_GH_BOUNDARY_ONLY';if(-not $reached){Write-Host $_.Exception.Message}}
 if(-not $reached){throw 'runtime release failed before the local GitHub boundary'}
 $params.RunAttempt=2;$rejected=$false
 try {& (Join-Path $root 'script/report/publish_quality_release.ps1') @params} catch {$rejected=$_.Exception.Message -cne 'LOCAL_GH_BOUNDARY_ONLY'}
 if(-not $rejected){throw 'wrong attempt reached GitHub boundary'}
 $params.RunAttempt=1;[IO.File]::AppendAllText((Join-Path $public 'junit.xml'),'fixture mutation');$rejected=$false
 try {& (Join-Path $root 'script/report/publish_quality_release.ps1') @params} catch {$rejected=$_.Exception.Message -cne 'LOCAL_GH_BOUNDARY_ONLY'}
 if(-not $rejected){throw 'changed same-run input reached GitHub boundary'}
} finally {Remove-Item Function:\gh}
Write-Host '@@ASSERT@@{"Name":"runtime release verifies actual bundle and rejects wrong attempt and changed input before GitHub boundary","Passed":true}'
