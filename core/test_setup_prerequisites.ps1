#Requires -Version 5.1
param([switch]$PackageOnly,[ValidateSet('Auto','Generic','NUC8')][string]$HardwareProfile='Auto',[string]$DriverPackagePath,[string]$ConfirmedBoard,[string]$ConfirmationComputer)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'paths.ps1')
foreach($entry in @('init.cmd','windows.cmd','readme.md')){if(-not(Test-Path -LiteralPath (Join-Path $script:NucPackageRoot $entry) -PathType Leaf)){throw ('缺少根目錄入口或說明：'+$entry)}}
$config=[IO.File]::ReadAllText((Resolve-NucPath 'configuration_library.ps1'))
$modules=@('apply_autologon_settings.ps1')+@([regex]::Matches($config,"File='([^']+\.ps1)'" )|ForEach-Object {$_.Groups[1].Value})
if($modules.Count -ne 19 -or @($modules|Select-Object -Unique).Count -ne 19){throw '模組清單不是 19 個不重複項目。'}
$required=$modules+@('paths.ps1','entry_os_boundary.ps1','prerequisites_library.ps1','verification.ps1','paths.json','start_windows.ps1','initialize_nuc.ps1','oobe_library.ps1','cleanup_oobe.ps1','run_module.ps1','Autologon64.exe','finalize_taskbar.ps1','desktop_layout.json','desktop_safety.ps1','terminal_hotkey_listener.ps1','remove_one_drive.ps1','initialize_ssh_client.ps1','ssh_firewall.ps1','apply_lan_ping_settings.ps1','lan_ping_library.ps1','apply_hosts_sync.ps1','CustomHostsSync\network_sites.ps1','CustomHostsSync\sync_custom_hosts.ps1','CustomHostsSync\watch_custom_hosts.ps1','CustomHostsSync\sites.json','CustomHostsSync\hosts_readme.md','CustomHostsSync\ssh_readme.md','debloat_library.ps1','debloat_apps.txt','debloat_profile.json','win11debloat\Win11Debloat.ps1','verify_only.ps1','audit_nuc.ps1')
$required+=@('start_pins_policy_library.ps1','start_pins_asset_library.ps1','provisioning_library.ps1','provisioning_asset_library.ps1','provisioning_launcher_library.ps1')
$required+=@('amd_privacy_library.ps1','driver_archive_library.ps1','driver_plan_library.ps1','driver_installation_library.ps1','gui_stage_library.ps1','gui_worker.ps1','explorer_settings_library.ps1','display_settings_library.ps1','theme_settings_library.ps1','taskbar_settings_library.ps1','taskbar.cs','taskbar_stage_library.ps1','start_menu_settings_library.ps1','desktop_settings_library.ps1','icons_settings_library.ps1','after_restart_library.ps1','configuration_library.ps1','terminal_hotkey_library.ps1','one_drive_library.ps1','update_stage_library.ps1','update_progress_library.ps1','update_worker_library.ps1','update_entry_library.ps1','update_callback.cs','uac_library.ps1','apply_uac_settings.ps1','apply_uac_settings.cmd','managed_source_library.ps1','desktop_icons.cs','display.cs','explorer.cs','theme.cs','terminal_hotkey.cs','residue_library.ps1','hosts_sync_library.ps1','connection_info_library.ps1','mdns_library.ps1','apply_mdns_settings.ps1','apply_mdns_settings.cmd','mdns_publisher_library.ps1','mdns_worker.ps1','mdns_publisher.cs','verification_library.ps1','privacy_library.ps1','input_method_library.ps1','audit_library.ps1','init_entry_library.ps1','apply_privacy_settings.ps1','apply_privacy_settings.cmd')
foreach($file in $required){if(-not(Test-Path -LiteralPath (Resolve-NucPath $file) -PathType Leaf)){throw ('缺少工具包檔案：'+$file)}}
# Source validation is safe on Server and never calls the client provisioning API.
. (Resolve-NucPath 'start_pins_asset_library.ps1')
$null=Assert-StartPinsAssetSource -AssetRoot (Join-Path $script:NucPackageRoot 'modules/start_menu/assets')
. (Resolve-NucPath 'provisioning_asset_library.ps1')
$null=Assert-InitProvisioningAssetSource -AssetRoot (Join-Path $script:NucPackageRoot 'modules/init/assets')
$scriptFiles=@(Get-ChildItem -LiteralPath (Join-Path $script:NucPackageRoot 'core') -Filter '*.ps1')+@(Get-ChildItem -LiteralPath (Join-Path $script:NucPackageRoot 'modules') -Recurse -Filter '*.ps1'|Where-Object {$_.FullName -notmatch '[\/]Win11Debloat[\/]'})
foreach($file in $scriptFiles){
 $tokens=$null;$errors=$null
 [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ('腳本語法錯誤：'+$file.Name+'；'+$errors[0].Message)}
}
if(-not $PackageOnly -and $HardwareProfile -ne 'Auto'){throw '硬體設定檔覆寫只可用於 PackageOnly 離線檢查。'}
$hardware=if($HardwareProfile -eq 'NUC8'){Get-SetupHardwareProfile -BoardProduct 'NUC8i7HVB'}elseif($HardwareProfile -eq 'Generic'){Get-SetupHardwareProfile -BoardProduct 'Generic'}else{Get-SetupHardwareProfile -ConfirmedBoard $ConfirmedBoard -ConfirmationComputer $ConfirmationComputer}
$payload=Test-SetupDriverPayload -Hardware $hardware -DriverPackagePath $DriverPackagePath
Write-Host ('硬體設定檔：'+$hardware.Name+'；'+$payload.Reason)
if(-not $PackageOnly){
 . (Resolve-NucPath 'prerequisites_library.ps1')
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 Assert-SetupWindowsPrerequisites -UserSid $identity.User -SourceRoot $script:NucPackageRoot
}
Write-Host ('前置檢查通過：19 個模組、必要檔案及 '+$payload.Count+' 個驅動封存檔；帳號及路徑動態取得。') -ForegroundColor Green




