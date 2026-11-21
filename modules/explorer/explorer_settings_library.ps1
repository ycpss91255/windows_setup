#Requires -Version 5.1
# Definitions only; registry, shell and native work begins only in the named invocation.
function Invoke-SetupExplorerNotification {
 if(-not ('WindowsSetupExplorerRefresh' -as [type])){Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class WindowsSetupExplorerRefresh{[DllImport("shell32.dll")]public static extern void SHChangeNotify(int e,uint f,IntPtr a,IntPtr b);}'}
 [WindowsSetupExplorerRefresh]::SHChangeNotify(0x08000000,0,[IntPtr]::Zero,[IntPtr]::Zero)
}
function Get-SetupExplorerShellOptions {
 param([string]$ModuleRoot,[switch]$Apply)
 if(-not ('NucExplorerLiveV2' -as [type])){Add-Type -Path (Join-Path $ModuleRoot 'native/explorer.cs')}
 [NucExplorerLiveV2]::Options([bool]$Apply)
}
function New-SetupExplorerShell {New-Object -ComObject Shell.Application}
function Invoke-SetupExplorerSettings {
 param([Parameter(Mandatory=$true)][string]$ModuleRoot,[switch]$VerifyOnly)
 $ErrorActionPreference='Stop'
 $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\explorer\Advanced'
 if(-not $VerifyOnly){
  if(-not(Test-Path $key)){New-Item $key -Force|Out-Null}
  Set-ItemProperty $key -Name Hidden -Value 1|Out-Null
  Set-ItemProperty $key -Name ShowSuperHidden -Value 0|Out-Null
  Set-ItemProperty $key -Name HideFileExt -Value 0|Out-Null
  Invoke-SetupExplorerNotification
 }
 $shellOptions=Get-SetupExplorerShellOptions -ModuleRoot $ModuleRoot -Apply:(-not $VerifyOnly)
 $shellHidden=($shellOptions -band 1) -ne 0
 $shellExtensions=($shellOptions -band 2) -ne 0
 if(-not $VerifyOnly){
  $shell=New-SetupExplorerShell
  foreach($window in @($shell.Windows())){try{if($window.FullName -match 'explorer.exe$'){$window.Refresh()}}catch{Write-Warning '有一個檔案總管視窗無法立即重新整理。'}}
 }
 $actual=Get-ItemProperty $key
 $result=[ordered]@{Success=($actual.Hidden -eq 1 -and $actual.ShowSuperHidden -eq 0 -and $actual.HideFileExt -eq 0 -and $shellHidden -and $shellExtensions);ShellShowsHidden=$shellHidden;ShellShowsExtensions=$shellExtensions;ShowFileExtensions=($actual.HideFileExt -eq 0);ShowHiddenFiles=($actual.Hidden -eq 1);HideProtectedSystemFiles=($actual.ShowSuperHidden -eq 0);CheckedAt=(Get-Date).ToString('o');Error=$null}
 if(-not $result.Success){$result.Error='隱藏檔案或副檔名顯示設定驗證失敗。'}
 return [pscustomobject]$result
}