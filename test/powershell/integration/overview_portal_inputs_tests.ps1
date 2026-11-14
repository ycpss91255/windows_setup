#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$parent=Join-Path $env:TEMP ('issue201_pair_'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $parent|Out-Null
$sha='a'*40
function gh {
 $a=@($args);$global:LASTEXITCODE=0
 if($a[0] -ceq 'api' -and $a -contains '--paginate'){return}
 if($a[0] -ceq 'api' -and $a[1] -like '*/commits/main'){return $sha}
 if($a[0] -ceq 'api' -and $a[1] -like '*/actions/runs/42/artifacts'){
  $items=@(@{name='windows-test-reports-42-2';expired=$false})
  if($global:containerMode -in @('valid','wrongrun')){$items+=@{name='docker-test-reports-42-2';expired=$false}}
  if($global:containerMode -eq 'wrong'){$items+=@{name='docker-test-reports-42-1';expired=$false}}
  if($global:containerMode -eq 'duplicate'){$items+=@(@{name='docker-test-reports-42-2';expired=$false},@{name='docker-test-reports-42-2';expired=$false})}
  return (@{artifacts=$items}|ConvertTo-Json -Depth 5)
 }
 if($a[0] -ceq 'api' -and $a[1] -like '*/actions/runs/42'){return (@{id=42;head_sha=$sha;head_branch='main';event='workflow_dispatch';run_attempt=2}|ConvertTo-Json -Compress)}
 if($a[0] -ceq 'run' -and $a[1] -ceq 'download'){$dir=$a[[Array]::IndexOf($a,'--dir')+1];$url=if($global:containerMode -eq 'wrongrun' -and $dir -like '*windows_container'){ 'https://github.com/example/repo/actions/runs/43' }else{'https://github.com/example/repo/actions/runs/42'};[IO.File]::WriteAllText((Join-Path $dir 'summary.json'),('{"Commit":"'+$sha+'","RunUrl":"'+$url+'"}'));return}
 throw 'unexpected mock gh request'
}
foreach($mode in @('valid','missing','wrong','duplicate','wrongrun')){
 $global:containerMode=$mode;$ok=$true
 try{$result=& (Join-Path $root 'script/report/get_portal_inputs.ps1') -Repository example/repo -OutputDirectory (Join-Path $parent $mode) -MainRunId 42 -ExpectedMainEvent workflow_dispatch -ExpectedMainAttempt 2;if(-not(Test-Path -LiteralPath $result.ContainerSnapshotPath -PathType Leaf)){$ok=$false}}catch{$ok=$false}
 if($ok -ne ($mode -eq 'valid')){throw ('same-run container selection failed: '+$mode)}
 Write-Host ('@@ASSERT@@'+(@{Name=('same-run '+$mode);Passed=$true}|ConvertTo-Json -Compress))
}
Remove-Item Function:\gh
