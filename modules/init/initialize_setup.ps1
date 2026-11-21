#Requires -Version 5.1
param([string]$SshScriptPath,[string]$ExpectedUserSID,[string]$ResumeStatePath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'init_entry_library.ps1')
Invoke-SetupInit -EntryPath $PSCommandPath -ModuleRoot $PSScriptRoot -SshScriptPath $SshScriptPath -ExpectedUserSID $ExpectedUserSID -ResumeStatePath $ResumeStatePath