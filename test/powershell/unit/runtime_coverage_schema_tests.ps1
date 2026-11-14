#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'script/report/repo_coverage.ps1')
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
$json='{"SchemaVersion":2,"Metric":"runtime-powershell-csharp-executable-lines-v2","Scope":"core-modules-powershell-and-modules-native-csharp","Commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","RunUrl":"https://github.com/example/repo/actions/runs/1","MeasuredAt":"2026-01-01T00:00:00Z","SourceState":"Clean","InventorySHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","NormalizedSHA256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","Result":{"SchemaVersion":1,"Metric":"complete-executable-lines-v1","Complete":true,"Covered":4,"Executable":5,"Percent":80,"Missing":[],"Blockers":[],"Languages":{"powershell":{"Covered":4,"Executable":5}}}}'
$coverage=$json|ConvertFrom-Json
Assert-RepoCoverage -Coverage $coverage
Assert ((Get-RepoCoverageScopeLabel $coverage) -eq 'PowerShell/C# runtime') 'Runtime scope is explicit'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('windows_setup_runtime_schema_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
[IO.File]::WriteAllText((Join-Path $temp 'repo_coverage.json'),($coverage|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
$tool=Join-Path $temp 'verify.cmd';$capture=Join-Path $temp 'arguments.txt'
[IO.File]::WriteAllText($tool,"@echo off`r`necho %* > `"%RUNTIME_SCHEMA_ARGS%`"`r`nexit /b 0`r`n",[Text.Encoding]::ASCII)
$previous=$env:RUNTIME_SCHEMA_ARGS;$env:RUNTIME_SCHEMA_ARGS=$capture
try {
 $report=[pscustomobject]@{SchemaVersion=2;Commit=$coverage.Commit;RunUrl=$coverage.RunUrl;SourceState='Clean';RepoCoverage=$coverage}
 Assert-RepoCoverageArtifacts -Report $report -Directory $temp -CoverageToolPath $tool -RequireComplete
 Assert ([IO.File]::ReadAllText($capture).Contains('--runtime')) 'Runtime verifier mode is required'
} finally {$env:RUNTIME_SCHEMA_ARGS=$previous}
. (Join-Path $root 'script/test/test_report.ps1')
$checks=@([pscustomobject]@{Name='u';Layer='Unit';Status='Passed';Executed=$true;Passed=$true;ExitCode=0;DurationSeconds=0;Assertions=@([pscustomobject]@{Name='u';Passed=$true})},[pscustomobject]@{Name='i';Layer='Integration';Status='Passed';Executed=$true;Passed=$true;ExitCode=0;DurationSeconds=0;Assertions=@([pscustomobject]@{Name='i';Passed=$true})})
$view=Join-Path $temp 'view'
Write-TestReports -Checks $checks -OutputDirectory $view -Layer All -Commit $coverage.Commit -RunUrl $coverage.RunUrl -SourceState Clean -RefName main -MeasuredAt $coverage.MeasuredAt -RepoCoverage $coverage | Out-Null
Assert ([IO.File]::ReadAllText((Join-Path $view 'index.html')).Contains('PowerShell/C# runtime')) 'Report page identifies runtime scope'
Assert ([IO.File]::ReadAllText((Join-Path $view 'summary.md')).Contains('PowerShell/C# runtime')) 'Report summary identifies runtime scope'
Assert ([IO.File]::ReadAllText((Join-Path $view 'coverage.svg')).Contains('runtime PowerShell/C#')) 'Badge identifies runtime language scope'
foreach($name in @('repo_coverage.json','coverage_inventory.json','coverage.xml')){if($name -eq 'repo_coverage.json'){$value=$coverage|ConvertTo-Json -Depth 20}else{$value='fixture'};[IO.File]::WriteAllText((Join-Path $view $name),$value)}
$catalog=Join-Path $temp 'catalog.json';[IO.File]::WriteAllText($catalog,'[]')
$portal=Join-Path $temp 'portal';$env:RUNTIME_SCHEMA_ARGS=$capture
try { & (Join-Path $root 'script/report/build_portal.ps1') -Preview -CatalogPath $catalog -MainSnapshotPath (Join-Path $view 'summary.json') -OutputDirectory $portal -CoverageToolPath $tool | Out-Null } finally {$env:RUNTIME_SCHEMA_ARGS=$previous}
Assert ([IO.File]::ReadAllText((Join-Path $portal 'index.html')).Contains('PowerShell/C# runtime')) 'Portal identifies runtime scope'
$legacy=$coverage|ConvertTo-Json -Depth 20|ConvertFrom-Json
$legacy.SchemaVersion=1;$legacy.Metric='complete-executable-lines-v1';$legacy.PSObject.Properties.Remove('Scope')
$legacyView=Join-Path $temp 'legacy-view'
Write-TestReports -Checks $checks -OutputDirectory $legacyView -Layer All -Commit $legacy.Commit -RunUrl $legacy.RunUrl -SourceState Clean -RefName main -MeasuredAt $legacy.MeasuredAt -RepoCoverage $legacy | Out-Null
foreach($name in @('repo_coverage.json','coverage_inventory.json','coverage.xml')){if($name -eq 'repo_coverage.json'){$value=$legacy|ConvertTo-Json -Depth 20}else{$value='fixture'};[IO.File]::WriteAllText((Join-Path $legacyView $name),$value)}
$rejected=$false;$env:RUNTIME_SCHEMA_ARGS=$capture
try { & (Join-Path $root 'script/report/build_portal.ps1') -CatalogPath $catalog -MainSnapshotPath (Join-Path $legacyView 'summary.json') -OutputDirectory (Join-Path $temp 'legacy-current') -CoverageToolPath $tool | Out-Null } catch {$rejected=$true} finally {$env:RUNTIME_SCHEMA_ARGS=$previous}
Assert $rejected 'Published main rejects historical coverage scope even with matching identity'
$coverage.Scope='all-owned'
$rejected=$false;try{Assert-RepoCoverage -Coverage $coverage}catch{$rejected=$true}
Assert $rejected 'Altered scope rejected'
