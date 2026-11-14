#Requires -Version 5.1
function Invoke-CIContainerHealthVerification {
 param(
  [Parameter(Mandatory=$true)][ValidatePattern('^sha256:[0-9a-f]{64}$')][string]$ImageId,
  [scriptblock]$InvokeNative={param($File,$Arguments,$TimeoutMilliseconds,$InitialHostedProbe) Invoke-RunnerBoundedProcess -File $File -Arguments $Arguments -TimeoutMilliseconds $TimeoutMilliseconds -InitialHostedProbe $InitialHostedProbe},
  [scriptblock]$Sleep={param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds},
  [ValidateRange(30000,240000)][int]$DeadlineMilliseconds=180000
 )
 $watch=[Diagnostics.Stopwatch]::StartNew();$cleanupReserve=20000
 $call={param([string[]]$Arguments,[bool]$Cleanup=$false)
  $remaining=$DeadlineMilliseconds-[int]$watch.ElapsedMilliseconds
  if(-not $Cleanup){$remaining-=$cleanupReserve}
  if($remaining -lt 1000){throw 'Health verification deadline exceeded.'}
  $result=& $InvokeNative 'docker.exe' $Arguments ([Math]::Min(10000,$remaining)) $false
  if($result.ExitCode -ne 0){throw ('Docker health verification failed: '+$Arguments[0])}
  return [string]$result.Output
 }
 $config=(& $call @('image','inspect','--format','{{json .Config.Healthcheck}}',$ImageId))|ConvertFrom-Json
 if($config.Interval -ne 30000000000 -or $config.Timeout -ne 10000000000 -or $config.Retries -ne 3){throw 'Unexpected image health configuration.'}
 foreach($kind in @('healthy','timeout')) {
  $owner=[guid]::NewGuid().ToString('N');$name='windows-setup-health-'+$owner;$id=$null;$createAttempted=$false
  try {
   $create=@('create','--name',$name,'--label',('windows-setup.health-owner='+$owner),'--network','none','--isolation','process','--entrypoint','powershell.exe')
   if($kind -eq 'timeout'){$create+=@('--health-cmd','powershell.exe -NoLogo -NoProfile -Command Start-Sleep -Seconds 30','--health-interval','1s','--health-timeout','10s','--health-retries','1')}
   $create+=@($ImageId,'-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 300')
   $createAttempted=$true;$id=(& $call $create).Trim()
   if($id -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid created container ID.'}
   $null=& $call @('start',$id)
   while($true){
    $item=(& $call @('inspect',$id))|ConvertFrom-Json
    if($item.Id -cne $id -or $item.Image -cne $ImageId -or $item.Config.Labels.'windows-setup.health-owner' -cne $owner -or -not $item.State.Running){throw 'Health fixture identity or state mismatch.'}
    $status=$item.State.Health.Status
    if($kind -eq 'healthy' -and $status -ceq 'healthy'){break}
    if($kind -eq 'timeout' -and $status -ceq 'unhealthy'){
     $logs=@($item.State.Health.Log)
     if(-not @($logs|Where-Object {$_.ExitCode -eq -1 -and $_.Output -match 'Health check exceeded timeout'}).Count){throw 'Unhealthy fixture lacks timeout evidence.'}
     break
    }
    if($status -notin @('starting','healthy')){throw 'Unexpected health status.'}
    & $Sleep 1000
   }
  } finally {
   if($createAttempted){
    # Even an interrupted create can leave a container; inspect its unique name.
    try{$item=(& $call @('inspect',$name) $true)|ConvertFrom-Json}catch{throw 'Unable to inspect owned health fixture for cleanup.'}
    if($item.Id -cnotmatch '^[0-9a-f]{64}$' -or ($id -and $item.Id -cne $id) -or $item.Image -cne $ImageId -or $item.Config.Labels.'windows-setup.health-owner' -cne $owner){throw 'Health fixture cleanup identity mismatch.'}
    $null=& $call @('rm','--force',$item.Id) $true
   }
  }
 }
}
