#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$parent=Join-Path $env:TEMP ('issue201_pair_'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $parent|Out-Null
$sha='a'*40
function gh {
 $a=@($args);$global:LASTEXITCODE=0
 if($a[0] -ceq 'api' -and $a -contains '--paginate' -and $a[2] -like '*/releases?*'){return}
 if($a[0] -ceq 'api' -and $a[1] -like '*/commits/main'){return $sha}
 if($a[0] -ceq 'api' -and $a -contains '--paginate' -and $a[2] -like '*/actions/runs/42/artifacts?*'){
  $items=@(@{id=456;name='windows-test-reports-42-2';digest=('sha256:'+('a'*64));expired=$false})
  if($global:containerMode -in @('valid','wrongrun')){$items+=@{id=457;name='docker-test-reports-42-2';digest=('sha256:'+('b'*64));expired=$false}}
  if($global:containerMode -eq 'wrong'){$items+=@{id=457;name='docker-test-reports-42-1';digest=('sha256:'+('b'*64));expired=$false}}
  if($global:containerMode -eq 'duplicate'){$items+=@(@{id=457;name='docker-test-reports-42-2';digest=('sha256:'+('b'*64));expired=$false},@{id=458;name='docker-test-reports-42-2';digest=('sha256:'+('b'*64));expired=$false})}
  return @($items|ForEach-Object {$_|ConvertTo-Json -Compress})
 }
 if($a[0] -ceq 'api' -and $a[1] -like '*/actions/runs/42'){return (@{id=42;head_sha=$sha;head_branch='main';event='workflow_dispatch';run_attempt=2}|ConvertTo-Json -Compress)}
 throw 'unexpected mock gh request'
}
$oldTool=$env:WINDOWS_SETUP_ARTIFACT_DOWNLOAD_TOOL
$env:WINDOWS_SETUP_ARTIFACT_DOWNLOAD_TOOL='Invoke-OverviewArtifactFixture'
function Invoke-OverviewArtifactFixture {
 $a=@($args);$id=$a[[Array]::IndexOf($a,'--id')+1];$dir=$a[[Array]::IndexOf($a,'--dest')+1]
 $isNative=$id -ceq '456'
 $expected=if($isNative){@('--repo','example/repo','--run','42','--attempt','2','--id','456','--digest',('sha256:'+('a'*64)),'--dest',$dir)}else{@('--repo','example/repo','--run','42','--attempt','2','--id','457','--digest',('sha256:'+('b'*64)),'--kind','container','--dest',$dir)}
 if(($a -join '|') -cne ($expected -join '|') -or -not $dir.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $dir -Leaf) -cne $(if($isNative){'main'}else{'windows_container'})){throw 'unexpected artifact identity'}
 New-Item -ItemType Directory -Path $dir|Out-Null
 $url=if($global:containerMode -eq 'wrongrun' -and -not $isNative){'https://github.com/example/repo/actions/runs/43'}else{'https://github.com/example/repo/actions/runs/42'}
 [IO.File]::WriteAllText((Join-Path $dir 'summary.json'),('{"Commit":"'+$sha+'","RunUrl":"'+$url+'"}'))
 $global:LASTEXITCODE=0
}
foreach($mode in @('valid','missing','wrong','duplicate','wrongrun')){
 $global:containerMode=$mode;$ok=$true
 try{$result=& (Join-Path $root 'script/report/get_portal_inputs.ps1') -Repository example/repo -OutputDirectory (Join-Path $parent $mode) -MainRunId 42 -ExpectedMainEvent workflow_dispatch -ExpectedMainAttempt 2;if(-not(Test-Path -LiteralPath $result.ContainerSnapshotPath -PathType Leaf)){$ok=$false}}catch{$ok=$false}
 if($ok -ne ($mode -eq 'valid')){throw ('same-run container selection failed: '+$mode)}
 Write-Host ('@@ASSERT@@'+(@{Name=('same-run '+$mode);Passed=$true}|ConvertTo-Json -Compress))
}
$env:WINDOWS_SETUP_ARTIFACT_DOWNLOAD_TOOL=$oldTool
Remove-Item Function:\Invoke-OverviewArtifactFixture
Remove-Item Function:\gh
