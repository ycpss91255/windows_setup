#Requires -Version 5.1
#Requires -RunAsAdministrator
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ssh_firewall.ps1')
& (Join-Path $PSScriptRoot 'initialize_ssh_client.ps1')
$capability=Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
if($capability.State -ne 'Installed'){
 Write-Host '正在安裝 OpenSSH Server；若元件尚未快取，需要連網下載。' -ForegroundColor Cyan
 $result=Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
 if($result.RestartNeeded){throw 'SSH 元件需要重新開機後才能繼續設定。'}
}
Set-Service sshd -StartupType Automatic
Start-Service sshd
Set-SetupSSHFirewallRule
if((Get-Service sshd).Status -ne 'Running'){throw 'SSH 服務尚未正常啟動。'}
Write-Host 'SSH 已啟動、設為自動啟動，防火牆僅允許本機子網路。' -ForegroundColor Green


& (Join-Path $PSScriptRoot 'apply_lan_ping_settings.ps1')
& (Join-Path $PSScriptRoot 'apply_mdns_settings.ps1')|Out-Null


& (Join-Path $PSScriptRoot 'apply_hosts_sync.ps1')
. (Join-Path $PSScriptRoot 'connection_info_library.ps1')
Get-SetupSshConnectionInfo|ForEach-Object {Write-Host $_}
