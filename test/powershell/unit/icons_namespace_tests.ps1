#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$script:count=0
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw ('FAIL: '+$Name)};$script:count++}
$native=[IO.File]::ReadAllText((Join-Path $root 'modules/desktop/native/desktop_icons.cs'))
$leaf=[IO.File]::ReadAllText((Join-Path $root 'modules/desktop/icons_settings_library.ps1'))
Assert ($native -match '(?m)^namespace WindowsSetupIcons\s*\{' -and $leaf -match "'WindowsSetupIcons[.]Desktop' -as \[type\]" -and $leaf -match '\[WindowsSetupIcons[.]Desktop\]::Capture\(' -and $leaf -match '\[WindowsSetupIcons[.]Desktop\]::Position\(') 'Icons native namespace and leaf guard and calls use the neutral name'
$winps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
foreach($case in 'OldOnly','NewOnly'){
 & $winps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'test/powershell/fixtures/icons_namespace_guard.ps1') -Root $root -Case $case
 Assert ($LASTEXITCODE -eq 0) ('isolated CLR guard: '+$case)
}
Write-Host ('ALL PASS: '+$script:count+' Icons namespace assertions')
