#Requires -Version 5.1
# 登入後排程啟動的重開後驗收入口；只從本機保存的 runtime 執行，不需要工具包或驅動包。
param([ValidatePattern('^[A-Fa-f0-9]{64}$')][Parameter(Mandatory=$true)][string]$ManifestSHA256)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'paths.ps1')
. (Resolve-NucPath 'resume_library.ps1')
if(-not (Test-SetupAdministrator)){throw '自動驗收需要排程的最高權限；未提權也不另跳 UAC。請從工具包執行 windows.cmd -AfterRestart。'}
$entry=Join-Path $PSScriptRoot 'verify_after_restart.ps1'
$afterRestart={& $entry}.GetNewClosure()
$null=Invoke-SetupResumeAfterRestart -ManifestSHA256 $ManifestSHA256 -RuntimeRoot (Split-Path $PSScriptRoot -Parent) -AfterRestart $afterRestart
