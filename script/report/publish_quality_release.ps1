#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$PublicDirectory,[Parameter(Mandatory=$true)][string]$Version,[Parameter(Mandatory=$true)][string]$Commit,[Parameter(Mandatory=$true)][string]$NotesPath,[Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,[switch]$Prerelease,[string]$CoverageToolPath=$env:WINDOWS_SETUP_COVERAGE_TOOL,[string]$DriverAssetManifestPath,[string]$ReportArchive,[string]$BundleToolPath=$env:WINDOWS_SETUP_REPORT_BUNDLE_TOOL,[int]$RunAttempt,[string]$RunUrl,[string]$SourceRoot,[string]$ContainerDirectory)
$ErrorActionPreference='Stop'
if(-not $DriverAssetManifestPath){$DriverAssetManifestPath=Join-Path $PSScriptRoot '../release/driver_release_assets.json'}
. (Join-Path $PSScriptRoot '../test/test_report.ps1')
. (Join-Path $PSScriptRoot 'portal.ps1')
. (Join-Path $PSScriptRoot '../release/driver_release_library.ps1')
$snapshot=Get-Content (Join-Path $PublicDirectory 'summary.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert-TestReportSnapshot -Report $snapshot -Release
if($snapshot.SchemaVersion -ne 2 -or -not $snapshot.PSObject.Properties['RepoCoverage'] -or $snapshot.RepoCoverage.SchemaVersion -ne 2 -or $snapshot.RepoCoverage.Scope -cne 'core-modules-powershell-and-modules-native-csharp' -or $snapshot.RepoCoverage.Metric -cne 'runtime-powershell-csharp-executable-lines-v2'){throw '本輪發布只接受 PowerShell/C# runtime 覆蓋率；舊口徑僅供歷史讀取。'}
Assert-RepoCoverageArtifacts -Report $snapshot -Directory $PublicDirectory -CoverageToolPath $CoverageToolPath -RequireComplete
if($snapshot.Commit -cne $Commit -or $snapshot.Version -cne $Version -or $snapshot.RefName -cne $Version){throw '發布版本與測試來源不一致。'}
if($snapshot.PSObject.Properties['GoCoverage']){throw 'runtime 報告不可混入舊 Go 覆蓋率證據。'}
$files=@(Get-TestReportArtifactNames $snapshot.SchemaVersion)
$hashes=@(foreach($name in $files){[ordered]@{Name=$name;SHA256=(Get-FileHash -LiteralPath (Join-Path $PublicDirectory $name)).Hash.ToLowerInvariant()}})
$quality=Join-Path $PublicDirectory 'quality.json';Copy-Item -LiteralPath (Join-Path $PublicDirectory 'summary.json') -Destination $quality
$manifest=[ordered]@{SchemaVersion=$snapshot.SchemaVersion;Version=$Version;Commit=$Commit;MeasuredAt=$snapshot.MeasuredAt;RunUrl=$snapshot.RunUrl;SnapshotSHA256=(Get-FileHash $quality).Hash.ToLowerInvariant();Files=$hashes}
$manifestPath=Join-Path $PublicDirectory 'quality-manifest.json'
[IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
function Set-SelectedRelease([long]$Id,$Payload) {
 $path=Join-Path ([IO.Path]::GetTempPath()) ('release_patch_'+[guid]::NewGuid().ToString('N')+'.json')
 try {
  [IO.File]::WriteAllText($path,($Payload|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
  & gh api ('repos/'+$Repository+'/releases/'+$Id) --method PATCH --input $path | Out-Null
  if($LASTEXITCODE -ne 0){throw '更新選定草稿失敗。'}
 } finally {Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}
}
function Assert-SelectedContent($Draft,[string]$Body,[object[]]$Assets) {
 if($Draft.prerelease -isnot [bool] -or $Draft.prerelease -cne [bool]$Prerelease -or $Draft.target_commitish -cne $Commit -or $Draft.name -cne $Version -or $Draft.body -isnot [string] -or $Draft.body -cne $Body){throw '草稿內容或來源不符。'}
 Assert-ReleaseAssetSet $Draft.assets $Assets
}
$tagCommit=& gh api ('repos/'+$Repository+'/commits/'+$Version) --jq '.sha'
if($LASTEXITCODE -ne 0 -or $tagCommit -cne $Commit){throw '標籤來源 SHA 不符。'}
$existing=& gh api --paginate ('repos/'+$Repository+'/releases?per_page=100') --jq '.[].tag_name'
if($LASTEXITCODE -ne 0){throw '無法確認既有版本。'}
if(-not $SourceRoot){$SourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))}
if(-not $ReportArchive -or [IO.Path]::GetFileName($ReportArchive) -cne ('windows_setup_report_'+$Version+'.zip') -or -not (Test-Path -LiteralPath $ReportArchive -PathType Leaf) -or (Get-Item -LiteralPath $ReportArchive).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '缺少當版報表封裝。'}
if(-not $BundleToolPath -or $RunAttempt -lt 1 -or $RunUrl -cne $snapshot.RunUrl){throw '缺少報表驗證工具或執行次數。'}
function Assert-NoReparseAncestors([string]$Path) {
 $current=[IO.Path]::GetFullPath($Path)
 while($current){
  $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '驗證目錄路徑包含重新解析點。'}
  $next=[IO.Directory]::GetParent($current)
  if($null -eq $next){break};$current=$next.FullName
 }
}
$owner=New-ReportOwnedTemp -Purpose Release
$parent=$owner.Path
try {
 $verified=Join-Path $parent 'verified'
 & $BundleToolPath verify --archive $ReportArchive --source-root $SourceRoot --version $Version --commit $Commit --run-url $RunUrl --run-attempt $RunAttempt --output-dir $verified
 if($LASTEXITCODE -ne 0){throw '報表封裝驗證失敗。'}
 $receipt=Get-Content -LiteralPath (Join-Path $verified 'verified.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if($receipt.archive_sha256 -isnot [string] -or $receipt.archive_sha256 -cnotmatch '^[a-f0-9]{64}$' -or ($receipt.archive_size -isnot [int] -and $receipt.archive_size -isnot [long]) -or $receipt.archive_size -le 0){throw '報表驗證收據無效。'}
 $nativeNames=@('index.html','summary.json','summary.md','junit.xml','unit.svg','integration.svg','coverage.svg','repo_coverage.json','coverage_inventory.json','coverage.xml')
 $containerNames=@('index.html','summary.json','summary.md','junit.xml','unit.svg','integration.svg','coverage.svg')
 foreach($pair in @(@{Input=$PublicDirectory;Verified='native';Names=$nativeNames},@{Input=$ContainerDirectory;Verified='windows_container';Names=$containerNames})){
  if(-not $pair.Input){throw '缺少同次報表目錄。'}
  $verifiedDirectory=Join-Path $verified $pair.Verified
  Assert-NoReparseAncestors $pair.Input
  Assert-NoReparseAncestors $verifiedDirectory
  foreach($name in $pair.Names){
   $inputFile=Join-Path $pair.Input $name;$verifiedFile=Join-Path $verifiedDirectory $name
   $inputItem=Get-Item -LiteralPath $inputFile -Force -ErrorAction Stop;$verifiedItem=Get-Item -LiteralPath $verifiedFile -Force -ErrorAction Stop
   if($inputItem.PSIsContainer -or $verifiedItem.PSIsContainer -or ($inputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($verifiedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $inputItem.Length -ne $verifiedItem.Length -or (Get-FileHash -LiteralPath $inputFile).Hash -cne (Get-FileHash -LiteralPath $verifiedFile).Hash){throw '封裝與同次原始報表不一致。'}
  }
 }
} finally {
 Remove-ReportOwnedTemp -Handle $owner
}
$attachments=@($ReportArchive)
$driverAssets=@(Get-ReleaseDriverAssets -Path $DriverAssetManifestPath -Version $Version)
$qualityAssets=@($attachments|ForEach-Object {[pscustomobject]@{Name=[IO.Path]::GetFileName($_);SHA256=(Get-FileHash -LiteralPath $_).Hash.ToLowerInvariant();Size=(Get-Item -LiteralPath $_).Length}})
if($qualityAssets.Count -ne 1 -or $qualityAssets[0].SHA256 -cne $receipt.archive_sha256 -or $qualityAssets[0].Size -ne $receipt.archive_size){throw '報表封裝與驗證收據不一致。'}
$expectedAssets=@($driverAssets)+$qualityAssets
$notes=[IO.File]::ReadAllText($NotesPath,[Text.UTF8Encoding]::new($false,$true))
if($driverAssets.Count){
 if($existing -cnotcontains $Version){throw '此版本必須先完成獨立驅動草稿。'}
 $draft=Get-ReleaseDraftByTag -Repository $Repository -Version $Version
 $selectedId=[long]$draft.id
 Assert-ReleaseDriverDraft $draft $Version $Commit $DriverAssetManifestPath $driverAssets
 foreach($attachment in $attachments){
  $name=[uri]::EscapeDataString([IO.Path]::GetFileName($attachment))
  & gh api ('https://uploads.github.com/repos/'+$Repository+'/releases/'+$selectedId+'/assets?name='+$name) --method POST -H 'Content-Type: application/octet-stream' --input $attachment | Out-Null
  if($LASTEXITCODE -ne 0){throw '品質附件上傳失敗，保留未發布草稿。'}
 }
 $draft=Get-ReleaseDraftByTag -Repository $Repository -Version $Version -ExpectedId $selectedId
 Assert-ReleaseDriverDraft $draft $Version $Commit $DriverAssetManifestPath $expectedAssets
}else{
 if($existing -ccontains $Version){throw '版本已存在；不覆寫或重用草稿。'}
 $ghArguments=@('release','create',$Version,'--repo',$Repository,'--verify-tag','--target',$Commit,'--draft','--title',$Version,'--notes-file',$NotesPath)
 if($Prerelease){$ghArguments+=@('--prerelease','--latest=false')}
 $ghArguments+=$attachments
 & gh @ghArguments
 if($LASTEXITCODE -ne 0){throw '草稿或附件建立失敗，未發布。'}
 $draft=Get-ReleaseDraftByTag -Repository $Repository -Version $Version
 $selectedId=[long]$draft.id
 Assert-SelectedContent $draft $notes $expectedAssets
}
Set-SelectedRelease $selectedId ([ordered]@{tag_name=$Version;target_commitish=$Commit;name=$Version;prerelease=[bool]$Prerelease;draft=$true;body=$notes})
$draft=Get-ReleaseDraftByTag -Repository $Repository -Version $Version -ExpectedId $selectedId
Assert-SelectedContent $draft $notes $expectedAssets
# Publishing last locks the completed attachment set when immutability is enabled.
Set-SelectedRelease $selectedId ([ordered]@{tag_name=$Version;target_commitish=$Commit;name=$Version;prerelease=[bool]$Prerelease;draft=$false})
$published=(& gh api ('repos/'+$Repository+'/releases/tags/'+$Version))|ConvertFrom-Json
if($LASTEXITCODE -ne 0 -or ($published.id -isnot [int] -and $published.id -isnot [long]) -or $published.id -ne $selectedId -or $published.immutable -isnot [bool] -or $published.immutable -cne $true -or $published.draft -isnot [bool] -or $published.draft -cne $false -or $published.tag_name -cne $Version){throw '已發布版本 ID、鎖定或狀態不符。'}
$tagCommit=& gh api ('repos/'+$Repository+'/commits/'+$Version) --jq '.sha'
if($LASTEXITCODE -ne 0 -or $tagCommit -cne $Commit){throw '發布後標籤來源 SHA 不符。'}
Assert-ReleaseAssetSet $published.assets $expectedAssets
Write-Host ('已發布並鎖定品質證據：'+$published.html_url)
