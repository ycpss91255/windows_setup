#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'script/test/test_report.ps1')
. (Join-Path $root 'script/report/portal.ps1')
. (Join-Path $root 'test/powershell/helpers/report_bundle_fixture.ps1')
$parent=Join-Path ([IO.Path]::GetTempPath()) ('portal_runtime_fixture_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($parent)
$oldTool=$env:WINDOWS_SETUP_REPORT_BUNDLE_TOOL;$oldRepo=$env:GH_REPO
try {
 $fixture=New-TestReportBundleFixture -RepositoryRoot $root -Destination (Join-Path $parent 'fixture') -Runtime
 $env:WINDOWS_SETUP_REPORT_BUNDLE_TOOL=$fixture.BundleTool;$env:GH_REPO='example/windows_setup';$f=$fixture.Metadata
 $entry=[pscustomobject]@{Version=$f.version;Commit=$f.commit;Immutable=$true;Repository=$env:GH_REPO;ArchivePath=$fixture.Archive;ArchiveDigest=('sha256:'+$f.sha256);ArchiveSize=$f.size;SourcePath=$fixture.Source;SnapshotPath='';ManifestPath='';ReleaseUrl=('https://github.com/'+$env:GH_REPO+'/releases/tag/'+$f.version)}
 $evidence=Test-PortalReleaseEvidence $entry
 if($evidence.HasGoProfile -or $evidence.Snapshot.RepoCoverage.Scope -cne 'core-modules-powershell-and-modules-native-csharp'){throw 'runtime bundle scope or Go profile mismatch'}
 $wrong=$entry|Select-Object *;$wrong.Commit=('b'*40);$rejected=$false
 try {Test-PortalReleaseEvidence $wrong|Out-Null}catch{$rejected=$true}
 if(-not $rejected){throw 'wrong commit accepted'}
 Write-Host '@@ASSERT@@{"Name":"runtime ZIP is verified without Go profile and wrong source is rejected","Passed":true}'
} finally {$env:WINDOWS_SETUP_REPORT_BUNDLE_TOOL=$oldTool;$env:GH_REPO=$oldRepo}
