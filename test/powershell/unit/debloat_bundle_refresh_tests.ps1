#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'modules/debloat/debloat_library.ps1')
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
$id='Microsoft.Copilot';$family=$id+'_fixture'
$bundle=[pscustomobject]@{Name=$id;PackageFullName=($id+'_5.0.0.0_neutral_~_fixture');PackageFamilyName=$family;IsBundle=$true}
$main=[pscustomobject]@{Name=$id;PackageFullName=($id+'_1.0.0.0_x64__fixture');PackageFamilyName=$family;IsBundle=$false}
$script:state=@($bundle,$main);$script:calls=@();$script:reads=0;$script:fail=''
function Get-AppxPackage {param([switch]$AllUsers,$PackageTypeFilter) if(-not $AllUsers){throw 'all users required'};$script:reads++;if($script:fail -eq 'refresh' -and $script:reads -gt 1){throw 'fixture refresh failure'};return $script:state}
function Get-AppxProvisionedPackage {param([switch]$Online) @()}
function Remove-AppxPackage {param($Package,[switch]$AllUsers) if(-not $AllUsers){throw 'all users required'};$script:calls+=$Package;if($script:fail -eq 'remove'){throw 'fixture bundle failure'};if($script:fail -ne 'stale'){$script:state=@($script:state|Where-Object {$_.PackageFullName -cne $Package})}}
function Remove-AppxProvisionedPackage {throw 'unexpected provisioned removal'}
function Get-Item {throw 'registry forbidden'}
$result=Invoke-SetupDebloatMissingApps -AppIds @($id)
Assert ($result.Success -and $script:reads -ge 2 -and $script:calls.Count -eq 2 -and $script:calls[0] -ceq $bundle.PackageFullName -and $script:calls[1] -ceq $main.PackageFullName) '不同版本 bundle 完成後重新查詢再處理殘留 main'
foreach($mode in @('remove','refresh','stale')){
 $script:state=@($bundle,$main);$script:calls=@();$script:reads=0;$script:fail=$mode
 $result=Invoke-SetupDebloatMissingApps -AppIds @($id)
 Assert (-not $result.Success -and $script:calls.Count -eq 1 -and $script:calls[0] -ceq $bundle.PackageFullName) ('bundle 失敗、重查失敗或仍存在不得猜測移除 main '+$mode)
}