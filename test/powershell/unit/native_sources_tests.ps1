#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'core/paths.ps1')
$script:count=0
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw ('FAIL: '+$Name)};$script:count++}
$cases=@(
 @{Native='modules/ssh/native/mdns_publisher.cs';Script='modules/ssh/mdns_publisher_library.ps1';Type='WindowsSetup.MdnsPublisher';Methods='Begin,NativeConstruct,ReadInstance,NativeFree';Key=$null},
 @{Native='modules/desktop/native/desktop_icons.cs';Script='modules/desktop/icons_settings_library.ps1';Type='NUC8Icons.Desktop';Methods='Capture,Position';Key='desktop_icons.cs'},
 @{Native='modules/display/native/display.cs';Script='modules/display/display_settings_library.ps1';Type='NUC8Display.Display';Methods='Read,Apply,NativeScales,GetDpiForSystem';Key='display.cs'},
 @{Native='modules/explorer/native/explorer.cs';Script='modules/explorer/explorer_settings_library.ps1';Type='NucExplorerLiveV2';Methods='Options';Key='explorer.cs'},
 @{Native='modules/taskbar/native/taskbar.cs';Script='modules/taskbar/taskbar_settings_library.ps1';Type='WindowsSetup.Taskbar';Methods='AutoHide';Key='taskbar.cs'},
 @{Native='modules/theme/native/theme.cs';Script='modules/theme/theme_settings_library.ps1';Type='NUC8Theme';Methods='ObserveTaskbar,TaskbarColor,SetSysColors,ReadWallpaper,GetSysColor,SystemParametersInfo';Key='theme.cs'},
 @{Native='modules/terminal/native/terminal_hotkey.cs';Script='modules/terminal/terminal_hotkey_library.ps1';Type='WindowsSetupTerminalHotkey';Methods='Run';Key='terminal_hotkey.cs'},
 @{Native='script/test/native/oobe_wim_reader.cs';Script='script/test/verify_oobe_payload.ps1';Type='WindowsSetup.OobeWimReader';Methods='Extract';Key=$null}
)
foreach($case in $cases){
 $path=Join-Path $root $case.Native
 Assert (Test-Path -LiteralPath $path -PathType Leaf) ('managed source has a real independently measurable file: '+$case.Native)
 if($case.Key){Assert ((Resolve-NucPath $case.Key) -eq $path) ('runtime managed dependency resolves after package relocation: '+$case.Key)}
 & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'test/powershell/fixtures/compile_native.ps1') -SourcePath $path -TypeName $case.Type -Methods $case.Methods
 Assert ($LASTEXITCODE -eq 0) ('PS5.1 compiler and deployed public ABI remain compatible: '+$case.Native)
 $source=[IO.File]::ReadAllText((Join-Path $root $case.Script))
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
 $pathLoads=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type' -and @($n.CommandElements|Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Path'}).Count -gt 0},$true))
 Assert ($pathLoads.Count -gt 0) ('runtime compiler loads original managed source by file: '+$case.Script)
}
Write-Host ('ALL PASS: '+$script:count+' source/PS5.1 ABI assertions; no native methods invoked')
