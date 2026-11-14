#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'script/docker/library.ps1')
function Assert([bool]$Condition,[string]$Message){Write-Host ('@@ASSERT@@'+(@{Name=$Message;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Message}}
function Refuse([scriptblock]$Action,[string]$Message){$failure=$null;try{& $Action|Out-Null}catch{$failure=$_};Assert ($null -ne $failure) $Message}
$fixture=Join-Path $env:TEMP ('docker_receipt_'+[guid]::NewGuid().ToString('N'))
$source=Join-Path $fixture 'source'
[void][IO.Directory]::CreateDirectory((Join-Path $source '.git'))
foreach($file in @('dockerfile/windows_tests.dockerfile','script/docker/download_library.ps1','script/docker/install_min_git.ps1','script/docker/install_go.ps1','script/docker/install_managed_tools.ps1','script/docker/container_test.ps1','script/docker/container_health.ps1','script/test/ci_tasks.ps1','.dockerignore','compose.yaml')){
 $target=Join-Path $source $file;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));Copy-Item -LiteralPath (Join-Path $root $file) -Destination $target
}
$context=Get-ContainerContext $source (Join-Path $fixture 'reports')
[IO.File]::AppendAllText((Join-Path $source 'script/docker/download_library.ps1'),"`r`n# changed input")
$changed=Get-ContainerContext $source (Join-Path $fixture 'reports')
Assert ($context.Image -cne $changed.Image) 'download helper is a real Docker COPY input and must change the content-addressed image'
$context=$changed
$script:commit='a'*40;$script:imageId='sha256:'+('b'*64)
function Get-ContainerSourceCommit {param($Root);return $script:commit}
function Invoke-ContainerDocker {param($Arguments);if(($Arguments[0..1] -join ' ') -cne 'image inspect'){throw 'no actual Docker calls are allowed'};return (@{Id=$script:imageId;RepoTags=@($context.Image)}|ConvertTo-Json -Compress)}
$receipt=Join-Path $fixture 'built.json'
Save-ContainerBuildReceipt -Context $context -Path $receipt
Assert ((Assert-ContainerBuildReceipt -Context $context -Path $receipt) -ceq $script:imageId) 'full-test phase reuses precisely the verified built image ID'
$saved=[IO.File]::ReadAllText($receipt)
foreach($change in @('commit','image','isolation','inputs','schema','missing','unknown','type')){
 [IO.File]::WriteAllText($receipt,$saved,[Text.UTF8Encoding]::new($false));$r=$saved|ConvertFrom-Json
 switch($change){
  commit{$script:commit='c'*40}
  image{$script:imageId='sha256:'+('d'*64)}
  isolation{$r.Isolation='hyperv'}
  inputs{$r.InputsSHA256='0'*64}
  schema{$r.SchemaVersion=2}
  missing{$r.PSObject.Properties.Remove('ImageId')}
  unknown{$r|Add-Member Unexpected 'not permitted'}
  type{$r.SchemaVersion='1'}
 }
 if($change -notin @('commit','image')){[IO.File]::WriteAllText($receipt,($r|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
 Refuse {Assert-ContainerBuildReceipt -Context $context -Path $receipt} ('stale or invalid build receipt blocks the full-test phase: '+$change)
 $script:commit='a'*40;$script:imageId='sha256:'+('b'*64)
}
[IO.File]::WriteAllText($receipt,$saved,[Text.UTF8Encoding]::new($false))
Refuse {Save-ContainerBuildReceipt -Context $context -Path $receipt} 'existing receipts are never overwritten by another build'
Refuse {Save-ContainerBuildReceipt -Context $context -Path (Join-Path $source 'receipt.json')} 'build receipt cannot dirty the source checkout'
Refuse {Assert-ContainerBuildReceipt -Context $context -Path (Join-Path $fixture 'missing.json')} 'missing build receipt cannot bypass the build phase'
$configuration=[pscustomobject]@{services=[pscustomobject]@{tools=[pscustomobject]@{image=$script:imageId;isolation=$context.Isolation;build=[pscustomobject]@{isolation=$context.Isolation};network_mode='none';command=@('powershell.exe','-File','C:/tools/container_test.ps1');environment=[pscustomobject]@{LITERAL='keep$unchanged'};volumes=@([pscustomobject]@{type='bind';source=$source;target='C:/workspace';read_only=$true})}}}
$runtime=New-ContainerRuntimeComposeFile -Context $context -Configuration $configuration -ImageId $script:imageId -Directory $fixture
$resolved=Get-Content -LiteralPath $runtime.Path -Raw|ConvertFrom-Json
Assert-ContainerRuntimeCompose -Configuration $resolved -ExpectedService $runtime.ExpectedService
Assert ($configuration.services.tools.PSObject.Properties.Name -ccontains 'build' -and $resolved.services.tools.PSObject.Properties.Name -cnotcontains 'build' -and $resolved.services.tools.environment.LITERAL -ceq 'keep$unchanged') 'private runtime copy removes only build and never mutates the original validated configuration'
foreach($bad in @('build','extra','missing','readonly','command','image','isolation')){
 $changed=[IO.File]::ReadAllText($runtime.Path)|ConvertFrom-Json
 switch($bad){
  build{$changed.services.tools|Add-Member build @{context='wrong'}}
  extra{$changed.services|Add-Member other @{image='unexpected'}}
  missing{$changed.services.tools.PSObject.Properties.Remove('command')}
  readonly{$changed.services.tools.volumes[0].read_only=$false}
  command{$changed.services.tools.command[0]='cmd.exe'}
  image{$changed.services.tools.image='sha256:'+('e'*64)}
  isolation{$changed.services.tools.isolation='hyperv'}
 }
 Refuse {Assert-ContainerRuntimeCompose -Configuration $changed -ExpectedService $runtime.ExpectedService} ('runtime resolution must preserve validated complete service: '+$bad)
}
Refuse {New-ContainerRuntimeComposeFile -Context $context -Configuration $configuration -ImageId 'mutable:tag' -Directory $fixture} 'runtime copy cannot use a mutable image tag'
Refuse {New-ContainerRuntimeComposeFile -Context $context -Configuration $configuration -ImageId $script:imageId -Directory $source} 'private runtime copy cannot be created in the source checkout'
function Invoke-ContainerDocker {param($Arguments);throw 'controlled inspect failure'}
Refuse {Assert-ContainerBuildReceipt -Context $context -Path $receipt} 'image inspection failure is never converted to a successful test'
