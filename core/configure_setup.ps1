#Requires -Version 5.1
param([string]$UserName=$env:USERNAME,[string]$AutoLogonPassword,[string]$DriverPackagePath,[string]$ExpectedUserSID,[string]$ConfirmedBoard,[string]$ConfirmationComputer,[string]$SelectionRecord,[switch]$NonInteractive)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'entry_os_boundary.ps1')
$currentSID=Get-SetupEntryIdentity
if($ExpectedUserSID -and $ExpectedUserSID -ne $currentSID){throw '提權後帳號已改變，請使用原帳號的管理員權限。'}
if($DriverPackagePath){$DriverPackagePath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DriverPackagePath)}
. (Join-Path $PSScriptRoot 'paths.ps1')
Initialize-NucReports
$hardware=Get-SetupHardwareProfile -DriverPackagePath $DriverPackagePath -ConfirmedBoard $ConfirmedBoard -ConfirmationComputer $ConfirmationComputer
$skippedModules=@()
if (-not (Test-SetupEntryAdministrator)) {
    $command="& '"+$PSCommandPath.Replace("'","''")+"' -ExpectedUserSID '"+$currentSID+"' -DriverPackagePath '"+$DriverPackagePath.Replace("'","''")+"'"
 if($ConfirmedBoard){$command+=" -ConfirmedBoard '"+$ConfirmedBoard.Replace("'","''")+"' -ConfirmationComputer '"+$ConfirmationComputer.Replace("'","''")+"'"}
 # Only a record in the exact allowed shape may enter the elevated command line.
 if($SelectionRecord -and (ConvertFrom-SetupDriverChoiceRecord -Record $SelectionRecord)){$command+=" -SelectionRecord '"+$SelectionRecord+"'"}
 if($NonInteractive){$command+=' -NonInteractive'}
    Start-SetupEntryElevated -Command $command
    exit
}
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\init\provisioning_library.ps1')
$null=Invoke-InitWindowsCheckpoint -StageRoot (Join-Path $env:ProgramData 'windows_setup_init')
& (Resolve-NucPath 'test_setup_prerequisites.ps1') -DriverPackagePath $DriverPackagePath -ConfirmedBoard $ConfirmedBoard -ConfirmationComputer $ConfirmationComputer
if(($hardware.DriverProfileId -or $hardware.IsNuc8) -and $DriverPackagePath){$hardware|Add-Member -NotePropertyName DriverSelection -NotePropertyValue (New-SetupDriverSelection -PackageRoot $script:NucPackageRoot -DriverPackagePath $DriverPackagePath) -Force}
if($UserName -ine $env:USERNAME){throw '自動登入帳號必須與目前執行帳號相同。'}
. (Resolve-NucPath 'configuration_library.ps1')
. (Join-Path $PSScriptRoot 'resume_library.ps1')
$startedAt=Get-Date
# 有失敗模組時更需要重開後續跑，所以無論本輪結果都嘗試登記；登記只接受本輪產生的同機同帳號結果。
try { Invoke-SetupConfiguration -Hardware $hardware -UserName $UserName -AutoLogonPassword $AutoLogonPassword -DriverPackagePath $DriverPackagePath -ConfirmedBoard $ConfirmedBoard -ConfirmationComputer $ConfirmationComputer -DriverChoice (Resolve-SetupDriverChoice -Record $SelectionRecord -Hardware $hardware) -NonInteractive:$NonInteractive } finally { $AutoLogonPassword=$null;$null=Invoke-SetupResumeRegistration -PackageRoot $script:NucPackageRoot -Hardware $hardware -StartedAt $startedAt }
