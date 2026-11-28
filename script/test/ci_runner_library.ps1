#Requires -Version 5.1
# 完整 suite 名冊：Invoke-SetupCI 與容器分片合併共用同一份探索規則，避免兩處清單分歧。
function Get-SetupCISuiteRoster {
 param([Parameter(Mandatory=$true)][string]$PackageRoot)
 $rosterTestRoot=Join-Path $PackageRoot 'test'
# The inventory is the roster: every owned unit/integration suite runs once for All.
$cases=@(foreach($kind in @('Unit','Integration')){
 foreach($file in @(Get-ChildItem (Join-Path $rosterTestRoot ('powershell/'+$kind.ToLowerInvariant())) -Filter '*_tests.ps1' -File|Sort-Object Name)){
  @{Name=($kind+'.'+$file.BaseName.Replace('_tests',''));Layer=$kind;Path=$file.FullName;Arguments=$(if($file.Name -eq 'layout_tests.ps1'){@('-PackageRoot',$PackageRoot,'-SourceOnly')}else{@()})}
 }
})
# Every test file in each layer must participate; naming mistakes must not hide suites.
foreach($kind in @('unit','integration')){
 $all=@(Get-ChildItem (Join-Path $rosterTestRoot ('powershell/'+$kind)) -File -Filter '*.ps1')
 if(-not $all.Count -or @($all|Where-Object {$_.Name -cnotmatch '^[a-z0-9_]+_tests\.ps1$'}).Count){throw ('Invalid or empty test inventory: '+$kind)}
 if(@($cases|Where-Object {$_.Layer -eq $kind}).Count -ne $all.Count){throw ('Incomplete test discovery: '+$kind)}
}
 return $cases
}
function Invoke-SetupCI {
 param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$ReportDirectory,[ValidateSet('All','Unit','Integration')][string]$Layer='All',[ValidateRange(1,4)][int]$Parallelism=1,[string[]]$Suite=@(),[int]$ShardIndex=0,[int]$ShardCount=1)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ci_shard_library.ps1')
