#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$parent=Join-Path ([IO.Path]::GetTempPath()) ('portal_retry_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $parent|Out-Null
$oldTool=$env:WINDOWS_SETUP_ARTIFACT_DOWNLOAD_TOOL
$env:WINDOWS_SETUP_ARTIFACT_DOWNLOAD_TOOL='Invoke-ArtifactFixture'
$global:portalRetryDownloadCalls=0
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
function global:gh {
 $global:LASTEXITCODE=0
 $vector=$args -join ' '
 if($vector -like '*releases?per_page=100*'){return}
 if($vector -like 'api repos/example/repo/commits/main*'){return 'abc'}
 if($vector -like 'api --paginate repos/example/repo/actions/runs/123/artifacts*'){
  $container='{"id":457,"name":"docker-test-reports-123-1","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","expired":false}'
  $row='{"id":456,"name":"windows-test-reports-123-1","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","expired":false}'
  # gh --paginate emits each page's selected objects as consecutive JSON lines.
  $firstPage=@(1..100|ForEach-Object {'{"id":1,"name":"unrelated","expired":false}'})
  if($global:portalRetryDuplicate){return @($row)+$firstPage+@($row)}
  if($global:portalRetryDuplicateContainer){return @($row,$container)+$firstPage+@($container)}
  if($global:portalRetryExpiredContainer){$container=$container.Replace('"expired":false','"expired":true')}
  return $firstPage+@($row,$container)
 }
 if($vector -like 'api repos/example/repo/actions/runs/123*'){return '{"id":123,"run_attempt":1,"head_sha":"abc","head_branch":"main","event":"push"}'}
 throw "Unexpected gh command: $vector"
}
function global:Invoke-ArtifactFixture {
 $global:portalRetryDownloadCalls++
 $values=@($args);$id=$values[[Array]::IndexOf($values,'--id')+1];$dest=$values[[Array]::IndexOf($values,'--dest')+1]
 $isNative=$id -ceq '456'
 $expected=if($isNative){@('--repo','example/repo','--run','123','--attempt','1','--id','456','--digest',('sha256:'+('a'*64)),'--dest',$dest)}else{@('--repo','example/repo','--run','123','--attempt','1','--id','457','--digest',('sha256:'+('b'*64)),'--kind','container','--dest',$dest)}
 if(($values -join '|') -cne ($expected -join '|') -or -not $dest.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $dest -Leaf) -cne $(if($isNative){'main'}else{'windows_container'})){throw 'Artifact identity was not passed intact'}
 New-Item -ItemType Directory -Path $dest|Out-Null
 [IO.File]::WriteAllText((Join-Path $dest 'summary.json'),'{"Commit":"abc","RunUrl":"https://github.com/example/repo/actions/runs/123"}')
 $global:LASTEXITCODE=0
}
try {
 & (Join-Path $root 'script/report/get_portal_inputs.ps1') -Repository 'example/repo' -OutputDirectory (Join-Path $parent 'out') -MainRunId 123|Out-Null
 Assert ($global:portalRetryDownloadCalls -eq 2) '第二頁兩環境工件經有界下載並傳遞身分'
 $global:portalRetryDuplicate=$true
 $rejected=$false
 try {& (Join-Path $root 'script/report/get_portal_inputs.ps1') -Repository 'example/repo' -OutputDirectory (Join-Path $parent 'duplicate') -MainRunId 123|Out-Null} catch {$rejected=$true}
 Assert ($rejected -and $global:portalRetryDownloadCalls -eq 2) '跨頁重複工件下載前拒絕'
 $global:portalRetryDuplicate=$false
 foreach($case in @('portalRetryDuplicateContainer','portalRetryExpiredContainer')){
  Set-Variable -Name $case -Value $true -Scope Global
  $before=$global:portalRetryDownloadCalls;$rejected=$false
  try {& (Join-Path $root 'script/report/get_portal_inputs.ps1') -Repository 'example/repo' -OutputDirectory (Join-Path $parent $case) -MainRunId 123|Out-Null} catch {$rejected=$true}
  Assert ($rejected -and $global:portalRetryDownloadCalls -eq ($before+1)) ('拒絕容器重複或過期 '+$case)
  Set-Variable -Name $case -Value $false -Scope Global
 }

} finally {
 $env:WINDOWS_SETUP_ARTIFACT_DOWNLOAD_TOOL=$oldTool
 Remove-Variable portalRetryDuplicate,portalRetryDuplicateContainer,portalRetryExpiredContainer,portalRetryDownloadCalls -Scope Global -ErrorAction SilentlyContinue
 Remove-Item function:global:gh,function:global:Invoke-ArtifactFixture -ErrorAction SilentlyContinue
 Remove-Item -LiteralPath $parent -Recurse -Force
}
