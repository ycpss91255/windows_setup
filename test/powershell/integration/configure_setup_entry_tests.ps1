#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$fixture=Join-Path $env:TEMP ('configure_setup_fixture_'+[guid]::NewGuid().ToString('N'))
$core=Join-Path $fixture 'package/core';$init=Join-Path $fixture 'package/modules/init';$program=Join-Path $fixture 'programdata';$logs=Join-Path $fixture 'logs'
foreach($dir in @($core,$init,$program,$logs)){[void][IO.Directory]::CreateDirectory($dir)}
$utf=New-Object Text.UTF8Encoding($true)
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
function SamePath([string]$Left,[string]$Right){if(-not [IO.Path]::IsPathRooted($Left) -or -not [IO.Path]::IsPathRooted($Right)){return $false};try{return [string]::Equals([IO.Path]::GetFullPath($Left),[IO.Path]::GetFullPath($Right),[StringComparison]::OrdinalIgnoreCase)}catch{return $false}}
Assert (SamePath (Join-Path $core './sample.ps1') (Join-Path $core 'sample.ps1')) 'equivalent rooted fixture path accepted'
Assert (-not(SamePath (Join-Path $core 'other.ps1') (Join-Path $core 'sample.ps1'))) 'different fixture path rejected'
Assert (-not(SamePath 'sample.ps1' (Join-Path $core 'sample.ps1'))) 'relative fixture path rejected'
$legacy=Join-Path $core 'configure_nuc.ps1';$canonical=Join-Path $core 'configure_setup.ps1'
Copy-Item -LiteralPath (Join-Path $root 'core/configure_nuc.ps1') -Destination $legacy
if(Test-Path -LiteralPath (Join-Path $root 'core/configure_setup.ps1')){Copy-Item -LiteralPath (Join-Path $root 'core/configure_setup.ps1') -Destination $canonical}
Assert (Test-Path -LiteralPath $canonical -PathType Leaf) 'canonical configure entry exists'
[IO.File]::WriteAllText((Join-Path $core 'entry_os_boundary.ps1'),@'
function Get-SetupEntryIdentity {[IO.File]::WriteAllText((Join-Path $env:FIXTURE_LOG 'identity.txt'),'called');'fixture-sid'}
function Test-SetupEntryAdministrator {$env:FIXTURE_ADMIN -eq 'true'}
function Start-SetupEntryElevated {param($Command) [IO.File]::WriteAllText((Join-Path $env:FIXTURE_LOG 'elevation.txt'),$Command)}
'@,$utf)
[IO.File]::WriteAllText((Join-Path $core 'paths.ps1'),@'
$script:NucPackageRoot=Split-Path $PSScriptRoot -Parent
function Add-FixtureEvent([string]$Name){Add-Content -LiteralPath (Join-Path $env:FIXTURE_LOG 'events.txt') -Value $Name -Encoding UTF8}
function Initialize-NucReports {Add-FixtureEvent 'reports'}
function Get-SetupHardwareProfile {param($DriverPackagePath,$ConfirmedBoard,$ConfirmationComputer) Add-FixtureEvent 'hardware';@{IsNuc8=$false;DriverProfileId=''}}
function Resolve-NucPath {param($Name) if($Name -notin @('test_setup_prerequisites.ps1','configuration_library.ps1')){throw 'unexpected resolver name'};Join-Path $PSScriptRoot $Name}
function New-SetupDriverSelection {param($PackageRoot,$DriverPackagePath) throw 'unexpected driver selection'}
'@,$utf)
[IO.File]::WriteAllText((Join-Path $init 'provisioning_library.ps1'),@'
function Invoke-InitWindowsCheckpoint {param($StageRoot) if($StageRoot -ne (Join-Path $env:ProgramData 'windows_setup_init')){throw 'unexpected stage root'};Add-FixtureEvent 'checkpoint'}
'@,$utf)
[IO.File]::WriteAllText((Join-Path $core 'test_setup_prerequisites.ps1'),@'
param($DriverPackagePath,$ConfirmedBoard,$ConfirmationComputer)
Add-FixtureEvent 'prereq'
if($env:FIXTURE_FAIL -eq 'prereq'){throw 'fixture prereq failure'}
'@,$utf)
[IO.File]::WriteAllText((Join-Path $core 'configuration_library.ps1'),@'
function Invoke-SetupConfiguration {param($Hardware,$UserName,$AutoLogonPassword,$DriverPackagePath,$ConfirmedBoard,$ConfirmationComputer,[switch]$NonInteractive)
 Add-FixtureEvent 'configuration'
 if($env:FIXTURE_FAIL -eq 'configuration'){throw 'fixture configuration failure'}
 @{User=$UserName;PasswordMatches=($AutoLogonPassword -ceq 'fixture-secret');Driver=$DriverPackagePath;Board=$ConfirmedBoard;Computer=$ConfirmationComputer;NonInteractive=$NonInteractive.IsPresent}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $env:FIXTURE_LOG 'configuration.json') -Encoding UTF8
}
'@,$utf)
$wrapper=Join-Path $fixture 'wrapper.ps1'
[IO.File]::WriteAllText($wrapper,@'
param($Entry,$Sid,$Driver,$Board,$Computer,$User,[switch]$OmitDriver,[switch]$NonInteractive)
$ErrorActionPreference='Stop'
function global:Start-Process {throw 'blocked Start-Process'}
function global:Add-Type {throw 'blocked Add-Type'}
function global:Get-ItemProperty {throw 'blocked registry'}
function global:Set-ItemProperty {throw 'blocked registry'}
function global:New-ItemProperty {throw 'blocked registry'}
function global:Remove-ItemProperty {throw 'blocked registry'}
function global:Get-Service {throw 'blocked service'}
function global:Set-Service {throw 'blocked service'}
function global:Start-Service {throw 'blocked service'}
function global:Stop-Service {throw 'blocked service'}
function global:Register-ScheduledTask {throw 'blocked task'}
function global:Start-ScheduledTask {throw 'blocked task'}
function global:Get-LocalUser {throw 'blocked account'}
function global:New-LocalUser {throw 'blocked account'}
function global:Set-LocalUser {throw 'blocked account'}
function global:Remove-LocalUser {throw 'blocked account'}
function global:Add-LocalGroupMember {throw 'blocked account'}
function global:Remove-LocalGroupMember {throw 'blocked account'}
function global:Install-ProvisioningPackage {throw 'blocked package'}
function global:Remove-ProvisioningPackage {throw 'blocked package'}
function global:Restart-Computer {throw 'blocked reboot'}
function global:Add-WindowsCapability {throw 'blocked capability'}
$arguments=@{UserName=$User;AutoLogonPassword='fixture-secret';ExpectedUserSID=$Sid;ConfirmedBoard=$Board;ConfirmationComputer=$Computer;NonInteractive=$NonInteractive}
if(-not $OmitDriver){$arguments.DriverPackagePath=$env:FIXTURE_DRIVER}
& $Entry @arguments
'@,$utf)
$oldTemp=$env:TEMP;$oldTmp=$env:TMP;$oldProgram=$env:ProgramData;$oldLog=$env:FIXTURE_LOG;$oldAdmin=$env:FIXTURE_ADMIN;$oldFail=$env:FIXTURE_FAIL;$oldDriver=$env:FIXTURE_DRIVER
try{
 $env:TEMP=$fixture;$env:TMP=$fixture;$env:ProgramData=$program;$env:FIXTURE_LOG=$logs
 foreach($entry in @($canonical,$legacy)){
  foreach($case in @('admin','sid','elevation','prereq','configuration','user_mismatch','driver_empty','driver_omitted')){
   foreach($file in @('events.txt','elevation.txt','configuration.json','identity.txt')){$target=Join-Path $logs $file;if(Test-Path -LiteralPath $target){[IO.File]::Delete($target)}}
   $env:FIXTURE_ADMIN=if($case -eq 'elevation'){'false'}else{'true'};$env:FIXTURE_FAIL=if($case -in @('prereq','configuration')){$case}else{''}
   $sid=if($case -eq 'sid'){'other-sid'}else{'fixture-sid'};$driver=Join-Path $fixture "driver ' 中文";$output=Join-Path $logs 'child.log'
   $user=if($case -eq 'user_mismatch'){$env:USERNAME+'_other'}else{$env:USERNAME};if($case -in @('driver_empty','driver_omitted')){$driver=''}
   $env:FIXTURE_DRIVER=$driver;$arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$wrapper,'-Entry',$entry,'-Sid',$sid,'-Board','board','-Computer','computer','-User',$user,'-NonInteractive');if($case -eq 'driver_omitted'){$arguments+='-OmitDriver'}
   $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$priorPreference=$ErrorActionPreference;$ErrorActionPreference='Continue'
   try{& $powershell @arguments *> $output;$exit=$LASTEXITCODE}finally{$ErrorActionPreference=$priorPreference}
   $events=Join-Path $logs 'events.txt';$capture=Join-Path $logs 'elevation.txt';$data=Join-Path $logs 'configuration.json';$childText=Get-Content -LiteralPath $output -Raw
   if($case -eq 'sid'){Assert ($exit -ne 0 -and (Test-Path (Join-Path $logs 'identity.txt')) -and $childText.Contains('提權後帳號已改變') -and -not(Test-Path $events) -and -not(Test-Path $capture) -and -not(Test-Path $data)) 'wrong SID stops before fixture effects';continue}
   if($case -eq 'elevation'){
    Assert ($exit -eq 0 -and (Test-Path $capture) -and -not(Test-Path $data)) 'fake elevation captured without configuration'
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($capture),[ref]$tokens,[ref]$errors);$statements=@($ast.EndBlock.Statements)
    Assert ($errors.Count -eq 0 -and $statements.Count -eq 1 -and $statements[0] -is [Management.Automation.Language.PipelineAst] -and $statements[0].PipelineElements.Count -eq 1) 'captured elevation is one command'
    $cmd=$statements[0].PipelineElements[0];Assert ($cmd -is [Management.Automation.Language.CommandAst] -and $cmd.InvocationOperator -eq 'Ampersand' -and $cmd.Redirections.Count -eq 0) 'captured elevation uses literal invocation without redirection'
    $parts=@($cmd.CommandElements);Assert ($parts[0] -is [Management.Automation.Language.StringConstantExpressionAst] -and (SamePath $parts[0].Value $canonical) -and -not(SamePath $parts[0].Value (Join-Path $core 'other.ps1'))) 'captured target is only canonical fixture entry'
    $values=@{};for($i=1;$i -lt $parts.Count;$i++){if($parts[$i] -isnot [Management.Automation.Language.CommandParameterAst] -or $parts[$i].Argument){throw 'unexpected captured argument'};$key=$parts[$i].ParameterName;if($key -notin @('ExpectedUserSID','DriverPackagePath','ConfirmedBoard','ConfirmationComputer','NonInteractive') -or $values.ContainsKey($key)){throw 'unexpected captured parameter'};if($i+1 -lt $parts.Count -and $parts[$i+1] -is [Management.Automation.Language.StringConstantExpressionAst]){$i++;$values[$key]=$parts[$i].Value}else{$values[$key]=$true}}
    Assert ($values.ExpectedUserSID -ceq 'fixture-sid' -and (SamePath $values.DriverPackagePath $driver) -and $values.ConfirmedBoard -ceq 'board' -and $values.ConfirmationComputer -ceq 'computer' -and $values.NonInteractive -and -not $values.ContainsKey('UserName') -and -not $values.ContainsKey('AutoLogonPassword')) 'captured literal flags preserve original elevation contract';continue
   }
   if($case -in @('prereq','configuration')){Assert ($exit -ne 0 -and $childText.Contains('fixture '+$case+' failure') -and -not(Test-Path $data)) ('fixture failure propagates '+$case);continue}
   if($case -eq 'user_mismatch'){Assert ($exit -ne 0 -and $childText.Contains('自動登入帳號必須與目前執行帳號相同') -and -not(Test-Path $data)) 'different user rejected before configuration';continue}
   Assert ($exit -eq 0 -and (Test-Path $data)) 'admin entry reaches fake configuration'
   $result=Get-Content -LiteralPath $data -Raw|ConvertFrom-Json;$order=@(Get-Content -LiteralPath $events)
   $driverMatches=if($driver){SamePath $result.Driver $driver}else{[string]::IsNullOrEmpty($result.Driver)}
   Assert ($result.User -ceq $env:USERNAME -and $result.PasswordMatches -and $driverMatches -and $result.Board -ceq 'board' -and $result.Computer -ceq 'computer' -and $result.NonInteractive) 'admin arguments reach fixed fake unchanged'
   Assert (($order -join ',') -ceq 'reports,hardware,checkpoint,prereq,configuration') 'fixture effects retain order and count'
  }
 }
 $mapping=Get-Content -LiteralPath (Join-Path $root 'core/paths.json') -Raw|ConvertFrom-Json
 Assert ($mapping.'configure_setup.ps1' -ceq 'core/configure_setup.ps1' -and $mapping.'Configure-NUC.ps1' -ceq 'core/configure_nuc.ps1') 'canonical and legacy mappings retained'
 $prereqText=[IO.File]::ReadAllText((Join-Path $root 'core/test_setup_prerequisites.ps1'))
 Assert ($prereqText.Contains("'configure_setup.ps1'") -and $prereqText.Contains("'configure_nuc.ps1'")) 'preflight requires both canonical and compatibility entries'
 $cmdText=[IO.File]::ReadAllText((Join-Path $root 'core/run_setup.cmd'))
 Assert ($cmdText -match '(?im)^powershell\.exe\s+.*-File\s+"%~dp0configure_setup\.ps1"\s*$') 'command entry selects canonical configure script'
 $startFixture=Join-Path $fixture 'start';[void][IO.Directory]::CreateDirectory($startFixture)
 Copy-Item -LiteralPath (Join-Path $root 'core/start_windows.ps1') -Destination $startFixture
 [IO.File]::WriteAllText((Join-Path $startFixture 'hardware.ps1'),@'
function Test-SetupInteractiveHost {$false}
function Select-SetupDriverRequest {param($PackageRoot,$DriverPackagePath,$PathSpecified,$ConfirmedBoard,$ConfirmationComputer,$Interactive) @{DriverPackagePath=$DriverPackagePath;ConfirmedBoard=$ConfirmedBoard;ConfirmationComputer=$ConfirmationComputer}}
'@,$utf)
 [IO.File]::WriteAllText((Join-Path $startFixture 'configure_setup.ps1'),@'
param($DriverPackagePath,$ConfirmedBoard,$ConfirmationComputer,[switch]$NonInteractive)
@{Driver=$DriverPackagePath;Board=$ConfirmedBoard;Computer=$ConfirmationComputer;NonInteractive=$NonInteractive.IsPresent}|ConvertTo-Json -Compress|Set-Content -LiteralPath $env:FIXTURE_START_CAPTURE -Encoding UTF8
'@,$utf)
 foreach($entryName in @('verify_only.ps1','verify_after_restart.ps1')){[IO.File]::WriteAllText((Join-Path $startFixture $entryName),"throw 'unexpected verify dispatch'",$utf)}
 $oldStart=$env:FIXTURE_START_CAPTURE;$env:FIXTURE_START_CAPTURE=Join-Path $logs 'start.json'
 try{
  $startDriver=Join-Path $fixture 'start-driver';& (Join-Path $startFixture 'start_windows.ps1') -DriverPackagePath $startDriver -ConfirmedBoard 'board' -ConfirmationComputer 'computer' -NonInteractive
  $startResult=Get-Content -LiteralPath $env:FIXTURE_START_CAPTURE -Raw|ConvertFrom-Json
  Assert ((SamePath $startResult.Driver $startDriver) -and $startResult.Board -ceq 'board' -and $startResult.Computer -ceq 'computer' -and $startResult.NonInteractive) 'start entry selects canonical fixture and forwards driver flags'
  foreach($flag in @('AfterRestart','VerifyOnly')){$flags=@{};$flags[$flag]=$true;$rejected=$false;try{& (Join-Path $startFixture 'start_windows.ps1') @flags -ConfirmedBoard 'board'}catch{$rejected=$true};Assert $rejected ('verification route rejects new confirmation '+$flag)}
 }finally{$env:FIXTURE_START_CAPTURE=$oldStart}
} finally {$env:TEMP=$oldTemp;$env:TMP=$oldTmp;$env:ProgramData=$oldProgram;$env:FIXTURE_LOG=$oldLog;$env:FIXTURE_ADMIN=$oldAdmin;$env:FIXTURE_FAIL=$oldFail;$env:FIXTURE_DRIVER=$oldDriver}
