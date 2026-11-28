#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('doctor','build','test','test-built','shell')][string]$Action,[string]$ReportDirectory,[ValidateSet('process','hyperv')][string]$Isolation='process',[string]$BuildReceiptPath,[int]$ShardIndex=0,[int]$ShardCount=1)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'library.ps1')
$previous=@{}
$runtimePath=$null
try {
 # 分片在呼叫 docker 前先核對，避免無效分片被容器入口靜默改成完整或空白執行。
 if($ShardCount -lt 1 -or $ShardCount -gt 6 -or $ShardIndex -lt 0 -or $ShardIndex -ge $ShardCount){throw ('容器測試分片超出範圍：'+$ShardIndex+'/'+$ShardCount)}
 $context=Get-ContainerContext -Root (Join-Path $PSScriptRoot '../..') -ReportDirectory $ReportDirectory -Isolation $Isolation
 if(-not(Get-Command docker.exe -ErrorAction SilentlyContinue)){throw 'Docker is not installed or not on PATH. No host configuration was changed.'}
 $info=Invoke-ContainerDocker -Arguments @('info','--format','{{json .}}')
 $engine=($info -join "`n")|ConvertFrom-Json
 if($engine.OSType -cne 'windows'){throw 'A Windows container engine is required; this entry never switches the host engine.'}
 Invoke-ContainerDocker -Arguments @('version')
 Invoke-ContainerDocker -Arguments @('compose','version')
 if($Action -eq 'doctor'){Write-Host 'Windows Docker engine detected. This is a prerequisite check, not a test pass.';exit 0}
 $settings=@{WINDOWS_SETUP_SOURCE=$context.Root;WINDOWS_SETUP_REPORTS=$context.Reports;WINDOWS_SETUP_IMAGE=$context.Image;WINDOWS_SETUP_ISOLATION=$context.Isolation;WINDOWS_SETUP_SHARD_INDEX=$ShardIndex;WINDOWS_SETUP_SHARD_COUNT=$ShardCount}
 foreach($key in $settings.Keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$settings[$key],'Process')}
 $compose=@('compose','--project-name',$context.Project,'--file',(Join-Path $context.Root 'compose.yaml'))
 $configuration=(Invoke-ContainerDocker -Arguments ($compose+@('config','--format','json'))) -join "`n"
 Assert-ContainerCompose -Configuration ($configuration|ConvertFrom-Json) -Isolation $context.Isolation -Image $context.Image
 if($Action -eq 'test-built'){
  $imageId=Assert-ContainerBuildReceipt -Context $context -Path $BuildReceiptPath
  # Run the inspected immutable ID, never re-resolve a mutable tag or rebuild.
  [Environment]::SetEnvironmentVariable('WINDOWS_SETUP_IMAGE',$imageId,'Process')
  $lockedConfiguration=(Invoke-ContainerDocker -Arguments ($compose+@('config','--format','json'))) -join "`n"
  $runtime=New-ContainerRuntimeComposeFile -Context $context -Configuration ($lockedConfiguration|ConvertFrom-Json) -ImageId $imageId -Directory ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($BuildReceiptPath)))
  $runtimePath=$runtime.Path
  $compose=@('compose','--project-name',$context.Project,'--file',$runtimePath)
  $runtimeConfiguration=(Invoke-ContainerDocker -Arguments ($compose+@('config','--format','json'))) -join "`n"
  Assert-ContainerRuntimeCompose -Configuration ($runtimeConfiguration|ConvertFrom-Json) -ExpectedService $runtime.ExpectedService
 }
 else{Invoke-ContainerDocker -Arguments ($compose+@('build','--pull','tools'))}
 if($Action -eq 'build'){
  if($BuildReceiptPath){Save-ContainerBuildReceipt -Context $context -Path $BuildReceiptPath}
  Write-Host ('Built '+$context.Image);exit 0
 }
 if(Test-Path -LiteralPath $context.Reports){throw 'Report destination must be a new directory to avoid mixing runs.'}
 New-Item -ItemType Directory -Path $context.Reports|Out-Null
 Write-Host ('Container report directory: '+$context.Reports)
 if($Action -in @('test','test-built')){
  $run=@('run','--rm','--no-deps')
  if($Action -eq 'test-built'){$run+=@('--pull','never')}
  Invoke-ContainerDocker -Arguments ($compose+$run+@('-T','tools'))
 }else{
  Invoke-ContainerDocker -Arguments ($compose+@('run','--rm','--no-deps','tools','powershell.exe','-NoLogo','-NoProfile','-NoExit','-Command','git.exe config --global --add safe.directory C:/workspace; if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}; . C:/workspace/script/docker/acceptance.ps1; Initialize-ContainerGoEnvironment -SourceRoot C:/workspace -CacheRoot (Join-Path $env:TEMP (''container_go_''+[guid]::NewGuid().ToString(''N''))); Set-Location C:/workspace'))
 }
 exit 0
}catch{
 Write-Error $_ -ErrorAction Continue
 if($_.Exception.Data.Contains('ExitCode')){exit ([int]$_.Exception.Data['ExitCode'])}
 exit 1
}finally{
 if($runtimePath -and (Test-Path -LiteralPath $runtimePath)){Remove-Item -LiteralPath $runtimePath -Force}
 foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
}
