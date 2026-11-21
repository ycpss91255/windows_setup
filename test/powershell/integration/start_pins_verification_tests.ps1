#Requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'core/verification_library.ps1'),[ref]$t,[ref]$e)
$aggregate=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-SetupVerification'},$true)
$calls=@($aggregate.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Add-SetupStartVerificationCheck'},$true))
$input=@($aggregate.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Resolve-NucPath' -and $n.Extent.Text -match 'apply_input_method_settings[.]ps1'},$true))
$amd=@($aggregate.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Resolve-NucPath' -and $n.Extent.Text -match 'apply_amd_privacy_settings[.]ps1'},$true))
Assert ($e.Count -eq 0 -and $calls.Count -eq 1 -and $amd.Count -eq 1 -and $input.Count -eq 1 -and $amd[0].Extent.StartOffset -lt $calls[0].Extent.StartOffset -and $calls[0].Extent.StartOffset -lt $input[0].Extent.StartOffset -and $calls[0].Extent.Text -match '\-PackageRoot\s+\$script:NucPackageRoot') 'actual aggregate invokes named Start boundary once between AMD and input'
. (Join-Path $repo 'core/verification_library.ps1')
$fixture=Join-Path $env:TEMP ('start_verify_'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $fixture
$entry=Join-Path $fixture 'start.ps1';[IO.File]::WriteAllText($entry,'param([switch]$VerifyOnly,[switch]$ApplyPolicy);if(-not $VerifyOnly -or $ApplyPolicy){throw "verification attempted mutation"};$global:startVerifiedCall=$true;$global:startVerificationFixture')
function Resolve-NucPath {param($Name) $entry}
function Invoke-SetupGuiFreshVerification {param($PackageRoot,$Role) if($Role -cne 'Start' -or $PackageRoot -cne $fixture){throw 'unexpected private verification target'};$script:calls++;$global:startVerifiedCall=$true;if($script:throwFixture){throw 'fixture fresh failure'};$global:startVerificationFixture}
function Add-Check {param($Name,$Passed,$Detail) $script:checks.Add([pscustomobject]@{Name=$Name;Passed=$Passed;Detail=$Detail})}
foreach($status in @('PendingSignIn','LegacyPendingApply','ConfirmedBad','Confirmed','MissingPin','Exception')){
 $global:startVerificationFixture=[pscustomobject]@{Success=($status -in @('ConfirmedBad','Confirmed','MissingPin'));Status=$(if($status -in @('ConfirmedBad','Confirmed','MissingPin')){'Confirmed'}else{$status});PinCount=$(if($status -eq 'MissingPin'){$null}elseif($status -eq 'Confirmed'){0}else{1})}
 $script:calls=0;$script:throwFixture=($status -eq 'Exception');$script:checks=New-Object 'Collections.Generic.List[object]'
 Add-SetupStartVerificationCheck -PackageRoot $fixture
 Assert ($script:calls -eq 1 -and $script:checks.Count -eq 1 -and $script:checks[0].Name -ceq '開始選單釘選清空' -and $script:checks[0].Passed -eq ($status -eq 'Confirmed') -and (($status -ne 'Exception') -or $script:checks[0].Detail -ceq 'fixture fresh failure')) ('named aggregate preserves fresh call and failure result '+$status)
}
$script:throwFixture=$false
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'core/after_restart_library.ps1'),[ref]$t,[ref]$e)
$retry=$ast.FindAll({param($a) $a -is [Management.Automation.Language.TryStatementAst] -and $a.Extent.Text.Contains("if(`$file -eq 'install_drivers.ps1')")},$true)|Select-Object -First 1
$file='apply_start_menu_settings.ps1';$errors=@();$remaining=@();$global:startVerifiedCall=$false
& ([scriptblock]::Create($retry.Extent.Text))
Assert ($global:startVerifiedCall) 'AfterRestart Start retry only verifies and cannot apply policy'
