#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'script/test/test_report.ps1')
function Assert([bool]$Passed,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Passed}|ConvertTo-Json -Compress));if(-not $Passed){throw $Name}}
$fixture=Join-Path $env:TEMP ('tag_go_staging_'+[guid]::NewGuid().ToString('N'))
$attach=Join-Path $root 'script/test/attach_go_coverage.ps1'
function New-Case([string]$Name,[string]$RefType='Release',[int]$SchemaVersion=2,[switch]$RestoredStage){
 $directory=Join-Path $fixture $Name
 $public=Join-Path $directory $(if($RestoredStage){'native-stage-import/report'}else{'NUC-CI-Results/public'})
 $producer=Join-Path $directory $(if($RestoredStage){'native-stage-import/go'}else{'go-coverage'})
 [void][IO.Directory]::CreateDirectory($producer)
 $checks=@(foreach($layer in @('Unit','Integration')){[pscustomobject]@{Name=('synthetic_'+$layer);Layer=$layer;Executed=$true;Passed=$true;Status='Passed';ExitCode=0;Assertions=@([pscustomobject]@{Name='explicit synthetic staging fixture';Passed=$true})}})
 $refName=if($RefType -eq 'Release'){'v1.2.3'}else{'main'}
 $null=Write-TestReports -Checks $checks -OutputDirectory $public -Commit ('a'*40) -RunUrl 'https://github.com/example/repo/actions/runs/123' -SourceState Clean -Version v1.2.3 -Environment 'Synthetic staging fixture' -RefType $RefType -RefName $refName -MeasuredAt '2026-11-09T00:00:00Z' -SchemaVersion $SchemaVersion
 $profile=Join-Path $producer 'go_coverage.out'
 [IO.File]::WriteAllText($profile,"mode: atomic`nwindows_setup/script/test/acceptance/report.go:1.1,1.2 8 1`nwindows_setup/script/test/acceptance/report.go:2.1,2.2 2 0`n",[Text.UTF8Encoding]::new($false))
 $coverage=[ordered]@{SchemaVersion=1;Scope='all-owned-go-including-cli';Metric='statements';Covered=8;TotalStatements=10;Percent=80.0;Threshold=80;Commit=('a'*40);RunUrl='https://github.com/example/repo/actions/runs/123';MeasuredAt='2026-11-09T00:00:01Z';SourceState='Clean';GoVersion='go1.27.3';Environment='windows/amd64';ProfileSHA256=(Get-FileHash -LiteralPath $profile).Hash.ToLowerInvariant();Packages=@('windows_setup/script/test/acceptance')}
 [IO.File]::WriteAllText((Join-Path $producer 'go_coverage.json'),($coverage|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
 return [pscustomobject]@{Directory=$directory;Public=$public;Producer=$producer;Summary=(Join-Path $public 'summary.json')}
}
function Run-Attach($Case,[switch]$PreparingRelease){
 $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$attach,'-PublicDirectory',$Case.Public,'-CoverageDirectory',$Case.Producer)
 if($PreparingRelease){$arguments+=@('-PreparingRelease')}
 $prior=$ErrorActionPreference
 try{$ErrorActionPreference='Continue';& powershell.exe @arguments *> (Join-Path $Case.Directory 'attach.private.log');return $LASTEXITCODE}finally{$ErrorActionPreference=$prior}
}
function Reject-Unchanged($Case,[string]$Name){
 $before=(Get-FileHash -LiteralPath $Case.Summary).Hash
 Assert ((Run-Attach $Case -PreparingRelease) -ne 0) $Name
 Assert ((Get-FileHash -LiteralPath $Case.Summary).Hash -ceq $before -and -not(Test-Path -LiteralPath (Join-Path $Case.Public 'go_coverage.out'))) ($Name+' leaves the original staging report untouched')
}
$tag=New-Case 'tag'
Assert ((Run-Attach $tag) -ne 0) 'Release reports still require explicit unpublished-staging intent'
Assert ((Run-Attach $tag -PreparingRelease) -eq 0) 'native Tag staging attaches measured Go metadata and raw bytes before publication'
$joined=Get-Content -LiteralPath $tag.Summary -Raw|ConvertFrom-Json
Assert ($joined.RefType -ceq 'Release' -and $joined.RefName -ceq 'v1.2.3' -and $joined.GoCoverage.Covered -eq 8 -and $joined.Coverage -ceq 'NotMeasured') 'Tag attachment preserves identity and does not invent whole-repo coverage'
Assert ((Get-FileHash -LiteralPath (Join-Path $tag.Public 'go_coverage.out')).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $tag.Producer 'go_coverage.out')).Hash) 'Tag staging contains the exact measured profile bytes'
$before=(Get-FileHash -LiteralPath $tag.Summary).Hash
Assert ((Run-Attach $tag -PreparingRelease) -ne 0 -and (Get-FileHash -LiteralPath $tag.Summary).Hash -ceq $before) 'already-attached Release evidence cannot be rewritten'
$legacy=New-Case 'legacy' 'Release' 1;Reject-Unchanged $legacy 'historical schema1 Release cannot gain fabricated modern evidence'
$branch=New-Case 'branch_wrong_intent' 'Branch';Reject-Unchanged $branch 'Release preparation intent cannot be applied to branch reports'
$complete=New-Case 'already_complete';$report=Get-Content -LiteralPath $complete.Summary -Raw|ConvertFrom-Json
$repo=[pscustomobject]@{SchemaVersion=1;Metric='complete-executable-lines-v1';Commit=$report.Commit;RunUrl=$report.RunUrl;MeasuredAt='2026-11-09T00:00:01Z';SourceState='Clean';InventorySHA256=('b'*64);NormalizedSHA256=('c'*64);Result=[pscustomobject]@{SchemaVersion=1;Metric='complete-executable-lines-v1';Complete=$true;Covered=8;Executable=10;Percent=80;Missing=@();Blockers=@();Languages=[pscustomobject]@{powershell=[pscustomobject]@{Covered=8;Executable=10}}}}
$report|Add-Member -NotePropertyName RepoCoverage -NotePropertyValue $repo;$report.Coverage='Measured'
[IO.File]::WriteAllText($complete.Summary,($report|ConvertTo-Json -Depth 20));Reject-Unchanged $complete 'already-complete Release snapshot cannot be backfilled'
foreach($name in @('go_coverage.out','go_coverage.json')){
 $existing=New-Case ('existing_'+$name.Replace('.','_'));$artifact=Join-Path $existing.Public $name
 [IO.File]::WriteAllText($artifact,'existing fixture bytes must not be overwritten')
 $summaryHash=(Get-FileHash -LiteralPath $existing.Summary).Hash;$artifactHash=(Get-FileHash -LiteralPath $artifact).Hash
 Assert ((Run-Attach $existing -PreparingRelease) -ne 0) ('existing Release staging artifact is rejected: '+$name)
 Assert ((Get-FileHash -LiteralPath $existing.Summary).Hash -ceq $summaryHash -and (Get-FileHash -LiteralPath $artifact).Hash -ceq $artifactHash) ('existing Release report and artifact bytes are preserved: '+$name)
}
foreach($mutation in @('commit','run','profile','missing_profile','missing_metadata','below_threshold','rounded_below_threshold','dirty')){
 $case=New-Case $mutation;$path=Join-Path $case.Producer 'go_coverage.json';$c=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
 switch($mutation){
  commit{$c.Commit='b'*40}
  run{$c.RunUrl='https://github.com/example/repo/actions/runs/124'}
  profile{[IO.File]::AppendAllText((Join-Path $case.Producer 'go_coverage.out'),'tampered')}
  missing_profile{Remove-Item -LiteralPath (Join-Path $case.Producer 'go_coverage.out')}
  missing_metadata{}
  below_threshold{$c.Covered=7;$c.Percent=70;[IO.File]::WriteAllText((Join-Path $case.Producer 'go_coverage.out'),"mode: atomic`nwindows_setup/script/test/acceptance/report.go:1.1,1.2 7 1`nwindows_setup/script/test/acceptance/report.go:2.1,2.2 3 0`n");$c.ProfileSHA256=(Get-FileHash -LiteralPath (Join-Path $case.Producer 'go_coverage.out')).Hash.ToLowerInvariant()}
  rounded_below_threshold{$c.Covered=7996;$c.TotalStatements=10000;$c.Percent=80.0;[IO.File]::WriteAllText((Join-Path $case.Producer 'go_coverage.out'),"mode: atomic`nwindows_setup/script/test/acceptance/report.go:1.1,1.2 7996 1`nwindows_setup/script/test/acceptance/report.go:2.1,2.2 2004 0`n");$c.ProfileSHA256=(Get-FileHash -LiteralPath (Join-Path $case.Producer 'go_coverage.out')).Hash.ToLowerInvariant()}
  dirty{$report=Get-Content -LiteralPath $case.Summary -Raw|ConvertFrom-Json;$report.SourceState='Dirty';[IO.File]::WriteAllText($case.Summary,($report|ConvertTo-Json -Depth 20))}
 }
 [IO.File]::WriteAllText($path,($c|ConvertTo-Json -Depth 8));if($mutation -eq 'missing_metadata'){Remove-Item -LiteralPath $path};Reject-Unchanged $case ('invalid Tag evidence is rejected: '+$mutation)
}
# Current CI requires Go tests while runtime coverage does not require Go evidence.
$workflow=[IO.File]::ReadAllText((Join-Path $root '.github/workflows/windows_tests.yml'))
$testsAt=$workflow.IndexOf("'test','-mod=vendor','-count=1','./...'");$packAt=$workflow.IndexOf("'native-stage-pack','--runtime'");$repoAt=$workflow.IndexOf('run_repo_coverage.ps1');$publishAt=$workflow.IndexOf('publish_quality_release.ps1')
Assert ($testsAt -ge 0 -and $testsAt -lt $packAt -and $packAt -lt $repoAt -and $repoAt -lt $publishAt) 'workflow requires Go tests before runtime evidence and publication'
Assert (-not $workflow.Contains('attach_go_coverage.ps1') -and -not $workflow.Contains('measure_go_coverage.ps1')) 'current workflow does not require Go coverage attachment'
# Complete the actual local Tag producer -> strict repo attachment -> publisher
# validation path. Coverage is an explicit tiny synthetic fixture, never CI proof.
$tool=Join-Path $fixture 'repo_coverage_tool.exe'
Push-Location $root
try{& go.exe build -mod=vendor -o $tool ./script/test/repo_coverage_tool;if($LASTEXITCODE){throw 'fixture coverage CLI build failed'}}finally{Pop-Location}
$evidence=Join-Path $fixture 'synthetic_repo';[void][IO.Directory]::CreateDirectory($evidence)
$inventory=[ordered]@{Sources=@([ordered]@{Path='core/example.ps1';Language='powershell';SHA256=('b'*64);ExpectedLines=@(1,2,3,4,5)});Excluded=$null;Blockers=$null}
[IO.File]::WriteAllText((Join-Path $evidence 'coverage_inventory.json'),($inventory|ConvertTo-Json -Depth 8))
$xml='<coverage coverage-schema="1" coverage-metric="complete-executable-lines-v1"><packages><package><classes><class filename="core/example.ps1"><lines><line number="1" hits="1"/><line number="2" hits="1"/><line number="3" hits="1"/><line number="4" hits="1"/><line number="5" hits="0"/></lines></class></classes></package></packages></coverage>'
[IO.File]::WriteAllText((Join-Path $evidence 'coverage.xml'),$xml)
$completeCoverage=[ordered]@{SchemaVersion=1;Metric='complete-executable-lines-v1';Commit=('a'*40);RunUrl='https://github.com/example/repo/actions/runs/123';MeasuredAt='2026-11-09T00:00:01Z';SourceState='Clean';InventorySHA256=(Get-FileHash -LiteralPath (Join-Path $evidence 'coverage_inventory.json')).Hash.ToLowerInvariant();NormalizedSHA256=(Get-FileHash -LiteralPath (Join-Path $evidence 'coverage.xml')).Hash.ToLowerInvariant();Result=[ordered]@{SchemaVersion=1;Metric='complete-executable-lines-v1';Complete=$true;Covered=4;Executable=5;Percent=80.0;Missing=$null;Blockers=$null;Languages=@{powershell=@{Covered=4;Executable=5}}}}
[IO.File]::WriteAllText((Join-Path $evidence 'repo_coverage.json'),($completeCoverage|ConvertTo-Json -Depth 8))
$flow=New-Case 'complete_tag_flow'
Assert ((Run-Attach $flow -PreparingRelease) -eq 0) 'complete synthetic Tag flow starts with the actual native Go producer'
& (Join-Path $root 'script/test/attach_repo_coverage.ps1') -PublicDirectory $flow.Public -CoverageDirectory $evidence -CoverageToolPath $tool
$joined=Get-Content -LiteralPath $flow.Summary -Raw|ConvertFrom-Json
Assert ($joined.GoCoverage.Covered -eq 8 -and $joined.RepoCoverage.Result.Covered -eq 4 -and $joined.Coverage -ceq 'Measured') 'actual strict repo attachment preserves separately measured Go evidence and profile'
$emptyDrivers=Join-Path $fixture 'no_driver_assets.json';[IO.File]::WriteAllText($emptyDrivers,'{"SchemaVersion":1,"Releases":[]}')
$global:tagGoPublisherReached=$false
function gh {$global:tagGoPublisherReached=$true;throw 'LOCAL_GH_BOUNDARY_ONLY'}
Assert ((Get-Command gh).CommandType -eq 'Function') '本機發布邊界必須使用 mock gh'
$boundary=$false
try{& (Join-Path $root 'script/report/publish_quality_release.ps1') -PublicDirectory $flow.Public -Version v1.2.3 -Commit ('a'*40) -NotesPath (Join-Path $flow.Public 'summary.md') -Repository example/repo -CoverageToolPath $tool -DriverAssetManifestPath $emptyDrivers}catch{$boundary=$_.Exception.Message -like '*舊口徑僅供歷史讀取*'}finally{Remove-Item Function:\gh}
Assert ($boundary -and -not $global:tagGoPublisherReached) 'current publisher rejects historical coverage before the GitHub boundary'
# Exercise the previously missing official requirements gate, not just the PS
# attachment and publisher. This synthetic profile inventories every owned Go
# file so the real CLI's denominator guard remains active; it is not CI data.
$gatePublic=Join-Path $fixture 'tag_requirements_public'
Copy-Item -LiteralPath $flow.Public -Destination $gatePublic -Recurse
$owned=@(& git -C $root -c core.quotePath=false ls-files | Where-Object {$_ -like 'script/test/*.go' -and $_ -notlike '*_test.go'})
Assert ($LASTEXITCODE -eq 0 -and $owned.Count -gt 0) 'Tag gate fixture inventories actual tracked owned Go paths'
[Array]::Sort($owned,[StringComparer]::Ordinal)
$profileLines=@('mode: set')
$packages=@()
foreach($file in $owned){
 $path='windows_setup/'+$file
 $profileLines+=($path+':1.1,1.2 8 1'),($path+':2.1,2.2 2 0')
 $packages+=$path.Substring(0,$path.LastIndexOf('/'))
}
$profilePath=Join-Path $gatePublic 'go_coverage.out'
[IO.File]::WriteAllText($profilePath,(($profileLines -join "`n")+"`n"),[Text.UTF8Encoding]::new($false))
$gateSnapshot=Get-Content -LiteralPath (Join-Path $gatePublic 'summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
$gateSnapshot.GoCoverage.Covered=8*$owned.Count
$gateSnapshot.GoCoverage.TotalStatements=10*$owned.Count
$gateSnapshot.GoCoverage.Percent=80.0
$gateSnapshot.GoCoverage.Environment='Synthetic all-owned Tag gate fixture, not measured CI data'
$gateSnapshot.GoCoverage.ProfileSHA256=(Get-FileHash -LiteralPath $profilePath).Hash.ToLowerInvariant()
$gateSnapshot.GoCoverage.Packages=@($packages|Sort-Object -Unique)
. (Join-Path $root 'script/report/portal.ps1')
Write-SnapshotView -Snapshot $gateSnapshot -OutputDirectory $gatePublic
Assert-TestReportSnapshot -Report $gateSnapshot -Release
$gateTool=Join-Path $fixture 'requirements_gate.exe'
Push-Location $root
try{& go.exe build -mod=vendor -o $gateTool ./script/test/requirements_gate;if($LASTEXITCODE){throw 'fixture requirements CLI build failed'}}finally{Pop-Location}
$priorPreference=$ErrorActionPreference
try{$ErrorActionPreference='Continue';& $gateTool --tests-only --artifact-dir $gatePublic --source-root $root --expected-sha ('a'*40) --expected-run-url 'https://github.com/example/repo/actions/runs/123' *> (Join-Path $fixture 'tag_requirements.private.log');$gateExit=$LASTEXITCODE}finally{$ErrorActionPreference=$priorPreference}
Assert ($gateExit -eq 0) 'tests-only CLI accepts valid Tag report without a Go coverage gate'
$legacySource=Join-Path $fixture 'historical_source';[void][IO.Directory]::CreateDirectory($legacySource)
foreach($file in $owned){$target=Join-Path $legacySource $file;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));[IO.File]::WriteAllText($target,"package fixture`n")}
[void][IO.Directory]::CreateDirectory((Join-Path $legacySource '.github/workflows'))
[IO.File]::WriteAllText((Join-Path $legacySource '.github/workflows/windows_tests.yml'),'name: fixture')
[IO.File]::WriteAllText((Join-Path $legacySource 'init.cmd'),'@echo off')
[IO.File]::WriteAllText((Join-Path $legacySource 'windows.cmd'),'@echo off')
[IO.File]::WriteAllText((Join-Path $legacySource 'readme.md'),"init.cmd windows.cmd Shift+F10 -AfterRestart -VerifyOnly`n![CI](https://github.com/example/repo/actions/workflows/windows_tests.yml/badge.svg)")
& git -C $legacySource init -q;if($LASTEXITCODE -ne 0){throw 'historical fixture git init failed'}
& git -C $legacySource add .;if($LASTEXITCODE -ne 0){throw 'historical fixture git add failed'}
try{$ErrorActionPreference='Continue';& $gateTool --historical-go --artifact-dir $gatePublic --source-root $legacySource --expected-sha ('a'*40) --expected-run-url 'https://github.com/example/repo/actions/runs/123' *> (Join-Path $fixture 'historical_requirements.private.log');$gateExit=$LASTEXITCODE}finally{$ErrorActionPreference=$priorPreference}
Assert ($gateExit -eq 0) 'explicit historical mode still validates the original Go coverage contract'
$global:tagGoPublisherReached=$false
function gh {$global:tagGoPublisherReached=$true;throw 'LOCAL_TAG_GATE_GH_BOUNDARY_ONLY'}
Assert ((Get-Command gh).CommandType -eq 'Function') 'Tag 發布邊界必須使用 mock gh'
$boundary=$false
try{& (Join-Path $root 'script/report/publish_quality_release.ps1') -PublicDirectory $gatePublic -Version v1.2.3 -Commit ('a'*40) -NotesPath (Join-Path $gatePublic 'summary.md') -Repository example/repo -CoverageToolPath $tool -DriverAssetManifestPath $emptyDrivers}catch{$boundary=$_.Exception.Message -like '*舊口徑僅供歷史讀取*'}finally{Remove-Item Function:\gh}
Assert ($boundary -and -not $global:tagGoPublisherReached) 'historical evidence cannot become a new release even when its former gate passes'
$global:LASTEXITCODE=0
