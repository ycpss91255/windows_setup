#Requires -Version 5.1
param([Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,[Parameter(Mandatory=$true)][string]$OutputDirectory,[string]$MainRunId,[ValidateSet('push','workflow_dispatch')][string]$ExpectedMainEvent='push',[int]$ExpectedMainAttempt=0)
$ErrorActionPreference='Stop'
$out=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if(Test-Path -LiteralPath $out){throw '證據下載目錄必須不存在。'}
New-Item -ItemType Directory $out|Out-Null
$lines=& gh api --paginate ('repos/'+$Repository+'/releases?per_page=100') --jq '.[] | @json'
if($LASTEXITCODE -ne 0){throw '無法列出 Release。'}
$rows=New-Object Collections.Generic.List[object]
foreach($line in $lines){
 $release=$line|ConvertFrom-Json
 if($release.draft -or $release.tag_name -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?$'){continue}
 $sha=& gh api ('repos/'+$Repository+'/commits/'+$release.tag_name) --jq '.sha'
 if($LASTEXITCODE -ne 0){throw '無法核對 Release tag SHA。'}
 $snapshot=@($release.assets|Where-Object name -ceq 'quality.json');$manifest=@($release.assets|Where-Object name -ceq 'quality-manifest.json')
 $bundleName='windows_setup_report_'+$release.tag_name+'.zip'
 $bundles=@($release.assets|Where-Object {$_.name -ilike 'windows_setup_report_*'})
 $row=[ordered]@{Version=$release.tag_name;Commit=$sha;ReleaseUrl=$release.html_url;Immutable=($release.immutable -is [bool] -and $release.immutable -ceq $true);SnapshotPath='';ManifestPath='';SnapshotDigest='';ManifestDigest='';AssetDirectory='';AssetDigests=@();ArchivePath='';ArchiveDigest='';ArchiveSize=0;SourcePath='';Repository=$Repository}
 if($bundles.Count){
  $dir=Join-Path $out $release.tag_name;New-Item -ItemType Directory $dir|Out-Null
  $row.ArchivePath=Join-Path $dir $bundleName
  $rawNames=@('quality.json','quality-manifest.json','index.html','summary.json','summary.md','junit.xml','unit.svg','integration.svg','system.svg','coverage.svg','repo_coverage.json','coverage_inventory.json','coverage.xml','go_coverage.out','go_coverage.json','go_coverage.svg')
  if(@($release.assets|Where-Object {$rawNames -icontains $_.name}).Count){$row.SnapshotPath='conflicting-raw'}
  if($bundles.Count -eq 1 -and $bundles[0].name -ceq $bundleName){
   & gh release download $release.tag_name --repo $Repository --dir $dir --pattern $bundleName
   if($LASTEXITCODE -ne 0){throw 'Release ZIP 下載失敗。'}
   $row.ArchiveDigest=$bundles[0].digest;$row.ArchiveSize=$bundles[0].size
   $source=Join-Path $dir 'source';New-Item -ItemType Directory $source|Out-Null
   $oldGlobal=$env:GIT_CONFIG_GLOBAL;$oldSystem=$env:GIT_CONFIG_NOSYSTEM
   try {
    $env:GIT_CONFIG_GLOBAL='NUL';$env:GIT_CONFIG_NOSYSTEM='1'
    & git -C $source init -q
    if($LASTEXITCODE -ne 0){throw '無法建立隔離來源。'}
    & git -C $source -c core.hooksPath=NUL -c core.autocrlf=false fetch --no-tags --depth=1 ('https://github.com/'+$Repository+'.git') ('refs/tags/'+$release.tag_name)
    if($LASTEXITCODE -ne 0){throw '無法取得版本 Git 物件。'}
    $fetched=& git -C $source rev-parse 'FETCH_HEAD^{commit}'
    if($LASTEXITCODE -ne 0 -or $fetched -cne $sha){throw '版本 Git 物件與 tag 提交不符。'}
    & git -C $source -c core.hooksPath=NUL -c core.autocrlf=false checkout --detach --quiet $sha
    if($LASTEXITCODE -ne 0){throw '無法取得乾淨版本來源。'}
   } finally {$env:GIT_CONFIG_GLOBAL=$oldGlobal;$env:GIT_CONFIG_NOSYSTEM=$oldSystem}
   $row.SourcePath=$source
  }
 } elseif($snapshot.Count -eq 1 -and $manifest.Count -eq 1){
  $dir=Join-Path $out $release.tag_name;New-Item -ItemType Directory $dir|Out-Null
  $download=@('release','download',$release.tag_name,'--repo',$Repository,'--dir',$dir)
  foreach($name in @('quality.json','quality-manifest.json','index.html','summary.md','junit.xml','unit.svg','integration.svg','system.svg','coverage.svg','repo_coverage.json','coverage_inventory.json','coverage.xml','go_coverage.out')){if($release.assets.name -ccontains $name){$download+=@('--pattern',$name)}}
  & gh @download
  if($LASTEXITCODE -ne 0){throw 'Release 品質證據下載失敗。'}
  $row.SnapshotPath=Join-Path $dir 'quality.json';$row.ManifestPath=Join-Path $dir 'quality-manifest.json';$row.SnapshotDigest=$snapshot[0].digest;$row.ManifestDigest=$manifest[0].digest
  $row.AssetDirectory=$dir;$row.AssetDigests=@($release.assets|ForEach-Object {[pscustomobject]@{Name=$_.name;Digest=$_.digest}})
 }
 $rows.Add([pscustomobject]$row)
}
[IO.File]::WriteAllText((Join-Path $out 'catalog.json'),(ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 8),[Text.UTF8Encoding]::new($false))
# Never relabel a tag run as main: resolve a completed run for the current main SHA.
$mainSha=& gh api ('repos/'+$Repository+'/commits/main') --jq '.sha'
if($LASTEXITCODE -ne 0){throw '無法確認 main SHA。'}
if(-not $MainRunId){
 $runLines=& gh api ('repos/'+$Repository+'/actions/workflows/windows_tests.yml/runs?branch=main&event=push&status=completed&per_page=100') --jq '.workflow_runs[] | @json'
 if($LASTEXITCODE -ne 0){throw '無法尋找 main 品質證據。'}
 $run=@($runLines|ForEach-Object {$_|ConvertFrom-Json}|Where-Object head_sha -ceq $mainSha|Select-Object -First 1)
 if($run.Count){$MainRunId=[string]$run[0].id}
}
if($MainRunId){
 if($MainRunId -notmatch '^[0-9]+$'){throw 'Run ID 不合法。'}
 $run=(& gh api ('repos/'+$Repository+'/actions/runs/'+$MainRunId))|ConvertFrom-Json
 if($LASTEXITCODE -ne 0 -or ($run.id -isnot [int] -and $run.id -isnot [long]) -or [string]$run.id -cne $MainRunId -or ($run.run_attempt -isnot [int] -and $run.run_attempt -isnot [long]) -or $run.run_attempt -lt 1 -or $run.head_sha -cne $mainSha -or $run.head_branch -cne 'main' -or $run.event -cne $ExpectedMainEvent -or ($ExpectedMainEvent -ceq 'workflow_dispatch' -and $ExpectedMainAttempt -lt 1) -or ($ExpectedMainAttempt -gt 0 -and $run.run_attempt -ne $ExpectedMainAttempt)){throw 'main run 來源不符。'}
 $artifacts=(& gh api ('repos/'+$Repository+'/actions/runs/'+$MainRunId+'/artifacts'))|ConvertFrom-Json
 $artifact=@($artifacts.artifacts|Where-Object {$_.name -eq ('windows-test-reports-'+$MainRunId+'-'+$run.run_attempt) -and -not $_.expired})
 if($artifact.Count -eq 1){
  $mainDir=Join-Path $out 'main';New-Item -ItemType Directory $mainDir|Out-Null
  & gh run download $MainRunId --repo $Repository --name $artifact[0].name --dir $mainDir
  if($LASTEXITCODE -ne 0){throw 'main 品質快照下載失敗。'}
  $snapshot=Get-Content (Join-Path $mainDir 'summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
  if($snapshot.Commit -cne $mainSha -or $snapshot.RunUrl -cne ('https://github.com/'+$Repository+'/actions/runs/'+$MainRunId)){throw 'main 快照提交或執行紀錄不符。'}
 }else{throw 'main 同次品質工件缺少或重複。'}
 $containerArtifact=@($artifacts.artifacts|Where-Object {$_.name -ceq ('docker-test-reports-'+$MainRunId+'-'+$run.run_attempt) -and -not $_.expired})
 if($containerArtifact.Count -ne 1){throw 'main 同次容器工件缺少或重複。'}
 $containerDir=Join-Path $out 'windows_container';New-Item -ItemType Directory $containerDir|Out-Null
 & gh run download $MainRunId --repo $Repository --name $containerArtifact[0].name --dir $containerDir
 if($LASTEXITCODE -ne 0){throw 'main 容器報告下載失敗。'}
 $containerSnapshot=Get-Content -LiteralPath (Join-Path $containerDir 'summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if($containerSnapshot.Commit -cne $mainSha -or $containerSnapshot.RunUrl -cne ('https://github.com/'+$Repository+'/actions/runs/'+$MainRunId)){throw 'main 容器報告提交或執行紀錄不符。'}
}
[pscustomobject]@{CatalogPath=(Join-Path $out 'catalog.json');MainSnapshotPath=(Join-Path $out 'main/summary.json');ContainerSnapshotPath=(Join-Path $out 'windows_container/summary.json')}
