#Requires -Version 5.1
param([switch]$AfterRestart,[switch]$VerifyOnly,[string]$DriverPackagePath,[string]$ConfirmedBoard,[string]$ConfirmationComputer,[switch]$NonInteractive)
$ErrorActionPreference='Stop'
if($AfterRestart -and $VerifyOnly){throw 'AfterRestart 與 VerifyOnly 不可同時指定。'}
$entry=if($AfterRestart){'verify_after_restart.ps1'}elseif($VerifyOnly){'verify_only.ps1'}else{'configure_setup.ps1'}
if($AfterRestart -or $VerifyOnly){
 if($DriverPackagePath -or $ConfirmedBoard -or $ConfirmationComputer){throw '重開後／只驗證使用同機紀錄的驅動選擇；如要重新選擇請執行一般 Windows 入口。'}
 & (Join-Path $PSScriptRoot $entry)
}else{
 . (Join-Path $PSScriptRoot 'hardware.ps1')
 $request=Select-SetupDriverRequest -PackageRoot (Split-Path -Parent $PSScriptRoot) -DriverPackagePath $DriverPackagePath -PathSpecified:$PSBoundParameters.ContainsKey('DriverPackagePath') -ConfirmedBoard $ConfirmedBoard -ConfirmationComputer $ConfirmationComputer -Interactive:((Test-SetupInteractiveHost) -and -not $NonInteractive)
 & (Join-Path $PSScriptRoot $entry) -DriverPackagePath $request.DriverPackagePath -ConfirmedBoard $request.ConfirmedBoard -ConfirmationComputer $request.ConfirmationComputer -NonInteractive:$NonInteractive
}