if($ShardCount -lt 1 -or $ShardIndex -lt 0 -or $ShardIndex -ge $ShardCount){throw '分片索引超出分片範圍。'}
$testRoot=Join-Path $packageRoot 'test'
. (Join-Path $PSScriptRoot 'test_report.ps1')
if($PSVersionTable.PSVersion.Major -ne 5){throw 'CI 必須使用 Windows PowerShell 5.1。'}
New-Item -ItemType Directory -Path $ReportDirectory -Force|Out-Null
$results=New-Object Collections.Generic.List[object]
$scripts=@(Get-ChildItem (Join-Path $packageRoot 'core') -Filter '*.ps1')+@(Get-ChildItem (Join-Path $packageRoot 'modules') -Recurse -Filter '*.ps1'|Where-Object FullName -notmatch '[\\/]Win11Debloat[\\/]')+@(Get-ChildItem $testRoot -Recurse -Filter '*.ps1')+@(Get-ChildItem (Join-Path $packageRoot 'script') -Recurse -Filter '*.ps1')
# 分片時語法檢查只在分片 0 執行一次，其他分片不重複解析。
if($ShardIndex -ne 0){$scripts=@()}
$parseFailures=@(foreach($file in $scripts){
 $tokens=$null;$errors=$null
 [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
 foreach($parseIssue in $errors){$file.Name+': '+$parseIssue.Message}
})
$parseFailures|Out-File (Join-Path $ReportDirectory 'syntax.log') -Encoding UTF8
if($ShardIndex -eq 0){$results.Add([pscustomobject]@{Name='PowerShell 5.1 語法';Layer='Static';Status=$(if($parseFailures.Count){'Failed'}else{'Passed'});Executed=$true;Passed=($parseFailures.Count -eq 0);ExitCode=[int]($parseFailures.Count -gt 0)})}
$cases=@(Get-SetupCISuiteRoster -PackageRoot $packageRoot)
$reportLayer=$Layer
$cases=@($cases|Where-Object {$Layer -eq 'All' -or $_.Layer -eq $Layer})
# 指定 Suite 只縮小執行範圍；完整清單檢查已先完成，未知、重複或空白名稱一律拒絕。
if($PSBoundParameters.ContainsKey('Suite')){
 if(-not @($Suite).Count){throw '指定的 Suite 清單不得為空。'}
 $selectedNames=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
 foreach($requested in @($Suite)){
  if([string]::IsNullOrWhiteSpace($requested) -or -not @($cases|Where-Object {$_.Name -ceq $requested}).Count){throw ('未知的測試名稱：'+$requested)}
  if(-not $selectedNames.Add($requested)){throw ('指定的測試名稱重複：'+$requested)}
 }
 $cases=@($cases|Where-Object {$selectedNames.Contains($_.Name)})
 # 報表層級只能宣稱實際執行的層級；跨兩層的子集仍以 All 呈現並要求兩層各有已執行項目。
 $layers=@($cases|ForEach-Object {$_.Layer}|Select-Object -Unique)
 if($layers.Count -eq 1){$reportLayer=$layers[0]}
}
# 依實測耗時把清單切成互不重疊的分片；聯集等於完整清單，沒有分到 suite 的分片失敗而不是回報成功。
if($ShardCount -gt 1 -and $cases.Count){$cases=@(Select-CISuiteShard -Cases $cases -ShardIndex $ShardIndex -ShardCount $ShardCount -Weights (Get-CISuiteWeights -Path (Join-Path $PSScriptRoot 'ci_suite_weights.json')) -DefaultWeight 10)}
# 分片後只含單一層級時，報表層級只宣稱實際執行的層級。
if($ShardCount -gt 1 -and $cases.Count){$shardLayers=@($cases|ForEach-Object {$_.Layer}|Select-Object -Unique);if($shardLayers.Count -eq 1){$reportLayer=$shardLayers[0]}}
if(-not $cases.Count){throw '沒有符合所選層級的測試，不得回報成功。'}
# Each case runs in its own Windows PowerShell child process; this block runs the serial path inline.
$runCase={
 param([string]$CaseName,[string[]]$CaseArguments,[string]$LogDirectory,[string]$WorkingDirectory,[string]$ShellPath)
 $ErrorActionPreference='Stop'
 Set-Location -LiteralPath $WorkingDirectory
 $log=Join-Path $LogDirectory ($CaseName+'.log')
 $code=1
 $timer=[Diagnostics.Stopwatch]::StartNew()
 $previousPreference=$ErrorActionPreference
 try{
  # Native stderr can contain Git warnings; the child exit code decides failure.
  $ErrorActionPreference='Continue'
  & $ShellPath @CaseArguments 2>&1 | Out-File $log -Encoding UTF8
  $code=$LASTEXITCODE
 }catch{$_|Out-String|Out-File $log -Append -Encoding UTF8}finally{$ErrorActionPreference=$previousPreference}
 $timer.Stop()
 [pscustomobject]@{Code=[int]$code;Seconds=[double]$timer.Elapsed.TotalSeconds}
}
$shellPath=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$workingDirectory=(Get-Location).ProviderPath
$outcomes=@{}
$running=New-Object Collections.Generic.List[object]
function Complete-SetupCICase($Case,$Outcome){
 $code=$Outcome.Code
 $assertions=@()
 foreach($line in @(Get-Content -LiteralPath (Join-Path $ReportDirectory ($Case.Name+'.log')))){
  if($line.StartsWith('@@ASSERT@@')){try{$record=$line.Substring(10)|ConvertFrom-Json;if($record.Passed -isnot [bool] -or $record.Name -isnot [string]){throw 'Invalid assertion record'};$assertions+=$record}catch{$code=1}}
 }
 if(-not $assertions.Count -or @($assertions|Where-Object {-not $_.Passed}).Count){$code=1}
 $outcomes[$Case.Name]=[pscustomobject]@{Name=$Case.Name;Layer=$Case.Layer;Status=$(if($code -eq 0){'Passed'}else{'Failed'});Executed=$true;Passed=($code -eq 0);ExitCode=$code;DurationSeconds=[math]::Round($Outcome.Seconds,3);Assertions=$assertions}
 Write-Host ($Case.Name+': '+$(if($code -eq 0){'PASS'}else{'FAIL'}))
}
# Parallel cases run as direct children of this process (through cmd redirection) so they share its console and code page;
# background jobs lose the console and fall back to a default code page, which garbles non-ASCII test output.
$cmdPath=Join-Path $env:WINDIR 'System32\cmd.exe'
function Start-SetupCIProcess($Case,$Arguments){
 $raw=Join-Path $ReportDirectory ($Case.Name+'.raw')
 $quoted=@(@($shellPath)+@($Arguments)|ForEach-Object {'"'+$_+'"'})
 $command='"'+($quoted -join ' ')+' > "'+$raw+'" 2>&1"'
 $process=Start-Process -FilePath $cmdPath -ArgumentList @('/d','/c',$command) -NoNewWindow -PassThru
 $null=$process.Handle
 [pscustomobject]@{Case=$Case;Process=$process;Raw=$raw;Timer=[Diagnostics.Stopwatch]::StartNew()}
}
function Complete-SetupCIProcess($Entry){
 $Entry.Process.WaitForExit()
 $Entry.Timer.Stop()
 $code=[int]$Entry.Process.ExitCode
 $log=Join-Path $ReportDirectory ($Entry.Case.Name+'.log')
 try{
  $text=[Console]::OutputEncoding.GetString([IO.File]::ReadAllBytes($Entry.Raw))
  [IO.File]::WriteAllText($log,$text,(New-Object Text.UTF8Encoding $true))
  [IO.File]::Delete($Entry.Raw)
 }catch{$code=1;$_|Out-String|Out-File $log -Append -Encoding UTF8}
 Complete-SetupCICase $Entry.Case ([pscustomobject]@{Code=$code;Seconds=$Entry.Timer.Elapsed.TotalSeconds})
}
function Wait-SetupCIProcess([int]$Limit){
 while($running.Count -ge $Limit -and $running.Count -gt 0){
  $finished=@($running|Where-Object {$_.Process.HasExited})
  if(-not $finished.Count){Start-Sleep -Milliseconds 200;continue}
  foreach($entry in $finished){[void]$running.Remove($entry);Complete-SetupCIProcess $entry}
 }
}
foreach($case in $cases){
 $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$case.Path)+$case.Arguments
 if($Parallelism -le 1){
  Complete-SetupCICase $case (& $runCase $case.Name $arguments $ReportDirectory $workingDirectory $shellPath)
  continue
 }
 Wait-SetupCIProcess $Parallelism
 $running.Add((Start-SetupCIProcess $case $arguments))
}
Wait-SetupCIProcess 1
# Report order follows the roster, never completion order.
foreach($case in $cases){$results.Add($outcomes[$case.Name])}
$success=@($results|Where-Object {$_.Executed -and -not $_.Passed}).Count -eq 0
$runUrl=if($env:GITHUB_REPOSITORY -and $env:GITHUB_RUN_ID){'https://github.com/'+$env:GITHUB_REPOSITORY+'/actions/runs/'+$env:GITHUB_RUN_ID}else{''}
$publicDirectory=Join-Path $ReportDirectory 'public'
$sourceState='Unknown'
$commit=$env:GITHUB_SHA
if(Get-Command git.exe -ErrorAction SilentlyContinue){
 $head=& git -C $packageRoot rev-parse HEAD 2>$null
 if($LASTEXITCODE -eq 0){if(-not $commit){$commit=$head};$dirty=@(& git -C $packageRoot status --porcelain 2>$null);if($LASTEXITCODE -eq 0){$sourceState=if($dirty.Count){'Dirty'}else{'Clean'}}}
}
$version=if(Test-Path (Join-Path $packageRoot '.version')){([IO.File]::ReadAllText((Join-Path $packageRoot '.version'))).Trim()}else{'Unknown'}
$refType=if($env:GITHUB_REF_TYPE -eq 'tag'){'Release'}else{'Branch'}
$refName=if($env:GITHUB_HEAD_REF){$env:GITHUB_HEAD_REF}elseif($env:GITHUB_REF_NAME){$env:GITHUB_REF_NAME}else{'local'}
$environment='Windows '+[Environment]::OSVersion.Version.ToString()+' / PowerShell '+$PSVersionTable.PSVersion.ToString()
if($env:WINDOWS_SETUP_TEST_CONTEXT -ceq 'Windows container'){$environment='Windows container / '+$environment}
$changes=@()
$changelogPath=Join-Path $packageRoot 'doc/changelog/changelog.md'
if(Test-Path $changelogPath){
 $changelog=[IO.File]::ReadAllText($changelogPath)
 if($refType -eq 'Release'){
  . (Join-Path $packageRoot 'script/release/release.ps1')
  $section=Get-ReleaseNotes $version $changelog
 }else{$section=([regex]::Match($changelog,'(?ms)^## \[Unreleased\].*?(?=^## \[|\z)')).Value}
 $changes=@($section -split '\r?\n'|Where-Object {$_ -match '^\s*-\s+\S'}|ForEach-Object {$_ -replace '^\s*-\s+',''})
}
$null=Write-TestReports -Version $version -Environment $environment -RefType $refType -RefName $refName -Changes $changes -Commit $commit -SourceState $sourceState -Checks @($results.ToArray()) -OutputDirectory $publicDirectory -Layer $reportLayer -RunUrl $runUrl
if($env:GITHUB_STEP_SUMMARY){Get-Content (Join-Path $publicDirectory 'summary.md') -Encoding UTF8|Out-File $env:GITHUB_STEP_SUMMARY -Append -Encoding UTF8}
if(-not $success){throw 'CI 測試未通過；請查看短期保留的測試報告。'}
Write-Host '所選單元與隔離整合測試通過。'
}
