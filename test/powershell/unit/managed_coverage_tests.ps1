#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$script:count=0
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw ('FAIL: '+$Name)};$script:count++}
$producer=Join-Path $root 'script/test/managed_coverage.ps1'
Assert (Test-Path -LiteralPath $producer -PathType Leaf) 'managed collector has a real source-based producer'
. $producer
$pin=Get-ManagedCoverageToolPin
Assert ($pin.Id -eq 'Microsoft.dotnet-coverage' -and $pin.Version -eq '17.14.1' -and $pin.PackageSHA512 -eq 'hgzaG+c7LtKup6HZixvXtn3l4Pa8VK23bM9vLHveD3Iq2XlzLu7vqMZwtVjQdsof83wx5OzY0tpDh3+YRdOVjA==') 'native collector tool is pinned to the verified official package'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('managed_scope_'+[guid]::NewGuid().ToString('N'));$source=Join-Path $temp 'source';New-Item -ItemType Directory -Path (Join-Path $source 'modules/native') -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $source 'modules/native/example.cs'),'public static class Example{public static int Read(){return 1;}}')
New-Item -ItemType Directory -Path (Join-Path $source 'test/fixtures') -Force|Out-Null;[IO.File]::WriteAllText((Join-Path $source 'test/fixtures/fake.cs'),'test is not production')
$inventory=@(Get-ManagedSourceInventory -SourceRoot $source)
Assert ($inventory.Count -eq 1 -and $inventory[0].Path -eq 'modules/native/example.cs' -and $inventory[0].SHA256 -eq (Get-FileHash (Join-Path $source 'modules/native/example.cs')).Hash.ToLowerInvariant()) 'inventory includes actual production source and excludes explicit test tree'
New-Item -ItemType Directory -Path (Join-Path $source 'modules/demo/native'),(Join-Path $source 'script/test/native') -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $source 'modules/demo/native/real.cs'),'public class RuntimeExample {}')
[IO.File]::WriteAllText((Join-Path $source 'script/test/native/support.cs'),'public class SupportExample {}')
$runtimeInventory=@(Get-ManagedSourceInventory -SourceRoot $source -Runtime)
Assert ($runtimeInventory.Count -eq 1 -and $runtimeInventory[0].Path -ceq 'modules/demo/native/real.cs') 'runtime managed inventory excludes maintenance support and unapproved paths'
$rejected=$false;try{Assert-ManagedOutputLocation $source (Join-Path $source 'output')}catch{$rejected=$true}
Assert $rejected 'collector cannot generate artifacts inside reviewed source'
$rejected=$false;try{Assert-ManagedOutputLocation $source $temp}catch{$rejected=$true}
Assert $rejected 'collector refuses existing output to prevent mixed-run evidence'
$rejected=$false;try{Invoke-ManagedNative -FilePath $env:ComSpec -Arguments @('/d','/c','exit','/b','37') -LogPath (Join-Path $temp 'failure.log')}catch{$rejected=($_.Exception.Message -match '37')}
Assert $rejected 'native subprocess failure is not silently accepted'
$empty=Join-Path $temp 'empty';New-Item -ItemType Directory -Path $empty|Out-Null;$target=Join-Path $temp 'not-created';$rejected=$false
try{Invoke-ManagedCoverage -SourceRoot $empty -OutputDirectory $target}catch{$rejected=$true}
Assert ($rejected -and -not(Test-Path $target)) 'empty scope fails before output creation or tool installation'
# A supplied offline package is authoritative: corruption must never trigger a network fallback.
$cacheCase=Join-Path $temp 'cache_case';New-Item -ItemType Directory -Path $cacheCase|Out-Null
$package=Join-Path $temp 'invalid.nupkg';[IO.File]::WriteAllText($package,'synthetic corrupt fixture')
$previousPackage=$env:WINDOWS_SETUP_MANAGED_PACKAGE_PATH;$env:WINDOWS_SETUP_MANAGED_PACKAGE_PATH=$package;$script:downloaded=$false
function Invoke-WebRequest {param($Uri,$OutFile,[switch]$UseBasicParsing,$ErrorAction);$script:downloaded=$true;throw 'Unexpected network access for a supplied cache'}
try{
 $rejected=$false;try{Initialize-ManagedCoverageTool -OutputDirectory $cacheCase -DotnetPath 'not-executed.exe'|Out-Null}catch{$rejected=$_.Exception.Message -match 'SHA512'}
 Assert ($rejected -and -not $script:downloaded) 'invalid offline package is rejected by pin without downloading or executing tools'
}finally{$env:WINDOWS_SETUP_MANAGED_PACKAGE_PATH=$previousPackage}
Write-Host ('ALL PASS: '+$script:count+' managed producer scope/process assertions; no native OS APIs invoked')
