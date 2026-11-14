#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Name}}
. (Join-Path $root 'script/docker/container_health_ci.ps1')
$image='sha256:'+('a'*64)
$script:containers=@{};$script:removed=@();$script:created=@();$script:wrongOwner=$false;$script:badConfig=$false;$script:failStart=$false;$script:badLog=$false
$invoke={param($File,$Arguments,$TimeoutMilliseconds,$InitialHostedProbe)
 $a=@($Arguments);$out=''
 switch ($a[0]) {
  'image' {if($script:badConfig){$out='{"Interval":30000000000,"Timeout":9000000000,"Retries":3}'}else{$out='{"Interval":30000000000,"Timeout":10000000000,"Retries":3}'}}
  'create' {
   $id=('{0:x64}' -f ($script:created.Count+1));$name=$a[[array]::IndexOf($a,'--name')+1];$label=$a[[array]::IndexOf($a,'--label')+1].Split('=')[1]
   $bad=$a -contains '--health-cmd';$script:containers[$name]=@{Id=$id;Owner=$label;Bad=$bad};$script:created+=,@($a);$out=$id
  }
  'start' {if($script:failStart){throw [TimeoutException]::new('fixture native timeout')};$out=$a[1]}
  'inspect' {
   $c=@($script:containers.Values|Where-Object {$_.Id -eq $a[1]})[0];if(-not $c){$c=$script:containers[$a[1]]};if(-not $c){return @{ExitCode=1;Output=''}}
   $owner=if($script:wrongOwner){'someone-else'}else{$c.Owner}
   $status=if($c.Bad){'unhealthy'}else{'healthy'};$log=if($c.Bad){@(@{ExitCode=-1;Output='Health check exceeded timeout (10s)'})}else{@(@{ExitCode=0;Output=''})}
   if($c.Bad -and $script:badLog){$log=@(@{ExitCode=1;Output='ordinary failure'})}
   $out=@{Id=$c.Id;Image=$image;Config=@{Labels=@{'windows-setup.health-owner'=$owner}};State=@{Running=$true;Health=@{Status=$status;Log=$log}}}|ConvertTo-Json -Depth 8 -Compress
  }
  'rm' {$script:removed+=@($a[2]);$out=$a[2]}
  default {throw ('unexpected docker call '+($a -join ' '))}
 }
 return @{ExitCode=0;Output=$out}
}
Invoke-CIContainerHealthVerification -ImageId $image -InvokeNative $invoke -Sleep {param($Milliseconds)}
Assert ($script:created.Count -eq 2 -and $script:removed.Count -eq 2) 'healthy and timeout fixtures both cleaned by exact ID'
foreach($args in $script:created){Assert (($args -contains '--network') -and ($args[[array]::IndexOf($args,'--network')+1] -eq 'none') -and -not ($args -contains '--volume') -and ($args -contains $image)) 'fixtures use exact image without network or mounts'}
$bad=$script:created[1]
Assert (($bad -contains '--health-cmd') -and $bad[[array]::IndexOf($bad,'--health-timeout')+1] -eq '10s') 'timeout fixture uses real ten-second health timeout'
$script:wrongOwner=$true;$script:removed=@();$failed=$false
try{Invoke-CIContainerHealthVerification -ImageId $image -InvokeNative $invoke -Sleep {param($Milliseconds)}}catch{$failed=$true}
Assert ($failed -and $script:removed.Count -eq 0) 'owner mismatch fails closed without deleting container'

$script:wrongOwner=$false;$script:badConfig=$true;$before=$script:created.Count;$failed=$false
try{Invoke-CIContainerHealthVerification -ImageId $image -InvokeNative $invoke -Sleep {param($Milliseconds)}}catch{$failed=$true}
Assert ($failed -and $script:created.Count -eq $before) 'wrong image health configuration fails before creating fixtures'
$script:badConfig=$false;$script:failStart=$true;$script:removed=@();$failed=$false
try{Invoke-CIContainerHealthVerification -ImageId $image -InvokeNative $invoke -Sleep {param($Milliseconds)}}catch{$failed=$true}
Assert ($failed -and $script:removed.Count -eq 1) 'native timeout after creation still cleans owned fixture'
$script:failStart=$false;$script:badLog=$true;$script:removed=@();$failed=$false
try{Invoke-CIContainerHealthVerification -ImageId $image -InvokeNative $invoke -Sleep {param($Milliseconds)}}catch{$failed=$true}
Assert ($failed -and $script:removed.Count -eq 2) 'ordinary unhealthy result cannot masquerade as timeout'
