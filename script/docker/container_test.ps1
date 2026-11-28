#Requires -Version 5.1
$ErrorActionPreference='Stop'
try {
 . C:/tools/ci_tasks.ps1
 Assert-CIRequiredTools -Managed
 if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'Windows PowerShell 5.1 required.'}
 $null=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 & git.exe --version
 if($LASTEXITCODE -ne 0){throw 'Git is required.'}
 & git.exe config --global --add safe.directory C:/workspace
 if($LASTEXITCODE -ne 0){throw 'Cannot configure checkout ownership exception.'}
 if(-not(Test-Path C:/workspace/.git -PathType Container)){throw 'A complete Git checkout must be mounted read-only.'}
 $env:GIT_OPTIONAL_LOCKS='0'
 $env:WINDOWS_SETUP_TEST_CONTEXT='Windows container'
 Set-Location C:/workspace
 . C:/workspace/script/docker/acceptance.ps1
 Initialize-ContainerGoEnvironment -SourceRoot C:/workspace -CacheRoot (Join-Path $env:TEMP ('container_go_'+[guid]::NewGuid().ToString('N')))
 $fixture=Join-Path $env:TEMP ('container_acceptance_'+[guid]::NewGuid().ToString('N'))
 $plan=Get-ContainerAcceptancePlan -ReportDirectory C:/reports -FixtureDirectory $fixture
 . C:/workspace/script/test/container_shards.ps1
 # 分片索引與份數只由 docker.ps1 經 compose 傳入；未設時等於單一份完整執行。
 $shardText=@{Index=[string]$env:WINDOWS_SETUP_SHARD_INDEX;Count=[string]$env:WINDOWS_SETUP_SHARD_COUNT}
 if(-not $shardText.Index){$shardText.Index='0'};if(-not $shardText.Count){$shardText.Count='1'}
 if($shardText.Index -cnotmatch '^[0-9]{1,2}$' -or $shardText.Count -cnotmatch '^[0-9]{1,2}$'){throw 'Invalid container shard identity.'}
 $shardIndex=[int]$shardText.Index;$shardCount=[int]$shardText.Count
 Write-CIContainerShardManifest -Directory C:/reports -ShardIndex $shardIndex -ShardCount $shardCount
 Write-Host ('Phase 1: actual PowerShell unit and isolated integration suites / shard '+$shardIndex+' of '+$shardCount+'.')
 & C:/workspace/script/test/run_ci.ps1 -Layer All -ReportDirectory C:/reports -Parallelism 2 -ShardIndex $shardIndex -ShardCount $shardCount
 # 第 0 份（含語法檢查與兩個測試層）在容器內續跑 Go 驗收與需求閘門；其他分片只執行分配到的 suites。
 if($shardIndex -ne 0){Write-Host 'Shard complete: container Go acceptance runs in shard 0; docker-tests merges and validates all shard reports.';exit 0}
 Write-Host 'Phase 2: private, explicitly synthetic renderer fixture.'
 & C:/workspace/script/test/create_portal_fixture.ps1 -OutputDirectory $fixture
 if($plan.Mode -eq 'LocalSynthetic'){Write-Host 'Local mode: Go contract checks use synthetic evidence; actual local PowerShell metadata is preserved in reports/public. This is not published CI evidence.'}
 Write-Host ('Phase 3: Go acceptance tests / '+$plan.Mode)
 $env:WINDOWS_SETUP_ARTIFACT_DIR=$plan.ArtifactDirectory
 $env:WINDOWS_SETUP_PORTAL_FIXTURE_DIR=Join-Path $fixture 'portal'
 Invoke-ContainerGoTestPhase -Plan $plan -SourceRoot C:/workspace -ReportDirectory C:/reports
 Write-Host ('Phase 4: source and report requirements gate / '+$plan.Mode)
 Invoke-ContainerGo -Arguments @('run','./script/test/requirements_gate','--tests-only','--artifact-dir',$plan.ArtifactDirectory,'--source-root','C:/workspace','--expected-sha',$plan.Commit,'--expected-run-url',$plan.RunUrl)
 Write-CIContainerShardManifest -Directory C:/reports -ShardIndex $shardIndex -ShardCount $shardCount -Acceptance
 exit 0
} catch {
 $failure=$_
 try{Write-CIContainerFailureDiagnostics -ReportDirectory C:/reports}catch{Write-Warning 'Container diagnostics could not be read; original failure is preserved.'}
 Write-Error $failure -ErrorAction Continue
 exit 1
}
