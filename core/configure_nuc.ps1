#Requires -Version 5.1
param([string]$UserName=$env:USERNAME,[string]$AutoLogonPassword,[string]$DriverPackagePath,[string]$ExpectedUserSID,[string]$ConfirmedBoard,[string]$ConfirmationComputer,[switch]$NonInteractive)
& (Join-Path $PSScriptRoot 'configure_setup.ps1') @PSBoundParameters