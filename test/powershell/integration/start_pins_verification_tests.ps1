#Requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'core/verification_library.ps1'),[ref]$t,[ref]$e)
$check=$ast.FindAll({param($a) $a -is [Management.Automation.Language.TryStatementAst] -and $a.Extent.Text.Contains('-Role Start')},$true)|Select-Object -Last 1
$fixture=Join-Path $env:TEMP ('start_verify_'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $fixture
$entry=Join-Path $fixture 'start.ps1';[IO.File]::WriteAllText($entry,'param([switch]$VerifyOnly,[switch]$ApplyPolicy);if(-not $VerifyOnly -or $ApplyPolicy){throw "verification attempted mutation"};$global:startVerifiedCall=$true;$global:startVerificationFixture')
function Resolve-NucPath {param($Name) $entry}
function Invoke-SetupGuiFreshVerification {param($PackageRoot,$Role) if($Role -cne 'Start'){throw 'unexpected private verification role'};$global:startVerifiedCall=$true;$global:startVerificationFixture}
function Add-Check {param($Name,$Passed,$Detail) $script:passed=$Passed}
foreach($status in @('PendingSignIn','LegacyPendingApply','ConfirmedBad','Confirmed')){
 $global:startVerificationFixture=[pscustomobject]@{Success=($status -like 'Confirmed*');Status=$(if($status -like 'Confirmed*'){'Confirmed'}else{$status});PinCount=$(if($status -eq 'Confirmed'){0}else{1})}
 & ([scriptblock]::Create($check.Extent.Text))
 Assert ($script:passed -eq ($status -eq 'Confirmed')) ('actual aggregate checks native result instead of absence of throw '+$status)
}
# Exercise only the named retry dispatcher against three fixed TEMP scripts.
. (Join-Path $repo 'core/after_restart_library.ps1')
$dispatchRoot=Join-Path $fixture 'dispatch';[void][IO.Directory]::CreateDirectory($dispatchRoot)
$dummy=@'
param([switch]$VerifyOnly,[switch]$ApplyPolicy,[switch]$NonInteractive,[string]$DriverPackagePath,[string]$ConfirmedBoard,[string]$ConfirmationComputer)
$global:retryCapture=[pscustomobject]@{Name=[IO.Path]::GetFileName($PSCommandPath);BoundNames=@($PSBoundParameters.Keys);VerifyOnly=[bool]$VerifyOnly;ApplyPolicy=[bool]$ApplyPolicy;ApplyPolicyBound=$PSBoundParameters.ContainsKey('ApplyPolicy');NonInteractive=[bool]$NonInteractive;DriverPackagePath=$DriverPackagePath;ConfirmedBoard=$ConfirmedBoard;ConfirmationComputer=$ConfirmationComputer}
if($global:retryFail){throw 'fixture retry failure'}
'fixture-output'
'@
$allowed=@('apply_start_menu_settings.ps1','install_drivers.ps1','apply_power_settings.ps1')
foreach($name in $allowed){[IO.File]::WriteAllText((Join-Path $dispatchRoot $name),$dummy,[Text.UTF8Encoding]::new($true))}
function Resolve-NucPath {param([string]$Name)
 if($Name -cnotin $allowed){throw 'fixture refuses unknown path'}
 $path=[IO.Path]::GetFullPath((Join-Path $dispatchRoot $Name))
 if([IO.Path]::GetDirectoryName($path) -ine [IO.Path]::GetFullPath($dispatchRoot)){throw 'fixture refuses non-TEMP path'}
 return $path
}
function Start-Process {throw 'fixture forbids real process'}
function Register-ScheduledTask {throw 'fixture forbids real task'}
function Set-ItemProperty {throw 'fixture forbids registry writes'}
function New-ItemProperty {throw 'fixture forbids registry writes'}
function Remove-ItemProperty {throw 'fixture forbids registry writes'}
function Add-Type {throw 'fixture forbids native loading'}
$global:retryFail=$false;$global:retryCapture=$null
$out=@(Invoke-SetupAfterRestartRetryDispatch -File 'apply_start_menu_settings.ps1' -DriverPackagePath 'fixture path' -Confirmation @{})
Assert ($global:retryCapture.Name -ceq 'apply_start_menu_settings.ps1' -and $global:retryCapture.VerifyOnly -and -not $global:retryCapture.ApplyPolicy -and -not $global:retryCapture.ApplyPolicyBound -and $global:retryCapture.BoundNames.Count -eq 1 -and $global:retryCapture.BoundNames -contains 'VerifyOnly' -and $out.Count -eq 0) 'AfterRestart Start retry only verifies and cannot apply policy'
$confirmation=@{ConfirmedBoard='fixture-board';ConfirmationComputer='fixture-computer'}
$out=@(Invoke-SetupAfterRestartRetryDispatch -File 'install_drivers.ps1' -DriverPackagePath 'fixture path' -Confirmation $confirmation)
Assert ($global:retryCapture.Name -ceq 'install_drivers.ps1' -and $global:retryCapture.NonInteractive -and $global:retryCapture.DriverPackagePath -ceq 'fixture path' -and $global:retryCapture.ConfirmedBoard -ceq 'fixture-board' -and $global:retryCapture.ConfirmationComputer -ceq 'fixture-computer' -and $global:retryCapture.BoundNames.Count -eq 4 -and $out.Count -eq 1 -and $out[0] -ceq 'fixture-output') 'driver dummy receives exact noninteractive path and confirmation'
$out=@(Invoke-SetupAfterRestartRetryDispatch -File 'apply_power_settings.ps1' -DriverPackagePath 'unused' -Confirmation @{})
Assert ($global:retryCapture.Name -ceq 'apply_power_settings.ps1' -and $global:retryCapture.BoundNames.Count -eq 0 -and $out.Count -eq 1 -and $out[0] -ceq 'fixture-output') 'ordinary retry retains module output'
foreach($name in $allowed){$global:retryFail=$true;$message='';try{Invoke-SetupAfterRestartRetryDispatch -File $name -DriverPackagePath 'fixture path' -Confirmation @{}|Out-Null}catch{$message=$_.Exception.Message};Assert ($message -ceq 'fixture retry failure') ('dispatcher propagates failure: '+$name)}
$global:retryFail=$false;$rejected=$false;try{Invoke-SetupAfterRestartRetryDispatch -File 'unknown.ps1' -Confirmation @{}|Out-Null}catch{$rejected=$_.Exception.Message -eq 'fixture refuses unknown path'}
Assert $rejected 'fixture refuses any unlisted script path'
# Inspect both actual call sites and their original error aggregation without executing the entry.
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'core/after_restart_library.ps1'),[ref]$t,[ref]$e)
$entryFunction=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-SetupAfterRestart'},$true)
$tries=@($entryFunction.FindAll({param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $null -ne $n.Body.Find({param($c) $c -is [Management.Automation.Language.CommandAst] -and $c.GetCommandName() -eq 'Invoke-SetupAfterRestartRetryDispatch'},$true)},$true))
Assert ($e.Count -eq 0 -and $tries.Count -eq 2) 'retry and cleanup each invoke dispatcher inside original try'
foreach($statement in $tries){
 $call=$statement.Body.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-SetupAfterRestartRetryDispatch'},$true)
 $bound=@{};$elements=$call.CommandElements
 for($index=1;$index -lt $elements.Count;$index++){$item=$elements[$index];if($item -isnot [Management.Automation.Language.CommandParameterAst]){continue};if($item.Argument){$bound[$item.ParameterName]=$item.Argument}else{$index++;$bound[$item.ParameterName]=$elements[$index]}}
 $bindingsCorrect=$bound.Count -eq 3
 foreach($pair in @(@('File','file'),@('DriverPackagePath','DriverPackagePath'),@('Confirmation','confirmation'))){$value=$bound[$pair[0]];if($value -isnot [Management.Automation.Language.VariableExpressionAst] -or $value.VariablePath.UserPath -ine $pair[1]){$bindingsCorrect=$false}}
 Assert $bindingsCorrect 'dispatcher receives original file driver path and confirmation variables'
 $assignments=@($statement.CatchClauses[0].Body.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Operator -eq [Management.Automation.Language.TokenKind]::PlusEquals},$true)|ForEach-Object {$_.Left.VariablePath.UserPath})
 $warning=$statement.CatchClauses[0].Body.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Warning'},$true)
 Assert ($statement.CatchClauses.Count -eq 1 -and $assignments -contains 'errors' -and $assignments -contains 'remaining' -and $null -ne $warning) 'outer catch retains errors remaining and warning'
}
$retryLoop=$tries[0].Parent
while($retryLoop -and $retryLoop -isnot [Management.Automation.Language.ForEachStatementAst]){$retryLoop=$retryLoop.Parent}
$driverGuard=$retryLoop.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -match "(?i)\`$file\s+-eq\s+'install_drivers\.ps1'" -and $null -ne $n.Find({param($c) $c -is [Management.Automation.Language.ContinueStatementAst]},$true)},$true)
Assert ($null -ne $driverGuard) 'existing retry loop retains its driver continue guard'
foreach($name in @('Start-Process','Register-ScheduledTask','Set-ItemProperty','New-ItemProperty','Remove-ItemProperty','Add-Type')){Remove-Item -LiteralPath ('Function:\'+$name)}
Remove-Variable retryCapture,retryFail -Scope Global -ErrorAction SilentlyContinue
