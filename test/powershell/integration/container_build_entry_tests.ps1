#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Message){Write-Host ('@@ASSERT@@'+(@{Name=$Message;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Message}}
$fixture=Join-Path $env:TEMP ('docker_entry_'+[guid]::NewGuid().ToString('N'));$source=Join-Path $fixture 'source'
[void][IO.Directory]::CreateDirectory((Join-Path $source '.git'))
$sourceItem=Get-Item -LiteralPath $source -ErrorAction Stop
$source=$sourceItem.FullName
Assert ($sourceItem -is [IO.DirectoryInfo] -and $source -ceq $sourceItem.FullName) 'owned fixture uses the real existing directory name before passing source to a child process'
$otherSource=Join-Path $fixture 'sibling/source';[void][IO.Directory]::CreateDirectory($otherSource);$otherSource=(Get-Item -LiteralPath $otherSource -ErrorAction Stop).FullName
Assert ((Split-Path -Leaf $otherSource) -ceq (Split-Path -Leaf $source) -and $otherSource -cne $source) 'source rejection fixture is another existing directory with the same leaf name'
foreach($file in @('dockerfile/windows_tests.dockerfile','script/docker/download_library.ps1','script/docker/install_min_git.ps1','script/docker/install_go.ps1','script/docker/install_managed_tools.ps1','script/docker/container_test.ps1','script/docker/container_health.ps1','script/docker/docker.ps1','script/docker/library.ps1','script/test/ci_tasks.ps1','.dockerignore','compose.yaml')){
 $target=Join-Path $source $file;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));Copy-Item -LiteralPath (Join-Path $root $file) -Destination $target
}
$runner=Join-Path $fixture 'runner.ps1'
$program=@'
param($Entry,$Action,$Receipt,$Reports,$Log,$Mode,$OtherSource)
$ErrorActionPreference='Stop'
function git.exe {$global:LASTEXITCODE=0;return ('a'*40)}
function docker.exe {
 $words=@($args);$runtime=$null
 if($words -contains '--file'){$file=$words[[Array]::IndexOf($words,'--file')+1];if([IO.Path]::GetExtension($file) -eq '.json'){$runtime=[IO.File]::ReadAllText($file)|ConvertFrom-Json}}
 [IO.File]::AppendAllText($Log,((@{Args=$words;Image=$env:WINDOWS_SETUP_IMAGE;Runtime=$runtime}|ConvertTo-Json -Depth 20 -Compress)+"`n"));$global:LASTEXITCODE=0
 # Docker's official Compose v2.40.3 parser rejects this up-only flag on run.
 if($words -contains '--no-build'){$global:LASTEXITCODE=125;return}
 if($words[0] -eq 'info'){return '{"OSType":"windows"}'}
 if($words[0] -eq 'image'){
  if($Mode -eq 'inspect-fail'){$global:LASTEXITCODE=18;return}
  return (@{Id=('sha256:'+('b'*64));RepoTags=@($env:WINDOWS_SETUP_IMAGE)}|ConvertTo-Json -Compress)
 }
 if($words -contains 'config'){
  if($runtime){
   switch($Mode){
    config-build{$runtime.services.tools|Add-Member build @{context='unexpected'}}
    config-source{$runtime.services.tools.volumes[0].read_only=$false}
    config-source-path{$runtime.services.tools.volumes[0].source=$OtherSource}
    config-command{$runtime.services.tools.command[0]='cmd.exe'}
    config-isolation{$runtime.services.tools.isolation='hyperv'}
    config-image{$runtime.services.tools.image='sha256:'+('f'*64)}
   }
   return ($runtime|ConvertTo-Json -Depth 20 -Compress)
  }
  return (@{services=@{tools=@{image=$env:WINDOWS_SETUP_IMAGE;isolation='process';network_mode='none';command=@('powershell.exe','-File','C:/tools/container_test.ps1');volumes=@(@{type='bind';source=$env:WINDOWS_SETUP_SOURCE;target='C:/workspace';read_only=$true},@{type='bind';source=$env:WINDOWS_SETUP_REPORTS;target='C:/reports';read_only=$false});build=@{isolation='process'}}}}|ConvertTo-Json -Depth 10 -Compress)
 }
 if($words -contains 'build' -and $Mode -eq 'build-fail'){$global:LASTEXITCODE=37}
 if($words -contains 'run' -and $Mode -eq 'run-fail'){$global:LASTEXITCODE=29}
}
& $Entry -Action $Action -BuildReceiptPath $Receipt -ReportDirectory $Reports -Isolation process
exit $LASTEXITCODE
'@
[IO.File]::WriteAllText($runner,$program,[Text.UTF8Encoding]::new($true))
$entry=Join-Path $source 'script/docker/docker.ps1';$receipt=Join-Path $fixture 'built.json';$log=Join-Path $fixture 'calls.jsonl'
function Run([string]$Action,[string]$Mode,[string]$ReceiptPath=$receipt){
 $reports=Join-Path $fixture ([guid]::NewGuid().ToString('N'))
 $old=$ErrorActionPreference
 try{$ErrorActionPreference='Continue';& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Entry $entry -Action $Action -Receipt $ReceiptPath -Reports $reports -Log $log -Mode $Mode -OtherSource $otherSource *> (Join-Path $fixture 'last.log');$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
 return $code
}
Assert ((Run build valid) -eq 0 -and (Test-Path -LiteralPath $receipt)) 'actual build entry writes its receipt only after successful native Docker build'
[IO.File]::WriteAllText($log,'')
Assert ((Run test-built valid) -eq 0) 'actual test-built entry executes complete container route'
$calls=@(Get-Content $log|ForEach-Object {$_|ConvertFrom-Json});$runs=@($calls|Where-Object {$_.Args -ccontains 'run'})
Assert ($runs.Count -eq 1 -and @($calls|Where-Object {$_.Args -ccontains 'build'}).Count -eq 0 -and $runs[0].Image -ceq ('sha256:'+('b'*64)) -and $runs[0].Args -cnotcontains '--no-build' -and $runs[0].Args -ccontains '--pull' -and $runs[0].Args -ccontains 'never' -and $runs[0].Runtime -and $runs[0].Runtime.services.tools.PSObject.Properties.Name -cnotcontains 'build') 'test phase uses supported CLI flags and a build-free manifest pinned to the inspected immutable ID'
Assert ($runs[0].Runtime.services.tools.volumes[0].read_only -eq $true -and $runs[0].Runtime.services.tools.volumes[0].source -ceq $source -and $runs[0].Runtime.services.tools.isolation -ceq 'process' -and $runs[0].Runtime.services.tools.network_mode -ceq 'none' -and $runs[0].Runtime.services.tools.command[0] -ceq 'powershell.exe') 'build-free runtime manifest preserves original read-only source, isolation, network and full-test command'
Assert (-not(Test-Path -LiteralPath $runs[0].Args[[Array]::IndexOf($runs[0].Args,'--file')+1])) 'private runtime manifest is removed after actual process completion'
foreach($mode in @('missing','inspect-fail','run-fail','config-build','config-source','config-source-path','config-command','config-isolation','config-image')){
 [IO.File]::WriteAllText($log,'');$path=if($mode -eq 'missing'){Join-Path $fixture 'absent.json'}else{$receipt}
 $code=Run test-built $mode $path;$calls=@(Get-Content $log|ForEach-Object {$_|ConvertFrom-Json});$runs=@($calls|Where-Object {$_.Args -ccontains 'run'})
 if($mode -eq 'run-fail'){Assert ($code -eq 29 -and $runs.Count -eq 1) 'actual native test failure retains its exact nonzero process exit'}
 else{Assert ($code -ne 0 -and $runs.Count -eq 0 -and @($calls|Where-Object {$_.Args -ccontains 'build'}).Count -eq 0) ('invalid prerequisite never runs or rebuilds the image: '+$mode)}
 foreach($configCall in @($calls|Where-Object {$_.Runtime})){
  Assert (-not(Test-Path -LiteralPath $configCall.Args[[Array]::IndexOf($configCall.Args,'--file')+1])) ('private runtime file is cleaned on success and failure: '+$mode)
 }
}
$failedReceipt=Join-Path $fixture 'failed.json'
Assert ((Run build build-fail $failedReceipt) -eq 37 -and -not(Test-Path $failedReceipt)) 'failed native build cannot emit a successful receipt'
