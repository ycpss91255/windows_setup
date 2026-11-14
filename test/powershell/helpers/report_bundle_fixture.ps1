#Requires -Version 5.1
function New-TestReportBundleFixture {
 [CmdletBinding()]
 param([Parameter(Mandatory=$true)][string]$RepositoryRoot,[Parameter(Mandatory=$true)][string]$Destination,[switch]$Runtime)
 if(-not [IO.Path]::IsPathRooted($RepositoryRoot) -or -not [IO.Path]::IsPathRooted($Destination)){throw 'Paths must be absolute.'}
 $root=[IO.Path]::GetFullPath($RepositoryRoot);$destination=[IO.Path]::GetFullPath($Destination)
 if(Test-Path -LiteralPath $destination){throw 'Fixture destination already exists.'}
 $previous=[Environment]::GetEnvironmentVariable('WINDOWS_SETUP_BUNDLE_FIXTURE_DIR','Process')
 $previousRuntime=[Environment]::GetEnvironmentVariable('WINDOWS_SETUP_RUNTIME_BUNDLE_FIXTURE_DIR','Process')
 Push-Location -LiteralPath $root
 try {
  if($Runtime){[Environment]::SetEnvironmentVariable('WINDOWS_SETUP_RUNTIME_BUNDLE_FIXTURE_DIR',$destination,'Process');$fixtureTest='^TestRuntimeReleaseReportDoesNotRequireGoCoverage$'}else{[Environment]::SetEnvironmentVariable('WINDOWS_SETUP_BUNDLE_FIXTURE_DIR',$destination,'Process');$fixtureTest='^TestExportSyntheticConsumerFixture$'}
  $fixtureFailed=$false;$oldPreference=$ErrorActionPreference
  try{
   $ErrorActionPreference='Continue'
   & go.exe test -count=1 -run $fixtureTest ./script/test/report_bundle_tool *> $null
   $fixtureFailed=($LASTEXITCODE -ne 0)
  }catch{$fixtureFailed=$true}finally{$ErrorActionPreference=$oldPreference}
  if($fixtureFailed){Write-Host '@@SAFE_FIXTURE_DIAG@@fixture_export:go_fixture_failed';throw 'Synthetic fixture generation failed.'}
  $metadata=Get-Content -LiteralPath (Join-Path $destination 'fixture.json') -Raw -Encoding UTF8|ConvertFrom-Json
  if($metadata.kind -cne 'Synthetic' -or $metadata.source -cne 'source' -or $metadata.archive -cne ('windows_setup_report_'+$metadata.version+'.zip')){throw 'Invalid synthetic fixture metadata.'}
  $source=Join-Path $destination $metadata.source;$archive=Join-Path $destination $metadata.archive
  if(-not (Test-Path -LiteralPath $source -PathType Container) -or -not (Test-Path -LiteralPath $archive -PathType Leaf)){throw 'Synthetic fixture is incomplete.'}
  $bundleTool=Join-Path $destination 'report_bundle_tool.exe';$coverageTool=Join-Path $destination 'repo_coverage_tool.exe'
  & go.exe build -o $bundleTool ./script/test/report_bundle_tool
  if($LASTEXITCODE -ne 0){throw 'Bundle tool build failed.'}
  & go.exe build -o $coverageTool ./script/test/repo_coverage_tool
  if($LASTEXITCODE -ne 0){throw 'Coverage tool build failed.'}
  return [pscustomobject]@{Root=$destination;Metadata=$metadata;Source=$source;Archive=$archive;BundleTool=$bundleTool;CoverageTool=$coverageTool}
 }finally {
  [Environment]::SetEnvironmentVariable('WINDOWS_SETUP_BUNDLE_FIXTURE_DIR',$previous,'Process')
  [Environment]::SetEnvironmentVariable('WINDOWS_SETUP_RUNTIME_BUNDLE_FIXTURE_DIR',$previousRuntime,'Process')
  Pop-Location
 }
}
