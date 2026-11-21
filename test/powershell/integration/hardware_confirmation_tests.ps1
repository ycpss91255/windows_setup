#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'core/hardware.ps1')
function Assert([bool]$Condition,[string]$Message){Write-Host ('@@ASSERT@@'+(@{Name=$Message;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Message}}
$fixture=Join-Path $env:TEMP ('hardware_confirm_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $fixture|Out-Null
$resultPath=Join-Path $fixture 'result.json'
@{Computer=$env:COMPUTERNAME;UserSID='fixture_sid';HardwareProfile=@{ConfirmedBoard='NUC8i7HVB';ConfirmationComputer=$env:COMPUTERNAME}}|ConvertTo-Json -Depth 5|Set-Content $resultPath -Encoding UTF8
$confirmation=Get-SetupSavedHardwareConfirmation -ResultPath $resultPath -UserSID fixture_sid
Assert ($confirmation.ConfirmedBoard -eq 'NUC8i7HVB') '續跑可恢復本機同帳號明確確認'
Assert ((Get-SetupSavedHardwareConfirmation -ResultPath $resultPath -UserSID different).Count -eq 0) '續跑不沿用其他帳號確認'
Assert ((Get-SetupSavedHardwareConfirmation -ResultPath $resultPath -UserSID fixture_sid -Computer different).Count -eq 0) '續跑不沿用其他電腦確認'
foreach($file in @('core/configure_setup.ps1','core/run_module.ps1','modules/drivers/install_drivers.ps1')){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$tokens,[ref]$errors)
 $elevation=$ast.Find({param($a) $a -is [Management.Automation.Language.IfStatementAst] -and $a.Extent.Text -match 'Start-Process powershell.exe -Verb RunAs|Start-SetupEntryElevated'},$true)
 $fakeEntry=Join-Path $fixture 'target.ps1'
 [IO.File]::WriteAllText($fakeEntry,'param($Module,$ExpectedUserSID,$DriverPackagePath,$ConfirmedBoard,$ConfirmationComputer,[switch]$NonInteractive);[pscustomobject]@{Board=$ConfirmedBoard;Computer=$ConfirmationComputer}',[Text.UTF8Encoding]::new($true))
 $capturedState=@{Args=''}
 function Start-Process {param($FilePath,$Verb,$ArgumentList);$capturedState.Args=$ArgumentList}
 if($file -eq 'core/configure_setup.ps1'){. (Join-Path $root 'core/entry_os_boundary.ps1')}
 $ConfirmedBoard='NUC8i7HVB';$ConfirmationComputer=$env:COMPUTERNAME;$DriverPackagePath='';$currentSID='fixture';$sid=$currentSID;$Module='Install-Drivers';$VerifyOnly=$false;$SyncOnly=$false;$Mode='All'
 $body=$elevation.Clauses[0].Item2.Statements|Where-Object {$_ -isnot [Management.Automation.Language.ExitStatementAst] -and $_ -isnot [Management.Automation.Language.ReturnStatementAst]}|ForEach-Object {$_.Extent.Text}
 & ([scriptblock]::Create(($body -join "`n").Replace('$PSCommandPath','$fakeEntry')))
 $decoded=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($capturedState.Args -split '-EncodedCommand ')[1]))
 $result=& ([scriptblock]::Create($decoded))
 Assert ($result.Board -eq $ConfirmedBoard -and $result.Computer -eq $ConfirmationComputer) ('真提權命令保留本機驅動確認：'+$file)
}# Execute actual downstream invocation ASTs against a capture-only target.
$forwardStub=Join-Path $fixture 'forward.ps1'
[IO.File]::WriteAllText($forwardStub,'param($DriverPackagePath,$ConfirmedBoard,$ConfirmationComputer,[switch]$NonInteractive);[pscustomobject]@{Board=$ConfirmedBoard;Computer=$ConfirmationComputer;Path=$DriverPackagePath}',[Text.UTF8Encoding]::new($true))
function Resolve-NucPath {param($Name);$forwardStub}
$path=$forwardStub;$stage=@{File='install_drivers.ps1'};$file='install_drivers.ps1';$DriverPackagePath='dynamic_driver_path'
foreach($relative in @('core/configure_setup.ps1','core/run_module.ps1','core/verify_after_restart.ps1')){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $relative),[ref]$tokens,[ref]$errors)
 if($relative -eq 'core/run_module.ps1'){$bound=@{DriverPackagePath=$DriverPackagePath};$setup=$ast.FindAll({param($a) ($a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$driverArguments') -or ($a -is [Management.Automation.Language.IfStatementAst] -and $a.Extent.Text -match 'driverArguments.DriverPackagePath')},$true);foreach($statement in $setup){. ([scriptblock]::Create($statement.Extent.Text.Replace('$PSBoundParameters','$bound')))}}
 if($relative -eq 'core/configure_setup.ps1'){$combined=[IO.File]::ReadAllText((Join-Path $root $relative))+[IO.File]::ReadAllText((Join-Path $root 'core/configuration_library.ps1'));$ast=[Management.Automation.Language.Parser]::ParseInput($combined,[ref]$tokens,[ref]$errors)}
 if($relative -eq 'core/verify_after_restart.ps1'){$combined=[IO.File]::ReadAllText((Join-Path $root $relative))+[IO.File]::ReadAllText((Join-Path $root 'core/after_restart_library.ps1'));$ast=[Management.Automation.Language.Parser]::ParseInput($combined,[ref]$tokens,[ref]$errors)}
 $calls=@($ast.FindAll({param($a) $a -is [Management.Automation.Language.CommandAst] -and $a.InvocationOperator -eq 'Ampersand' -and ($a.Extent.Text -match '-DriverPackagePath|@driverArguments')},$true))
 Assert ($calls.Count -eq $(if($relative -eq 'core/verify_after_restart.ps1'){4}elseif($relative -eq 'core/configure_setup.ps1'){2}else{1})) ('完整下游調用數：'+$relative)
 foreach($call in $calls){$result=& ([scriptblock]::Create($call.Extent.Text));Assert ($result.Board -eq 'NUC8i7HVB' -and $result.Computer -eq $env:COMPUTERNAME -and $result.Path -eq $DriverPackagePath) ('真下游呼叫傳遞型號與機器身分：'+$relative)}
}
# Rehydrate and evaluate the real verification profile assignments.
function Resolve-NucPath {param($Name);$resultPath}
function Get-CimInstance {param($ClassName,$ErrorAction);[pscustomobject]@{Product=''}}
function Get-SetupSavedHardwareConfirmation {param($ResultPath);@{ConfirmedBoard='NUC8i7HVB';ConfirmationComputer=$env:COMPUTERNAME}}
foreach($relative in @('core/verify_only.ps1','core/verify_after_restart.ps1')){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $relative),[ref]$tokens,[ref]$errors)
 foreach($name in @('confirmation','hardware')){$statement=$ast.Find({param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq ('$'+$name)},$true);. ([scriptblock]::Create($statement.Extent.Text))}
 Assert ($hardware.DriverBoard -eq 'NUC8i7HVB' -and $hardware.BoardProduct -eq '') ('真驗證入口恢復確認並重新偵測：'+$relative)
}$payload=Join-Path $fixture 'payload'
New-Item -ItemType Directory $payload|Out-Null
$manifest=@(foreach($name in @('Chipset.zip','SerialIO.zip','UCM.zip','GFX-Radeon.zip')){$item=Join-Path $payload $name;[IO.File]::WriteAllText($item,'fixture');@{File=$name;SHA256=(Get-FileHash $item -Algorithm SHA256).Hash}})
$manifest|ConvertTo-Json|Set-Content (Join-Path $payload 'manifest.json') -Encoding UTF8
@{SchemaVersion=1;HardwareProfile='NUC8';Architecture='x64';SupportedBoards=@('NUC8i7HVB','NUC8i7HNB')}|ConvertTo-Json|Set-Content (Join-Path $payload 'package.json') -Encoding UTF8
Assert ((Test-SetupDriverPayload -Hardware $hardware -DriverPackagePath $payload).Status -eq 'Passed') '真payload驗證使用確認DriverBoard，原始未知板號仍保留'
$mixedRejected=$false
try{& (Join-Path $root 'modules/drivers/install_drivers.ps1') -PackageOnly -ConfirmedBoard NUC8i7HNB -ConfirmationComputer $env:COMPUTERNAME -DriverPackagePath $payload}catch{$mixedRejected=$_.Exception.Message -match 'PackageOnly.*手動'}
Assert $mixedRejected '離線驗包拒絕混用手動實機確認，不依假的HVB報衝突'
