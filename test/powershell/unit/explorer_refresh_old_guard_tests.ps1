#Requires -Version 5.1
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot '../fixtures/explorer_refresh_guard_fixture.ps1') -Case OldOnly
