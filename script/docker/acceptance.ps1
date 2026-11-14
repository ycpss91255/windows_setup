#Requires -Version 5.1
function Get-ContainerAcceptancePlan {
 param([string]$ReportDirectory,[string]$FixtureDirectory,[string]$Commit=$env:GITHUB_SHA,[string]$Repository=$env:GITHUB_REPOSITORY,[string]$RunId=$env:GITHUB_RUN_ID,[string]$RefType=$env:GITHUB_REF_TYPE,[string]$RefName=$env:GITHUB_REF_NAME)
 $parts=@($Commit,$Repository,$RunId,$RefType,$RefName|Where-Object {$_})
 if($parts.Count -eq 0){return [pscustomobject]@{Mode='LocalSynthetic';ArtifactDirectory=(Join-Path $FixtureDirectory 'synthetic_snapshot');Commit=('f'*40);RunUrl='https://github.com/example/fixture/actions/runs/1'}}
 if($parts.Count -ne 5 -or $RefType -cnotin @('branch','tag') -or $Commit -notmatch '^[a-fA-F0-9]{40}$' -or $Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $RunId -notmatch '^[0-9]+$'){throw 'Incomplete or invalid CI provenance; refusing to downgrade to local synthetic mode.'}
 [pscustomobject]@{Mode='CIActual';ArtifactDirectory=(Join-Path $ReportDirectory 'public');Commit=$Commit;RunUrl=('https://github.com/'+$Repository+'/actions/runs/'+$RunId)}
}
function Invoke-ContainerGo {
 param([string[]]$Arguments)
 $preference=$ErrorActionPreference
 try{$ErrorActionPreference='Continue'; & go.exe @Arguments; $goExit=$LASTEXITCODE}finally{$ErrorActionPreference=$preference}
 if($goExit -ne 0){throw ('Go acceptance failed with exit code '+$goExit)}
}

function Initialize-ContainerGoEnvironment {
 param([Parameter(Mandatory=$true)][string]$SourceRoot,[Parameter(Mandatory=$true)][string]$CacheRoot)
 $source=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\','/')
 $cache=[IO.Path]::GetFullPath($CacheRoot).TrimEnd('\','/')
 if($cache -ieq $source -or $cache.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Go caches must stay outside the read-only source checkout.'}
 $settings=@{GOCACHE=(Join-Path $cache 'build');GOMODCACHE=(Join-Path $cache 'modules');GOPATH=(Join-Path $cache 'gopath');GOTMPDIR=(Join-Path $cache 'tmp')}
 foreach($key in $settings.Keys){New-Item -ItemType Directory -Path $settings[$key] -Force|Out-Null;[Environment]::SetEnvironmentVariable($key,$settings[$key],'Process')}
 foreach($entry in @{GOTOOLCHAIN='local';GOPROXY='off';GOSUMDB='off';GOFLAGS='-mod=vendor';CGO_ENABLED='0';GOWORK='off';GOENV='off'}.GetEnumerator()){[Environment]::SetEnvironmentVariable($entry.Key,$entry.Value,'Process')}
}
function Invoke-ContainerGoTestPhase {
 param($Plan,[string]$SourceRoot,[string]$ReportDirectory)
 if($Plan.Mode -cnotin @('LocalSynthetic','CIActual')){throw 'Unknown Go test mode.'}
 Invoke-ContainerGo -Arguments @('test','-count=1','./...')
}
