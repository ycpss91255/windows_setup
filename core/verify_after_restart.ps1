#Requires -Version 5.1
param([string]$ExpectedUserSID)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'entry_os_boundary.ps1')
$currentSID=Get-SetupEntryIdentity
if($ExpectedUserSID -and $ExpectedUserSID -ne $currentSID){throw '提權後帳號已改變，請使用原帳號的管理員權限。'}
. (Join-Path $PSScriptRoot 'paths.ps1')
Initialize-NucReports
$driverSource=Get-SetupEntryDriverSource -ResultPath (Resolve-NucPath 'Setup-Result.json')
$DriverPackagePath=$driverSource.Path
$confirmation=Get-SetupSavedHardwareConfirmation -ResultPath (Resolve-NucPath 'Setup-Result.json')
$hardware=Get-SetupHardwareProfile -DriverPackagePath $DriverPackagePath @confirmation
if($driverSource.PayloadAbsent){$hardware|Add-Member -NotePropertyName DriverPayloadAbsent -NotePropertyValue $true -Force}
$skippedModules=@(@('install_drivers.ps1','apply_amd_privacy_settings.ps1','desktop_icon_layout.ps1')|ForEach-Object {Get-SetupModuleDecision -Module $_ -Hardware $hardware}|Where-Object {-not $_.Applicable})
if(-not (Test-SetupEntryAdministrator)){
 $command="& '"+$PSCommandPath.Replace("'","''")+"' -ExpectedUserSID '"+$currentSID+"'"
 Start-SetupEntryElevated -Command $command;exit
}
& (Resolve-NucPath 'test_setup_prerequisites.ps1') -DriverPackagePath $DriverPackagePath -InstalledDriverState:([bool]$driverSource.PayloadAbsent) @confirmation
if(($hardware.DriverProfileId -or $hardware.IsNuc8) -and $DriverPackagePath){$hardware|Add-Member -NotePropertyName DriverSelection -NotePropertyValue (New-SetupDriverSelection -PackageRoot $script:NucPackageRoot -DriverPackagePath $DriverPackagePath) -Force}
# 本機續跑沿用原選擇紀錄，避免把本機保存清單的位置寫成下次的驅動包位置。
if($driverSource.Selection -and $hardware.DriverSelection){$hardware.DriverSelection=$driverSource.Selection}
. (Resolve-NucPath 'after_restart_library.ps1')
Invoke-SetupAfterRestart -Hardware $hardware -DriverPackagePath $DriverPackagePath -Confirmation $confirmation -SkippedModules $skippedModules -DriverChoice (Get-SetupSavedDriverChoice -ResultPath (Resolve-NucPath 'Setup-Result.json') -Hardware $hardware)
