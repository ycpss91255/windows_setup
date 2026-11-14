#Requires -Version 5.1
[CmdletBinding()]
param([string]$SourceRoot,[string]$OutputDirectory,[string]$PrivateDirectory,[int]$ShardIndex,[ValidateRange(1,4)][int]$ShardCount=4,[string]$Commit,[string]$RunUrl,[ValidateRange(1,2147483647)][int]$RunAttempt=1,[string]$CoverageToolPath)
. (Join-Path $PSScriptRoot 'ci_tasks.ps1')
function Invoke-PowerShellCoverageShard {
 [CmdletBinding()]
 param([Parameter(Mandatory=$true)][string]$SourceRoot,[Parameter(Mandatory=$true)][string]$OutputDirectory,[Parameter(Mandatory=$true)][string]$PrivateDirectory,[Parameter(Mandatory=$true)][int]$ShardIndex,[ValidateRange(1,4)][int]$ShardCount=4,[Parameter(Mandatory=$true)][string]$Commit,[Parameter(Mandatory=$true)][string]$RunUrl,[ValidateRange(1,2147483647)][int]$RunAttempt=1,[string]$CoverageToolPath)
$ErrorActionPreference='Stop'
$source=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\','/')
$output=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\','/')
$private=[IO.Path]::GetFullPath($PrivateDirectory).TrimEnd('\','/')
if($ShardIndex -lt 0 -or $ShardIndex -ge $ShardCount){throw '分片索引超出完整分片範圍。'}
foreach($path in @($output,$private)){
 if($path -ieq $source -or $path.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $path)){throw '分片產物必須使用來源外部全新目錄。'}
}
if($output -ieq $private -or $output.StartsWith($private+'\',[StringComparison]::OrdinalIgnoreCase) -or $private.StartsWith($output+'\',[StringComparison]::OrdinalIgnoreCase)){throw '安全證據與私有量測目錄必須分離。'}
[void][IO.Directory]::CreateDirectory($private)
if(-not $CoverageToolPath){
 $CoverageToolPath=Join-Path $private 'repo_coverage_tool.exe'
 Push-Location ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')))
 try{Invoke-CINative -File go.exe -Arguments @('build','-mod=vendor','-o',$CoverageToolPath,'./script/test/repo_coverage_tool')}finally{Pop-Location}
}
$manifest=Join-Path $private 'canonical_manifest.json'
Invoke-CINative -File powershell.exe -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot '../../test/powershell/coverage/create_baseline_manifest.ps1'),'-SourceRoot',$source,'-OutputPath',$manifest,'-Runtime')
$identity=@('--runtime','--source-root',$source,'--manifest',$manifest,'--expected-sha',$Commit,'--expected-run-url',$RunUrl,'--run-attempt',$RunAttempt.ToString(),'--shard-index',$ShardIndex.ToString(),'--shard-count',$ShardCount.ToString())
$plan=Join-Path $private 'plan'
Invoke-CINative -File $CoverageToolPath -Arguments (@('powershell-shard-plan','--output-dir',$plan)+$identity)
$evidence=Join-Path $private 'collector'
Invoke-CINative -File powershell.exe -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'powershell_coverage.ps1'),'-ManifestPath',(Join-Path $plan 'privatecollection_manifest.json'),'-OutputDirectory',$evidence,'-ThrottleLimit','2')
Invoke-CINative -File $CoverageToolPath -Arguments @('export-powershell','--runtime','--source-root',$source,'--evidence-dir',$evidence,'--output-dir',$output)
Invoke-CINative -File $CoverageToolPath -Arguments (@('powershell-shard-pack','--evidence-dir',$output)+$identity)
Write-Host ('已完成保真原生PowerShell分片 '+$ShardIndex+'/'+$ShardCount+'；公開目錄只保留已驗證的相對路徑證據。')
$global:LASTEXITCODE=0

}
if($MyInvocation.InvocationName -ne '.') {Invoke-PowerShellCoverageShard @PSBoundParameters}
