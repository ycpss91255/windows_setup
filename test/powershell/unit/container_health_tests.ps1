#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Name}}
. (Join-Path $root 'script/docker/container_health.ps1')
. (Join-Path $root 'script/test/ci_tasks.ps1')
$script:called=0
function Assert-CIRequiredTools {param([switch]$Managed) $script:called++;if(-not $Managed){throw 'managed tool check required'}}
Assert (Test-ContainerToolHealth) 'successful tool responses yield healthy'
Assert ($script:called -eq 1) 'probe checks all managed prerequisites'
function Assert-CIRequiredTools {param([switch]$Managed) if(-not $Managed){throw 'managed tool check required'}}
$temp=Join-Path $env:TEMP ('health_cmd_'+[guid]::NewGuid().ToString('N'))
$oldPath=$env:PATH
try {
 [void][IO.Directory]::CreateDirectory($temp)
 $good=Join-Path $temp 'good';$bad=Join-Path $temp 'bad'
 [void][IO.Directory]::CreateDirectory($good);[void][IO.Directory]::CreateDirectory($bad)
 Add-Type -TypeDefinition 'public class Fixture { public static int Main() { return 0; } }' -OutputAssembly (Join-Path $good 'cmd.exe') -OutputType ConsoleApplication
 Add-Type -TypeDefinition 'public class Fixture { public static int Main() { return 7; } }' -OutputAssembly (Join-Path $bad 'cmd.exe') -OutputType ConsoleApplication
 $env:PATH=$good+';'+$oldPath
 Assert (Test-ContainerToolHealth) 'responsive cmd executable yields healthy'
 $env:PATH=$bad+';'+$oldPath
 & (Join-Path $bad 'cmd.exe')
 Assert ($LASTEXITCODE -eq 7) 'controlled cmd executable actually returns seven'
 Assert (-not (Test-ContainerToolHealth)) 'cmd executable returning seven yields unhealthy'
} finally {
 $env:PATH=$oldPath
 Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
function Assert-CIRequiredTools {param([switch]$Managed) throw 'tool failed to respond'}
Assert (-not (Test-ContainerToolHealth)) 'failed tool response yields unhealthy'
$docker=[IO.File]::ReadAllText((Join-Path $root 'dockerfile/windows_tests.dockerfile'))
$ignore=[IO.File]::ReadAllText((Join-Path $root '.dockerignore'))
Assert ($docker -match '(?m)^HEALTHCHECK --interval=30s --timeout=10s --retries=3 CMD ' -and $docker.Contains('Test-ContainerToolHealth') -and $docker.Contains('exit 1')) 'bounded Docker health check propagates failures'
Assert ($docker.Contains('COPY script/docker/container_health.ps1 C:/tools/container_health.ps1') -and $ignore.Contains('!script/docker/container_health.ps1')) 'probe is included in image build context'
Assert ($docker.Contains('"-File", "C:/tools/container_test.ps1"')) 'test command and its exit status remain unchanged'
