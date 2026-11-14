#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$SourceRoot,[Parameter(Mandatory=$true)][string]$OutputPath,[switch]$Runtime)
$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath $SourceRoot).Path
if(Test-Path -LiteralPath $OutputPath){throw '基線清單輸出已存在。'}
# Same safe suite directories as run_ci. Client/native smoke suites remain separate.
# This command only writes a manifest: it never starts coverage, including when
# the collector's bounded synthetic tests call it from a coverage worker.
$tests=@(foreach($layer in @('unit','integration')){
 Get-ChildItem -LiteralPath (Join-Path $source ('test/powershell/'+$layer)) -File -Filter '*_tests.ps1'|ForEach-Object {'test/powershell/'+$layer+'/'+$_.Name}
})
if(-not $tests.Count){throw '安全測試清單為空。'}
[Array]::Sort($tests,[StringComparer]::Ordinal)
foreach($test in $tests){if(-not(Test-Path -LiteralPath (Join-Path $source $test) -PathType Leaf)){throw ('安全測試遺失：'+$test)}}
$tracked=@(& git -C $source ls-files '*.ps1' '*.psm1')
if($LASTEXITCODE -ne 0){throw '無法取得版本控制來源清單。'}
$sourcePattern=if($Runtime){'^(core|modules)/'}else{'^(core|modules|script)/'}
$sources=@($tracked|Where-Object {$_ -match $sourcePattern -and $_ -notmatch '^modules/debloat/win11debloat/'}|Sort-Object)
if(-not $sources.Count){throw '正式 PowerShell 來源清單為空。'}
[Array]::Sort($sources,[StringComparer]::Ordinal)
$testEngines=[ordered]@{}
$metadataSuite='test/powershell/integration/managed_catalog_tests.ps1'
if($metadataSuite -cin $tests){$testEngines[$metadataSuite]='pwsh'}
$manifest=[ordered]@{SourceRoot=$source;Sources=$sources;Tests=$tests;TestEngines=$testEngines;Wrapper='test/powershell/coverage/safe_suite.ps1'}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($manifest|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
Write-Host ('已準備 '+$sources.Count+' 個正式來源與 '+$tests.Count+' 個獨立安全 suite。')
