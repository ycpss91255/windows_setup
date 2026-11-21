#Requires -Version 5.1
#Requires -RunAsAdministrator
param([switch]$VerifyOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lan_ping_library.ps1')
Invoke-SetupLanPingSettings -VerifyOnly:$VerifyOnly

try{
 . (Join-Path $PSScriptRoot 'mdns_library.ps1')
 Write-Host '正在唯讀觀測目前系統名稱的 .local 解析；這不代表另一臺已可連線。'
 $mdns=Get-SetupMdnsStatus
 Format-SetupMdnsConnectionInfo -Status $mdns | ForEach-Object {Write-Host $_}
}catch{Write-Warning ('名稱觀測無法完成：'+$_.Exception.Message+'；既有 Ping 設定與 IP 連線不受影響。')}
