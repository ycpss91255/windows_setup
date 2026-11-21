#Requires -Version 5.1
function Test-BoundaryTarget([string]$Candidate,[string]$Expected) {
 if(-not [IO.Path]::IsPathRooted($Candidate) -or -not [IO.Path]::IsPathRooted($Expected)){return $false}
 try { return [string]::Equals([IO.Path]::GetFullPath($Candidate),[IO.Path]::GetFullPath($Expected),[StringComparison]::OrdinalIgnoreCase) } catch { return $false }
}
function Assert-RunModuleSafePath([string]$Path) {
 $current=Get-Item -LiteralPath $Path -Force
 while($null -ne $current){
  if($current.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse point in fixture path'}
  if($current -is [IO.FileInfo]){$current=$current.Directory}else{$current=$current.Parent}
 }
}
function Assert-RunModuleFixture($Fixture) {
 if(-not $script:runModuleFixtures.ContainsKey($Fixture.Root) -or $Fixture.Entry -cne (Join-Path $Fixture.Root 'run_module.ps1')){throw 'unknown fixture'}
 Assert-RunModuleSafePath $Fixture.Root
 foreach($name in $script:runModuleFixtures[$Fixture.Root].Keys){
  $path=Join-Path $Fixture.Root $name
  Assert-RunModuleSafePath $path
  if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $script:runModuleFixtures[$Fixture.Root][$name]){throw 'fixture source changed'}
 }
}
function New-RunModuleFixture {
 param([Parameter(Mandatory=$true)][string]$SourceRoot)
 if($null -eq $script:runModuleFixtures){$script:runModuleFixtures=@{}}
 if(-not [IO.Path]::IsPathRooted($SourceRoot)){throw 'SourceRoot must be absolute'}
 $SourceRoot=[IO.Path]::GetFullPath($SourceRoot)
 $source=Join-Path $SourceRoot 'core/run_module.ps1'
 Assert-RunModuleSafePath $source
 foreach($item in @($SourceRoot,(Join-Path $SourceRoot 'core'),$source)){
  if(-not (Test-Path -LiteralPath $item) -or ((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'invalid source path'}
 }
 $directory=Join-Path $env:TEMP ('run_module_fixture_'+[guid]::NewGuid().ToString('N'))
 [void][IO.Directory]::CreateDirectory($directory)
 Assert-RunModuleSafePath $directory
 $entry=Join-Path $directory 'run_module.ps1'
 Copy-Item -LiteralPath $source -Destination $entry
 if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash){throw 'source copy mismatch'}
 [IO.File]::WriteAllText((Join-Path $directory 'entry_os_boundary.ps1'),@'
function Get-SetupEntryIdentity { 'fixture-sid' }
function Test-SetupEntryAdministrator { $env:RUN_MODULE_FIXTURE_ADMIN -eq 'true' }
function Start-SetupEntryElevated { param($Command) [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'captured.txt'),$Command) }
'@,[Text.UTF8Encoding]::new($true))
 [IO.File]::WriteAllText((Join-Path $directory 'paths.ps1'),@'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'paths_loaded.txt'),'loaded')
function Resolve-NucPath { throw 'legacy resolver reached' }
function Resolve-SetupPath { param($Name) if($Name -notmatch '^[A-Za-z0-9-]+[.]ps1$'){throw 'unexpected module'};[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'resolver_called.txt'),$Name);Join-Path $PSScriptRoot 'dummy.ps1' }
'@,[Text.UTF8Encoding]::new($true))
 [IO.File]::WriteAllText((Join-Path $directory 'dummy.ps1'),@'
param([switch]$VerifyOnly,[switch]$Restore,[switch]$SyncOnly,[string]$Mode,[string]$DriverPackagePath,[string]$ConfirmedBoard,[string]$ConfirmationComputer,[switch]$NonInteractive,[switch]$ApplyPolicy)
$PSBoundParameters|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'dummy.json') -Encoding UTF8
'@,[Text.UTF8Encoding]::new($true))
 [IO.File]::WriteAllText((Join-Path $directory 'wrapper.ps1'),@'
$ErrorActionPreference='Stop'
function global:Test-SetupAdministrator {throw 'legacy admin boundary reached'}
function global:Start-Process {throw 'blocked process'}
function global:Add-Type {throw 'blocked native'}
function global:Get-ItemProperty {throw 'blocked registry'}
function global:Set-ItemProperty {throw 'blocked registry'}
function global:New-ItemProperty {throw 'blocked registry'}
function global:Remove-ItemProperty {throw 'blocked registry'}
function global:Get-Service {throw 'blocked service'}
function global:Set-Service {throw 'blocked service'}
function global:Start-Service {throw 'blocked service'}
function global:Register-ScheduledTask {throw 'blocked task'}
$data=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'args.json') -Raw|ConvertFrom-Json
$arguments=@{};foreach($property in $data.PSObject.Properties){$arguments[$property.Name]=$property.Value}
& (Join-Path $PSScriptRoot 'run_module.ps1') @arguments
'@,[Text.UTF8Encoding]::new($true))
 $hashes=@{};foreach($name in @('run_module.ps1','entry_os_boundary.ps1','paths.ps1','dummy.ps1','wrapper.ps1')){$hashes[$name]=(Get-FileHash -LiteralPath (Join-Path $directory $name) -Algorithm SHA256).Hash}
 $script:runModuleFixtures[$directory]=$hashes
 return [pscustomobject]@{Root=$directory;Entry=$entry}
}

function Invoke-RunModuleFixture {
 param([Parameter(Mandatory=$true)]$Fixture,[Parameter(Mandatory=$true)][hashtable]$Arguments,[bool]$Admin=$false)
 Assert-RunModuleFixture $Fixture
 $allowed=@('Module','ExpectedUserSID','VerifyOnly','ApplyPolicy','Restore','Mode','SyncOnly','DriverPackagePath','NonInteractive','ConfirmedBoard','ConfirmationComputer')
 foreach($key in $Arguments.Keys){if($key -notin $allowed){throw 'unexpected parameter'}}
 foreach($key in $Arguments.Keys){
  if($key -in @('VerifyOnly','ApplyPolicy','Restore','SyncOnly','NonInteractive')){if($Arguments[$key] -isnot [bool]){throw 'expected boolean switch'}}
  elseif($Arguments[$key] -isnot [string]){throw 'expected string parameter'}
 }
 foreach($name in @('args.json','captured.txt','dummy.json','paths_loaded.txt','resolver_called.txt','case.log')){$path=Join-Path $Fixture.Root $name;if(Test-Path -LiteralPath $path){Assert-RunModuleSafePath $path}}
 foreach($name in @('captured.txt','dummy.json','paths_loaded.txt','resolver_called.txt')){[IO.File]::Delete((Join-Path $Fixture.Root $name))}
 $Arguments|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $Fixture.Root 'args.json') -Encoding UTF8
 $previous=$env:RUN_MODULE_FIXTURE_ADMIN;$prior=$ErrorActionPreference
 try {
  $env:RUN_MODULE_FIXTURE_ADMIN=$Admin.ToString().ToLowerInvariant();$ErrorActionPreference='Continue'
  $powershell=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell/v1.0/powershell.exe'
  & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Fixture.Root 'wrapper.ps1') *> (Join-Path $Fixture.Root 'case.log')
  $code=$LASTEXITCODE
 } finally {$ErrorActionPreference=$prior;$env:RUN_MODULE_FIXTURE_ADMIN=$previous}
 if($code -ne 0){throw 'fixture child rejected arguments'}
}

