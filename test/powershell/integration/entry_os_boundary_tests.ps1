#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$temp=Join-Path $env:TEMP ('entry_boundary_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$encoding=New-Object Text.UTF8Encoding($true)
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
try {
 foreach($name in @('configure_setup.ps1','configure_nuc.ps1','verify_after_restart.ps1','verify_only.ps1')){
  Copy-Item -LiteralPath (Join-Path $root ('core/'+$name)) -Destination $temp
 }
 [IO.File]::WriteAllText((Join-Path $temp 'entry_os_boundary.ps1'),"function Get-SetupEntryIdentity { return 'fixture-sid' }`nfunction Test-SetupEntryAdministrator { throw 'unexpected admin check' }`nfunction Start-SetupEntryElevated { throw 'unexpected launch' }",$encoding)
 [IO.File]::WriteAllText((Join-Path $temp 'paths.ps1'),"throw 'fixture paths reached'",$encoding)
 foreach($name in @('configure_setup.ps1','configure_nuc.ps1','verify_after_restart.ps1','verify_only.ps1')){
  $ErrorActionPreference='Continue'
  $output=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $temp $name) -ExpectedUserSID fixture-sid 2>&1 | Out-String
  $ErrorActionPreference='Stop'
  Assert ($LASTEXITCODE -ne 0 -and $output.Contains('fixture paths reached')) ($name+' 使用可隔離身分邊界並在受控路徑停止')
 }
 # Fixture dependencies stop at the administrator boundary before any launch.
 [IO.File]::WriteAllText((Join-Path $temp 'paths.ps1'),@'
function Initialize-NucReports {}
function Start-Process { throw 'fixture blocked process launch' }
function Get-SetupHardwareProfile { param($DriverPackagePath,$ConfirmedBoard,$ConfirmationComputer) return @{} }
function Get-SetupSavedDriverSelection { param($ResultPath) return '' }
function Get-SetupEntryDriverSource { param($ResultPath) return [pscustomobject]@{Path='';PayloadAbsent=$false;Selection=$null} }
function Get-SetupSavedHardwareConfirmation { param($ResultPath) return @{} }
function Get-SetupModuleDecision { param($Module,$Hardware) return @{Applicable=$true} }
function Resolve-NucPath { param($Name) return (Join-Path $PSScriptRoot 'safe.ps1') }
'@,$encoding)
 [IO.File]::WriteAllText((Join-Path $temp 'safe.ps1'),'# safe fixture',$encoding)
 [IO.File]::WriteAllText((Join-Path $temp 'verification.ps1'),'# safe fixture',$encoding)
 foreach($name in @('configure_setup.ps1','configure_nuc.ps1','verify_after_restart.ps1','verify_only.ps1')){
  $ErrorActionPreference='Continue'
  $output=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $temp $name) -ExpectedUserSID fixture-sid 2>&1 | Out-String
  $ErrorActionPreference='Stop'
  Assert ($LASTEXITCODE -ne 0 -and $output.Contains('unexpected admin check')) ($name+' 使用可隔離管理員邊界')
 }
 [IO.File]::WriteAllText((Join-Path $temp 'entry_os_boundary.ps1'),"function Get-SetupEntryIdentity { return 'fixture-sid' }`nfunction Test-SetupEntryAdministrator { return `$false }`nfunction Start-SetupEntryElevated { param(`$Command) throw 'fixture elevation boundary reached' }",$encoding)
 foreach($name in @('configure_setup.ps1','configure_nuc.ps1','verify_after_restart.ps1','verify_only.ps1')){
  $ErrorActionPreference='Continue'
  $output=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $temp $name) -ExpectedUserSID fixture-sid 2>&1 | Out-String
  $ErrorActionPreference='Stop'
  Assert ($LASTEXITCODE -ne 0 -and $output.Contains('fixture elevation boundary reached')) ($name+' 使用可隔離提權啟動邊界')
 }
} finally {if($temp.StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $temp -Recurse -Force}}
