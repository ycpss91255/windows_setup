#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ManifestPath,[Parameter(Mandatory=$true)][string]$OutputDirectory,[int]$WorkerIndex=-1,[string]$PesterModule,[string]$PwshPath,[ValidateRange(1,2)][int]$ThrottleLimit=1)
$workerClock=[Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'powershell_worker_diagnostics.ps1')
$version='6.0.0'
# SHA512 from the official Gallery version metadata, not from a local binary.
$packageHash='AHIAm7QW11As3sjMayo1rPU4JVIEfBL+ZILAyTyDnMPxMwLFQ3VeAA0prFTx+Y4DgZCUnH2N4+Xb0HDQua2EKA=='
function Write-Json($Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
function Get-PinnedPester {
 $cache=Join-Path ([IO.Path]::GetTempPath()) 'windows_setup_pester_6_0_0'
 [void][IO.Directory]::CreateDirectory($cache)
 $zip=Join-Path $cache 'pester.zip'
 if($env:WINDOWS_SETUP_PESTER_PACKAGE_PATH){
  $zip=[IO.Path]::GetFullPath($env:WINDOWS_SETUP_PESTER_PACKAGE_PATH)
  if(-not(Test-Path -LiteralPath $zip -PathType Leaf)){throw '預備的 Pester 套件不存在，拒絕退回網路或使用者快取。'}
 }
 if(-not(Test-Path -LiteralPath $zip)){
  $download=Join-Path $cache ([guid]::NewGuid().ToString('N')+'.download')
  $tls=[Net.ServicePointManager]::SecurityProtocol
  try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -Uri 'https://www.powershellgallery.com/api/v2/package/Pester/6.0.0' -OutFile $download -UseBasicParsing}finally{[Net.ServicePointManager]::SecurityProtocol=$tls}
  $hash=[Convert]::ToBase64String([Security.Cryptography.SHA512]::Create().ComputeHash([IO.File]::ReadAllBytes($download)))
  if($hash -cne $packageHash){throw 'Pester 官方套件 SHA512 不符。'}
  [IO.File]::Copy($download,$zip,$true)
 }
 $hash=[Convert]::ToBase64String([Security.Cryptography.SHA512]::Create().ComputeHash([IO.File]::ReadAllBytes($zip)))
 if($hash -cne $packageHash){throw 'Pester 快取 SHA512 不符，拒絕載入。'}
 $module=Join-Path $cache ([guid]::NewGuid().ToString('N'))
 Expand-Archive -LiteralPath $zip -DestinationPath $module
 return Join-Path $module 'Pester.psd1'
}
if($WorkerIndex -lt 0 -and $PSVersionTable.PSVersion.Major -ne 5){throw '收集管理程序要求 Windows PowerShell 5.1。'}
$manifest=Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8|ConvertFrom-Json
$source=[IO.Path]::GetFullPath([string]$manifest.SourceRoot).TrimEnd('\','/')
if(-not(Test-Path -LiteralPath $source -PathType Container)){throw '來源根目錄不存在。'}
function Resolve-InputFile([string]$Relative){
 if([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative)){throw '必須使用來源根目錄內的相對檔名。'}
 $path=[IO.Path]::GetFullPath((Join-Path $source $Relative))
 if(-not $path.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $path -PathType Leaf)){throw ('來源遺失或越界：'+$Relative)}
 return $path
}
$sources=@($manifest.Sources|ForEach-Object {Resolve-InputFile $_})
$tests=@($manifest.Tests|ForEach-Object {Resolve-InputFile $_})
$wrapper=if($manifest.Wrapper){Resolve-InputFile $manifest.Wrapper}else{$null}
$diagnosticFiles=@($manifest.Sources)+@($manifest.Tests)+@($manifest.Wrapper)
if(Test-Path -LiteralPath (Join-Path $source '.git')){$diagnosticFiles+=@(& git -C $source ls-files '*.ps1' 2>$null)}
if(-not $sources.Count -or -not $tests.Count -or @($sources|Select-Object -Unique).Count -ne $sources.Count -or @($tests|Select-Object -Unique).Count -ne $tests.Count){throw '來源或測試清單不可空白或重複。'}
if(@($sources|Where-Object {$_ -in $tests -or [IO.Path]::GetExtension($_) -ine '.ps1'}).Count){throw '正式來源必須為 PS1，且不可與測試重疊。'}
$engines=@{}
if($null -ne $manifest.TestEngines){
 if($manifest.TestEngines -isnot [pscustomobject]){throw 'TestEngines 必須為 suite 到引擎的對照物件。'}
 foreach($property in $manifest.TestEngines.PSObject.Properties){
  if($property.Name -cnotin @($manifest.Tests) -or $property.Value -isnot [string] -or $property.Value -cnotin @('powershell','pwsh')){throw 'TestEngines 包含未知 suite 或不支援的引擎。'}
  $engines[$property.Name]=$property.Value
 }
}
function Get-TestEngine([int]$Index){$name=[string]$manifest.Tests[$Index];if($engines.ContainsKey($name)){return $engines[$name]};return 'powershell'}
function Test-EngineVersion([string]$Engine,[string]$Version){
 $actual=[version]$Version
 if($Engine -eq 'pwsh'){return $actual.Major -eq 7 -and $actual -ge [version]'7.4'}
 return $actual.Major -eq 5 -and $actual.Minor -eq 1
}
$shardContext=$null
if($null -ne $manifest.PSObject.Properties['ShardContext']){
 $shardContext=$manifest.ShardContext
 $contextKeys=@('Commit','RunUrl','RunAttempt','ShardIndex','ShardCount','GlobalIndices')
 if($shardContext -isnot [pscustomobject] -or @($shardContext.PSObject.Properties).Count -ne $contextKeys.Count -or @($shardContext.PSObject.Properties|Where-Object {$_.Name -cnotin $contextKeys}).Count){throw '分片執行context欄位不完整或不合法。'}
 foreach($key in @('RunAttempt','ShardIndex','ShardCount')){if($shardContext.$key -isnot [int] -and $shardContext.$key -isnot [long]){throw '分片context的數字必須為整數。'}}
 if($shardContext.Commit -isnot [string] -or $shardContext.Commit -cnotmatch '^[a-f0-9]{40}$' -or $shardContext.RunUrl -isnot [string] -or $shardContext.RunUrl -cnotmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+$' -or $shardContext.RunAttempt -lt 1 -or $shardContext.ShardCount -lt 1 -or $shardContext.ShardCount -gt 4 -or $shardContext.ShardIndex -lt 0 -or $shardContext.ShardIndex -ge $shardContext.ShardCount -or $shardContext.GlobalIndices -isnot [array] -or @($shardContext.GlobalIndices).Count -ne $tests.Count){throw '分片執行context身分或完整索引不合法。'}
 $seenIndices=@{};$lastIndex=-1
 foreach($globalIndex in $shardContext.GlobalIndices){if(($globalIndex -isnot [int] -and $globalIndex -isnot [long]) -or $globalIndex -lt 0 -or $globalIndex -le $lastIndex -or $globalIndex%$shardContext.ShardCount -ne $shardContext.ShardIndex -or $seenIndices.ContainsKey($globalIndex)){throw '分片globalindex必須依序、唯一且符合分配。'};$seenIndices[$globalIndex]=$true;$lastIndex=$globalIndex}
}
$hashes=@($sources|ForEach-Object {[pscustomobject]@{File=$_.Substring($source.Length+1).Replace('\','/');SHA256=(Get-FileHash -LiteralPath $_).Hash.ToLowerInvariant()}})
$output=[IO.Path]::GetFullPath($OutputDirectory)
if($WorkerIndex -ge 0){
 [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
 $global:OutputEncoding=[Console]::OutputEncoding
 if($WorkerIndex -ge $tests.Count -or -not(Test-Path -LiteralPath $PesterModule -PathType Leaf)){throw '子程序參數不完整。'}
 $engine=Get-TestEngine $WorkerIndex
 if(-not(Test-EngineVersion $engine $PSVersionTable.PSVersion.ToString())){throw '子程序實際引擎不符合指定版本；pwsh 必須為 7.4 以上的 7.x。'}
 $engineExecutable=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
 $engineHash=(Get-FileHash -LiteralPath $engineExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
 $testContext=$null
 if($null -ne $shardContext){
  $suiteFile=$tests[$WorkerIndex]
  $testContext=[ordered]@{Commit=$shardContext.Commit;RunUrl=$shardContext.RunUrl;RunAttempt=$shardContext.RunAttempt;ShardIndex=$shardContext.ShardIndex;ShardCount=$shardContext.ShardCount;GlobalIndex=$shardContext.GlobalIndices[$WorkerIndex];ProcessId=$PID;TestFile=$suiteFile.Substring($source.Length+1).Replace('\','/');TestSHA256=(Get-FileHash -LiteralPath $suiteFile).Hash.ToLowerInvariant();WrapperFile='';WrapperSHA256=''}
  if($wrapper){$testContext.WrapperFile=$wrapper.Substring($source.Length+1).Replace('\','/');$testContext.WrapperSHA256=(Get-FileHash -LiteralPath $wrapper).Hash.ToLowerInvariant()}
 }
 Import-Module -Name $PesterModule -Force
 if((Get-Module Pester).Version.ToString() -cne $version){throw 'Pester 版本不符。'}
 $config=New-PesterConfiguration
 # 自有安全 suite 不使用此 drive，避免並行初始化共用 HKCU scratch。
 $config.TestRegistry.Enabled=$false
 $config.Run.Path=@($tests[$WorkerIndex]);$config.Run.RepoRoot=$source;$config.Run.PassThru=$true
 if($wrapper){$config.Run.Path=@();$config.Run.Container=@(New-PesterContainer -Path $wrapper -Data @{SuitePath=$tests[$WorkerIndex];SourceRoot=$source})}
 $config.CodeCoverage.Enabled=$true;$config.CodeCoverage.Path=$sources;$config.CodeCoverage.ExcludeTests=$false
 $config.CodeCoverage.OutputFormat='Cobertura';$config.CodeCoverage.OutputPath=Join-Path $output ('worker_'+$WorkerIndex+'.xml')
 $config.CodeCoverage.CoveragePercentTarget=0
 $failurePath=Join-Path $output ('worker_'+$WorkerIndex+'.private.failure.json')
 $priorPesterErrors=@($global:Error);$pesterInvocationErrors=@()
 $setupMilliseconds=$workerClock.ElapsedMilliseconds;$workerClock.Restart()
 try{$result=Invoke-Pester -Configuration $config -ErrorVariable pesterInvocationErrors}catch{try{Write-PesterWorkerFailureRecord -Path $failurePath -SourceRoot $source -AllowedFiles $diagnosticFiles -InvocationErrors @($_)}catch{};throw}
 $pesterMilliseconds=$workerClock.ElapsedMilliseconds;$workerClock.Restart()
 if($result.FailedCount -gt 0 -or $result.PassedCount -lt 1 -or $result.Result -ne 'Passed'){
  try{
   if($null -eq $result){
    $currentPesterErrors=@(Get-NewPesterInvocationErrors -PriorErrors $priorPesterErrors -CurrentErrors @($global:Error) -InvocationErrors $pesterInvocationErrors)
    Write-PesterWorkerFailureRecord -Path $failurePath -SourceRoot $source -AllowedFiles $diagnosticFiles -InvocationErrors $currentPesterErrors -NoResult
   }else{Write-PesterWorkerFailureRecord -Path $failurePath -SourceRoot $source -AllowedFiles $diagnosticFiles -Result $result}
  }catch{}
  throw 'Pester 測試未全部成功。'
 }
 if($null -ne $testContext -and ((Get-FileHash -LiteralPath $suiteFile).Hash.ToLowerInvariant() -cne $testContext.TestSHA256 -or ($wrapper -and (Get-FileHash -LiteralPath $wrapper).Hash.ToLowerInvariant() -cne $testContext.WrapperSHA256))){throw '測試或wrapper在原生量測期間變更。'}
 $commands=@($result.CodeCoverage.CommandsExecuted)+@($result.CodeCoverage.CommandsMissed)
 if(-not $commands.Count){throw '沒有真實命令覆蓋率證據。'}
 $rows=@(foreach($command in $commands){
  $file=[IO.Path]::GetFullPath([string]$command.File)
  if($file -notin $sources -or $command.StartLine -lt 1 -or $command.StartColumn -lt 1){throw 'Pester 證據來源不符。'}
  [pscustomobject]@{File=$file.Substring($source.Length+1).Replace('\','/');Line=[int]$command.StartLine;Column=[int]$command.StartColumn;EndLine=[int]$command.EndLine;EndColumn=[int]$command.EndColumn;Hit=([int]$command.HitCount -gt 0)}
 })
 foreach($expected in $hashes){if($expected.File -notin $rows.File){throw ('Pester 未提供完整來源分母：'+$expected.File)}}
 $workerProof=[ordered]@{ProcessId=$PID;PesterVersion=$version;Engine=$engine;EngineVersion=$PSVersionTable.PSVersion.ToString();EngineSHA256=$engineHash;Sources=$hashes;Commands=$rows}
 if($null -ne $testContext){$workerProof.Context=$testContext}
 Write-Json (Join-Path $output ('worker_'+$WorkerIndex+'.json')) $workerProof
 if($null -ne $testContext){
  $serializationMilliseconds=$workerClock.ElapsedMilliseconds
  $timing=[ordered]@{SchemaVersion=1;Context=$testContext;Phases=@([ordered]@{Name='worker_setup';Milliseconds=$setupMilliseconds},[ordered]@{Name='pester_instrumentation_and_test';Milliseconds=$pesterMilliseconds},[ordered]@{Name='serialization';Milliseconds=$serializationMilliseconds})}
  Write-Json (Join-Path $output ('worker_'+$WorkerIndex+'.timing.json')) $timing
 }
 exit 0
}
if(Test-Path -LiteralPath $output){throw '輸出目錄必須是全新目錄。'}
[void][IO.Directory]::CreateDirectory($output)
$module=Get-PinnedPester
$launchers=@{powershell=(Join-Path $PSHOME 'powershell.exe')}
if(@($engines.Values|Where-Object {$_ -eq 'pwsh'}).Count){
 if(-not $PwshPath){$PwshPath=(Get-Command pwsh.exe -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source}
 $PwshPath=[IO.Path]::GetFullPath($PwshPath)
 if(-not(Test-Path -LiteralPath $PwshPath -PathType Leaf)){throw '找不到指定的 pwsh；不會降級為 Windows PowerShell。'}
 $launchers.pwsh=$PwshPath
}
$workers=@();$merged=@{};$expectedKeys=$null
function Quote-CollectorArgument([string]$Value){
 return '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}
for($offset=0;$offset -lt $tests.Count;$offset+=$ThrottleLimit){
 $batch=@()
 try{
  for($index=$offset;$index -lt [Math]::Min($offset+$ThrottleLimit,$tests.Count);$index++){
   $engine=Get-TestEngine $index;$launcher=$launchers[$engine]
   $launcherHash=(Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash.ToLowerInvariant()
   $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-ManifestPath',$ManifestPath,'-OutputDirectory',$output,'-WorkerIndex',$index.ToString(),'-PesterModule',$module)
   $argumentLine=(@($arguments|ForEach-Object {Quote-CollectorArgument ([string]$_)}) -join ' ')
   $process=Start-Process -FilePath $launcher -ArgumentList $argumentLine -WorkingDirectory $source -WindowStyle Hidden -RedirectStandardOutput (Join-Path $output ('worker_'+$index+'.private.stdout.log')) -RedirectStandardError (Join-Path $output ('worker_'+$index+'.private.stderr.log')) -PassThru
   $batch+=@([pscustomobject]@{Index=$index;Engine=$engine;LauncherHash=$launcherHash;Process=$process})
   $null=$process.Handle
  }
  foreach($running in $batch){
   $i=$running.Index;$requestedEngine=$running.Engine;$launcherHash=$running.LauncherHash
   $running.Process.WaitForExit()
   $nativeExit=$running.Process.ExitCode
   if($null -eq $nativeExit -or $nativeExit -ne 0){
    try{
     $diagnostic=Get-PowerShellWorkerFailureDiagnostic -SourceRoot $source -TestFile ([string]$manifest.Tests[$i]) -WorkerIndex $i -Engine $requestedEngine -NativeExitCode $(if($null -eq $nativeExit){-1}else{$nativeExit}) -StandardOutputPath (Join-Path $output ('worker_'+$i+'.private.stdout.log')) -StandardErrorPath (Join-Path $output ('worker_'+$i+'.private.stderr.log')) -AllowedFiles $diagnosticFiles -FailureRecordPath (Join-Path $output ('worker_'+$i+'.private.failure.json'))
     Write-Host ('PowerShell worker failure diagnostic: '+($diagnostic|ConvertTo-Json -Depth 5 -Compress))
    }catch{Write-Host 'PowerShell worker failure diagnostic unavailable; original native failure is retained.'}
    throw ('PowerShell coverage worker failed: index='+$i+' exit='+$nativeExit)
   }
 $worker=Get-Content -LiteralPath (Join-Path $output ('worker_'+$i+'.json')) -Raw -Encoding UTF8|ConvertFrom-Json
 if($worker.ProcessId -ne $running.Process.Id -or $worker.Engine -cne $requestedEngine -or $worker.EngineSHA256 -cne $launcherHash -or -not(Test-EngineVersion $requestedEngine $worker.EngineVersion)){throw '子程序引擎版本或執行檔雜湊不一致。'}
 if(($worker.Sources|ConvertTo-Json -Compress) -cne ($hashes|ConvertTo-Json -Compress)){throw '子程序來源雜湊不一致。'}
 $keys=@(foreach($row in $worker.Commands){$key=$row.File+':'+$row.Line+':'+$row.Column+':'+$row.EndLine+':'+$row.EndColumn;if(-not $merged.ContainsKey($key)){$merged[$key]=$row}else{$merged[$key].Hit=$merged[$key].Hit -or $row.Hit};$key})
 [Array]::Sort($keys,[StringComparer]::Ordinal)
 if($null -eq $expectedKeys){$expectedKeys=$keys}elseif(($keys -join "`n") -cne ($expectedKeys -join "`n")){throw '子程序命令分母不一致。'}
 $workers+=@([pscustomobject]@{Index=$i;ProcessId=$worker.ProcessId;Engine=$worker.Engine;EngineVersion=$worker.EngineVersion;EngineSHA256=$worker.EngineSHA256;Evidence=('worker_'+$i+'.json')})
   Write-Host ('PowerShell worker completed: '+($i+1)+'/'+$tests.Count)
  }
 }finally{
  foreach($running in $batch){try{if(-not $running.Process.HasExited){$running.Process.Kill();$running.Process.WaitForExit()}}finally{$running.Process.Dispose()}}
 }
}
foreach($item in $hashes){if((Get-FileHash -LiteralPath (Join-Path $source $item.File)).Hash.ToLowerInvariant() -cne $item.SHA256){throw '量測期間來源變更。'}}
$xml=[xml]'<?xml version="1.0" encoding="utf-8"?><coverage version="1" lines-covered="0" lines-valid="0" line-rate="0"><sources><source>.</source></sources><packages><package name="PowerShell"><classes /></package></packages></coverage>'
$xml.coverage.SetAttribute('coverage-metric','complete-executable-lines-v1')
$xml.coverage.SetAttribute('coverage-schema','1')
$total=0;$covered=0
foreach($item in $hashes){
 $class=$xml.CreateElement('class');$class.SetAttribute('name',$item.File);$class.SetAttribute('filename',$item.File)
 $lines=$xml.CreateElement('lines');[void]$class.AppendChild($lines)
 foreach($group in @($merged.Values|Where-Object File -ceq $item.File|Group-Object Line|Sort-Object {[int]$_.Name})){
  $hit=@($group.Group|Where-Object {-not $_.Hit}).Count -eq 0
  $line=$xml.CreateElement('line');$line.SetAttribute('number',$group.Name);$line.SetAttribute('hits',([int]$hit).ToString());[void]$lines.AppendChild($line)
  $total++;if($hit){$covered++}
 }
 [void]$xml.SelectSingleNode('/coverage/packages/package/classes').AppendChild($class)
}
if(-not $total){throw '可執行行分母為空。'}
foreach($item in $hashes){$item|Add-Member -NotePropertyName ExpectedLines -NotePropertyValue @($merged.Values|Where-Object File -ceq $item.File|Select-Object -ExpandProperty Line -Unique|Sort-Object)}
$xml.coverage.SetAttribute('lines-covered',$covered.ToString());$xml.coverage.SetAttribute('lines-valid',$total.ToString());$xml.coverage.SetAttribute('line-rate',($covered/[double]$total).ToString([Globalization.CultureInfo]::InvariantCulture))
Write-Json (Join-Path $output 'evidence.json') ([ordered]@{SchemaVersion=1;PesterVersion=$version;PackageSHA512=$packageHash;Sources=$hashes;Workers=$workers;Metric='FullyCoveredCommandStartLines';Covered=$covered;Total=$total})
$xml.Save((Join-Path $output 'coverage.xml'))
Write-Host ('PowerShell 原檔可執行行覆蓋率：'+$covered+'/'+$total+'；僅此清單範圍，不是整個儲存庫。')

$global:LASTEXITCODE=0