function Read-RunModuleCapturedCommand {
 param([Parameter(Mandatory=$true)]$Fixture)
 Assert-RunModuleFixture $Fixture
 Assert-RunModuleSafePath (Join-Path $Fixture.Root 'captured.txt')
 $text=[IO.File]::ReadAllText((Join-Path $Fixture.Root 'captured.txt'));$t=$null;$e=$null
 $tree=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$t,[ref]$e);$statements=@($tree.EndBlock.Statements)
 if($e.Count -or $statements.Count -ne 1 -or $statements[0] -isnot [Management.Automation.Language.PipelineAst] -or $statements[0].PipelineElements.Count -ne 1){throw 'unexpected captured syntax'}
 $cmd=$statements[0].PipelineElements[0]
 if($cmd -isnot [Management.Automation.Language.CommandAst] -or $cmd.InvocationOperator -ne 'Ampersand' -or $cmd.Redirections.Count){throw 'unexpected captured command'}
 $parts=@($cmd.CommandElements)
 if($parts[0] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or -not (Test-BoundaryTarget $parts[0].Value $Fixture.Entry)){throw 'unexpected captured target'}
 $values=@{};for($i=1;$i -lt $parts.Count;$i++){
  if($parts[$i] -isnot [Management.Automation.Language.CommandParameterAst] -or $null -ne $parts[$i].Argument){throw 'unexpected captured argument'}
  $key=$parts[$i].ParameterName;if($key -notin @('Module','ExpectedUserSID','VerifyOnly','ApplyPolicy','Restore','Mode','SyncOnly','DriverPackagePath','NonInteractive','ConfirmedBoard','ConfirmationComputer') -or $values.ContainsKey($key)){throw 'unexpected or duplicate parameter'}
  $hasLiteral=$i+1 -lt $parts.Count -and $parts[$i+1] -is [Management.Automation.Language.StringConstantExpressionAst]
  if($key -in @('VerifyOnly','ApplyPolicy','Restore','SyncOnly','NonInteractive')){if($hasLiteral){throw 'unexpected switch value'};$values[$key]=$true}
  else{if(-not $hasLiteral){throw 'missing literal value'};$i++;$values[$key]=$parts[$i].Value}
 }
 return $values
}
