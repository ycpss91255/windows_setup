#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
$sha='a'*40;$parent=Join-Path $env:TEMP ('manual_portal_source_'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $parent|Out-Null
function gh {
 $argsList=@($args);$global:LASTEXITCODE=0
 if($argsList[0] -ceq 'api' -and $argsList -contains '--paginate' -and $argsList[2] -like '*/releases?*'){return}
 if($argsList[0] -ceq 'api' -and $argsList[1] -like '*/commits/main'){return $sha}
 if($argsList[0] -ceq 'api' -and $argsList -contains '--paginate' -and $argsList[2] -like '*/actions/runs/42/artifacts?*'){
  return @((@{id=456;name=('windows-test-reports-42-'+$global:artifactAttempt);digest=('sha256:'+('a'*64));expired=$false}|ConvertTo-Json -Compress),(@{id=457;name=('docker-test-reports-42-'+$global:artifactAttempt);digest=('sha256:'+('b'*64));expired=$false}|ConvertTo-Json -Compress))
 }
 if($argsList[0] -ceq 'api' -and $argsList[1] -like '*/actions/runs/42'){
  return (@{id=$global:runId;head_sha=$global:runSha;head_branch=$global:runBranch;event=$global:runEvent;run_attempt=$global:runAttempt}|ConvertTo-Json -Compress)
 }
 if($argsList[0] -ceq 'run' -and $argsList[1] -ceq 'download'){
  $dir=$argsList[[Array]::IndexOf($argsList,'--dir')+1];[IO.File]::WriteAllText((Join-Path $dir 'summary.json'),('{"Commit":"'+$sha+'","RunUrl":"https://github.com/example/repo/actions/runs/42"}'));return
 }
 throw ('unexpected mock gh request')
}
function mock_artifact_download {
 $arguments=@($args);$dir=$arguments[[Array]::IndexOf($arguments,'--dest')+1];New-Item -ItemType Directory $dir|Out-Null;[IO.File]::WriteAllText((Join-Path $dir 'summary.json'),('{"Commit":"'+$sha+'","RunUrl":"https://github.com/example/repo/actions/runs/42"}'));$global:LASTEXITCODE=0
}
$oldHelper=$env:WINDOWS_SETUP_ARTIFACT_DOWNLOAD_TOOL;$env:WINDOWS_SETUP_ARTIFACT_DOWNLOAD_TOOL='mock_artifact_download'
foreach($case in @(
 @{Name='dispatch main';Event='workflow_dispatch';Branch='main';Sha=$sha;Attempt=2;Artifact=2;Expected=$true},
 @{Name='wrong event';Event='push';Branch='main';Sha=$sha;Attempt=2;Artifact=2;Expected=$false},
 @{Name='wrong branch';Event='workflow_dispatch';Branch='feature';Sha=$sha;Attempt=2;Artifact=2;Expected=$false},
 @{Name='wrong sha';Event='workflow_dispatch';Branch='main';Sha=('b'*40);Attempt=2;Artifact=2;Expected=$false},
 @{Name='wrong run';Event='workflow_dispatch';Branch='main';Sha=$sha;Attempt=2;Artifact=2;RunId=43;Expected=$false},
 @{Name='wrong attempt';Event='workflow_dispatch';Branch='main';Sha=$sha;Attempt=1;Artifact=1;Expected=$false},
 @{Name='wrong artifact attempt';Event='workflow_dispatch';Branch='main';Sha=$sha;Attempt=2;Artifact=1;Expected=$false}
)){
 $global:runEvent=$case.Event;$global:runBranch=$case.Branch;$global:runSha=$case.Sha;$global:runAttempt=$case.Attempt;$global:artifactAttempt=$case.Artifact;$global:runId=if($case.ContainsKey('RunId')){$case.RunId}else{42}
 $ok=$true;try{$result=& (Join-Path $root 'script/report/get_portal_inputs.ps1') -Repository example/repo -OutputDirectory (Join-Path $parent $case.Name) -MainRunId 42 -ExpectedMainEvent workflow_dispatch -ExpectedMainAttempt 2; if(-not (Test-Path -LiteralPath $result.MainSnapshotPath -PathType Leaf)){$ok=$false}}catch{$ok=$false;Write-Host ('fixture: '+$_.Exception.Message)}
 Assert ($ok -eq $case.Expected) ('同次 main 恢復來源 '+$case.Name)
}
$env:WINDOWS_SETUP_ARTIFACT_DOWNLOAD_TOOL=$oldHelper
Remove-Item Function:\mock_artifact_download
Remove-Item Function:\gh
