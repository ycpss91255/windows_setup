#Requires -Version 5.1
param([ValidatePattern('^[a-fA-F0-9-]{36}$')][string]$VerificationRunId=([guid]::NewGuid().ToString()),[string]$ExpectedUserSID)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'entry_os_boundary.ps1')
$currentSID=Get-SetupEntryIdentity
if($ExpectedUserSID -and $ExpectedUserSID -ne $currentSID){throw '提權後帳號已改變，請使用原帳號的管理員權限。'}
. (Join-Path $PSScriptRoot 'paths.ps1')
. (Join-Path $PSScriptRoot 'verification.ps1')
. (Resolve-NucPath 'ssh_firewall.ps1')
Initialize-NucReports
$driverSource=Get-SetupEntryDriverSource -ResultPath (Resolve-NucPath 'Setup-Result.json')
$DriverPackagePath=$driverSource.Path
$confirmation=Get-SetupSavedHardwareConfirmation -ResultPath (Resolve-NucPath 'Setup-Result.json')
$hardware=Get-SetupHardwareProfile -DriverPackagePath $DriverPackagePath @confirmation
if($driverSource.PayloadAbsent){$hardware|Add-Member -NotePropertyName DriverPayloadAbsent -NotePropertyValue $true -Force}
if(-not (Test-SetupEntryAdministrator)){
 $command="& '"+$PSCommandPath.Replace("'","''")+"' -ExpectedUserSID '"+$currentSID+"'"
 $command+=" -VerificationRunId '"+$VerificationRunId+"'"
 Start-SetupEntryElevated -Command $command;exit
}
. (Resolve-NucPath 'update_stage_library.ps1')
. (Resolve-NucPath 'gui_stage_library.ps1')
. (Join-Path $PSScriptRoot 'verification_library.ps1')
Invoke-SetupVerification -Hardware $hardware -DriverPackagePath $DriverPackagePath -VerificationRunId $VerificationRunId
