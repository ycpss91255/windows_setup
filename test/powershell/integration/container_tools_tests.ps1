#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'script/docker/library.ps1')
function Assert([bool]$Condition,[string]$Message){Write-Host ('@@ASSERT@@'+(@{Name=$Message;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Message}}
function Refuse([scriptblock]$Action,[string]$Message){$caught=$false;try{& $Action|Out-Null}catch{$caught=$true};Assert $caught $Message}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ("container 中文 ' "+[guid]::NewGuid().ToString('N'))
$source=Join-Path $fixture 'source';$reports=Join-Path $fixture 'reports'
New-Item -ItemType Directory (Join-Path $source '.git'),(Join-Path $source 'dockerfile'),(Join-Path $source 'script/docker'),(Join-Path $source 'script/test') -Force|Out-Null
foreach($file in @('dockerfile/windows_tests.dockerfile','script/docker/download_library.ps1','script/docker/install_min_git.ps1','script/docker/install_go.ps1','script/docker/install_managed_tools.ps1','script/docker/container_test.ps1','script/docker/container_health.ps1','script/test/ci_tasks.ps1','.dockerignore','compose.yaml')){Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $source $file)}
$first=Get-ContainerContext $source $reports
$again=Get-ContainerContext $source $reports
Assert ($first.Image -ceq $again.Image -and $first.Project -ceq $again.Project) 'same toolchain inputs select the same exact image and project'
Assert ($first.Root -ceq $source -and $first.Reports -ceq $reports) 'spaces Unicode and apostrophe paths remain one value'
Assert (-not(Test-Path $reports)) 'planning never creates or overwrites report destination'
[IO.File]::AppendAllText((Join-Path $source 'script/docker/container_test.ps1'),"`r`n# changed fixture")
$changed=Get-ContainerContext $source $reports
Assert ($changed.Image -cne $first.Image) 'changed runner content cannot reuse stale image tag'
# The toolchain installer must participate in the content-addressed build cache.
$managedInstaller=Join-Path $source 'script/docker/install_managed_tools.ps1'
Copy-Item -LiteralPath (Join-Path $root 'script/docker/install_managed_tools.ps1') -Destination $managedInstaller
$beforeManaged=Get-ContainerContext $source $reports
[IO.File]::AppendAllText($managedInstaller,"`r`n# changed managed tool pin")
$afterManaged=Get-ContainerContext $source $reports
Assert ($afterManaged.Image -cne $beforeManaged.Image) 'changed managed SDK or PowerShell pin cannot reuse stale offline container image'
Refuse {Get-ContainerContext $source (Join-Path $source 'reports')} 'report bind cannot be inside read-only source'
Refuse {Get-ContainerContext $source $fixture} 'report bind cannot contain source checkout'
Refuse {Get-ContainerContext $source $source} 'report bind cannot equal source checkout'
$linked=Join-Path $fixture 'linked';New-Item -ItemType Directory $linked|Out-Null;[IO.File]::WriteAllText((Join-Path $linked '.git'),'gitdir: outside')
Refuse {Get-ContainerContext $linked $reports} 'linked worktree git pointer is rejected instead of mounting incomplete history'
# Fake only Docker invocation, proving the native exit status is preserved for callers.
function docker.exe {$global:LASTEXITCODE=37}
$failure=$null;try{Invoke-ContainerDocker -Arguments @('run','fixture')}catch{$failure=$_.Exception}
Assert ($failure -and $failure.Data['ExitCode'] -eq 37) 'failed Docker command retains exact nonzero exit status'
function docker.exe {Write-Output 'fixture-ok';$global:LASTEXITCODE=0}
Assert ((Invoke-ContainerDocker -Arguments @('version')) -eq 'fixture-ok') 'successful Docker output is returned unchanged'
function docker.exe {$script:captured=@($args);$global:LASTEXITCODE=0}
Invoke-ContainerDocker -Arguments @('info','--format','{{json .}}')
Assert ($script:captured.Count -eq 3 -and $script:captured[1] -eq '--format' -and $script:captured[2] -eq '{{json .}}') 'Docker info format argument reaches executable intact'
Invoke-ContainerDocker -Arguments @('compose','version')
Assert (($script:captured -join '|') -eq 'compose|version') 'Compose subcommand is not dropped during argument forwarding'
Remove-Item Function:/docker.exe

foreach($mode in @('process','hyperv')){
 $configuration=[pscustomobject]@{services=[pscustomobject]@{tools=[pscustomobject]@{image=$first.Image;isolation=$mode;build=[pscustomobject]@{isolation=$mode}}}}
 Assert-ContainerCompose -Configuration $configuration -Isolation $mode -Image $first.Image
 Assert $true ('resolved Compose accepts matching build and run isolation: '+$mode)
 $configuration.services.tools.build.isolation=''
 Refuse {Assert-ContainerCompose $configuration $mode $first.Image} ('missing build isolation cannot silently use engine default: '+$mode)
 $configuration.services.tools.build.isolation=$mode;$configuration.services.tools.isolation=''
 Refuse {Assert-ContainerCompose $configuration $mode $first.Image} ('missing run isolation is rejected: '+$mode)
}
. (Join-Path $root 'script/docker/acceptance.ps1')
$local=Get-ContainerAcceptancePlan -ReportDirectory $reports -FixtureDirectory $fixture -Commit '' -Repository '' -RunId '' -RefType '' -RefName ''
Assert ($local.Mode -eq 'LocalSynthetic' -and $local.ArtifactDirectory -eq (Join-Path $fixture 'synthetic_snapshot') -and -not $local.ArtifactDirectory.StartsWith($reports)) 'local no-CI mode uses private labeled synthetic evidence without overwriting actual report'
$actual=Get-ContainerAcceptancePlan -ReportDirectory $reports -FixtureDirectory $fixture -Commit ('a'*40) -Repository 'example/repo' -RunId '123' -RefType 'branch' -RefName 'feature/test'
Assert ($actual.Mode -eq 'CIActual' -and $actual.ArtifactDirectory -eq (Join-Path $reports 'public') -and $actual.RunUrl -eq 'https://github.com/example/repo/actions/runs/123') 'CI mode binds Go acceptance to actual report and supplied execution identity'
Refuse {Get-ContainerAcceptancePlan $reports $fixture ('a'*40) '' ''} 'partial CI metadata cannot downgrade to synthetic validation'
Refuse {Get-ContainerAcceptancePlan $reports $fixture 'invalid' 'example/repo' '123'} 'malformed CI commit cannot become evidence'
function go.exe {$global:LASTEXITCODE=19}
Refuse {Invoke-ContainerGo -Arguments @('run','fixture.go')} 'Go failure is not swallowed by container orchestration'
Remove-Item Function:/go.exe
Refuse {Get-ContainerAcceptancePlan $reports $fixture ('a'*40) 'example/repo' '123' '' ''} 'CI identity without ref metadata cannot silently become local branch evidence'
# Exercise real Windows executable lookup with the image's PATH, without running setup.
$dockerfile=[IO.File]::ReadAllText((Join-Path $root 'dockerfile/windows_tests.dockerfile'))
$imagePath=[regex]::Match($dockerfile,'(?m)^ENV PATH="([^"]+)"').Groups[1].Value
Assert ($imagePath -and -not $imagePath.Contains('$')) 'image PATH is explicit instead of case-sensitive inherited Docker interpolation'
$originalPath=$env:Path
try{
 $env:Path=$imagePath
 Assert ([bool](Get-Command powershell.exe -CommandType Application -ErrorAction Stop)) 'image PATH preserves actual Windows PowerShell discovery'
 Assert ([bool](Get-Command cmd.exe -CommandType Application -ErrorAction Stop)) 'image PATH preserves actual Windows command processor discovery'
}finally{$env:Path=$originalPath}
# Go migration: exercise the process boundary with a fake executable, never Go.
function go.exe {$script:goArguments=@($args);$global:LASTEXITCODE=0;Write-Output 'go-result'}
Assert ((Invoke-ContainerGo -Arguments @('test','-count=1','./...')) -eq 'go-result') 'Go acceptance executes the Go toolchain and returns its actual output'
Assert (($script:goArguments -join '|') -eq 'test|-count=1|./...') 'Go test arguments retain uncached execution and package selection'
function go.exe {$global:LASTEXITCODE=23}
Refuse {Invoke-ContainerGo -Arguments @('run','./script/test/requirements_gate')} 'Go acceptance cannot swallow a nonzero process result'
Remove-Item Function:/go.exe
$goKeys=@('GOCACHE','GOMODCACHE','GOPATH','GOTMPDIR','GOTOOLCHAIN','GOPROXY','GOSUMDB','GOFLAGS','CGO_ENABLED','GOWORK','GOENV')
$before=@{};foreach($key in $goKeys){$before[$key]=[Environment]::GetEnvironmentVariable($key,'Process')}
try{
 $goCache=Join-Path $fixture 'go_cache'
 Initialize-ContainerGoEnvironment -SourceRoot $source -CacheRoot $goCache
 foreach($key in @('GOCACHE','GOMODCACHE','GOPATH','GOTMPDIR')){
  $value=[Environment]::GetEnvironmentVariable($key,'Process')
  Assert ($value.StartsWith($goCache+'\',[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $value -PathType Container)) ('Go writable state stays outside source: '+$key)
 }
 Assert ($env:GOTOOLCHAIN -eq 'local' -and $env:GOPROXY -eq 'off' -and $env:GOSUMDB -eq 'off' -and $env:GOFLAGS -eq '-mod=vendor' -and $env:CGO_ENABLED -eq '0' -and $env:GOWORK -eq 'off' -and $env:GOENV -eq 'off') 'Go execution uses checked-in vendor and cannot fetch toolchains or module services'
 Refuse {Initialize-ContainerGoEnvironment -SourceRoot $source -CacheRoot (Join-Path $source 'cache')} 'Go caches cannot write into the read-only source mount'
}finally{foreach($key in $goKeys){[Environment]::SetEnvironmentVariable($key,$before[$key],'Process')}}
$coverageSource=Join-Path $fixture 'coverage_source';New-Item -ItemType Directory (Join-Path $coverageSource 'script/test') -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $coverageSource 'script/test/measure_go_coverage.ps1'),'param($SourceRoot,$ReportDirectory,$OutputDirectory); throw ''fixture measurement failed''')
$global:localGoCalls=0
function go.exe {$global:localGoCalls++;$global:LASTEXITCODE=0}
Invoke-ContainerGoTestPhase -Plan ([pscustomobject]@{Mode='LocalSynthetic'}) -SourceRoot $coverageSource -ReportDirectory (Join-Path $fixture 'local_report')
Assert ($global:localGoCalls -eq 1) 'local container runs full Go tests without manufacturing clean coverage evidence'
Invoke-ContainerGoTestPhase -Plan ([pscustomobject]@{Mode='CIActual'}) -SourceRoot $coverageSource -ReportDirectory (Join-Path $fixture 'ci_report')
Assert ($global:localGoCalls -eq 2) 'CI container runs Go tests without invoking the coverage collector'
function go.exe {$global:LASTEXITCODE=23}
Refuse {Invoke-ContainerGoTestPhase -Plan ([pscustomobject]@{Mode='CIActual'}) -SourceRoot $coverageSource -ReportDirectory (Join-Path $fixture 'ci_report')} 'CI container rejects failed Go tests'
Remove-Item Function:/go.exe
