#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Message){Write-Host ('@@ASSERT@@'+(@{Name=$Message;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Message}}
$fixture=Join-Path $env:TEMP ('desktop_safety_'+[guid]::NewGuid().ToString('N'))
$desktop=Join-Path $fixture '桌面';$common=Join-Path $fixture 'Common Desktop'
$fixtureDesktopRoots=@($desktop,$common)
foreach($path in $fixtureDesktopRoots){[void][IO.Directory]::CreateDirectory($path)}
. (Join-Path $root 'modules/desktop/desktop_safety.ps1')
. (Join-Path $root 'modules/desktop/desktop_settings_library.ps1')
# VerifyOnly must not invoke any mutating, native or process operation.
function Remove-SetupDesktopEntry {throw 'unexpected desktop deletion'}
function New-Item {throw 'unexpected filesystem or registry creation'}
function New-ItemProperty {throw 'unexpected registry mutation'}
function Set-ItemProperty {throw 'unexpected registry mutation'}
function Remove-Item {throw 'unexpected deletion'}
function Add-Type {throw 'unexpected native operation'}
function Start-Process {throw 'unexpected process launch'}
$tokens=$null;$errors=$null
$leafAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'modules/desktop/desktop_settings_library.ps1'),[ref]$tokens,[ref]$errors)
$call=$leafAst.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert-DesktopSourceLocation'},$true)
Assert ($null -ne $call -and $call.Extent.Text -match '\-SourceRoot\s+\$SourcePackageRoot' -and $call.Extent.Text -match '\-DesktopRoots\s+\$DesktopRoots') 'actual named leaf invokes original source safety before cleanup'
foreach($case in @(
 @{Name='nested package';Package=(Join-Path $desktop 'windows_setup');Reject=$true},
 @{Name='package equals desktop';Package=$desktop;Reject=$true},
 @{Name='common desktop';Package=(Join-Path $common 'windows_setup');Reject=$true},
 @{Name='worker original desktop source';Package=(Join-Path $desktop 'windows_setup');Reject=$true},
 @{Name='worker missing source identity';Package='';Reject=$true},
 @{Name='safe similar prefix';Package=($desktop+'2\windows_setup');Reject=$false}
)){
 $packageRoot=$case.Package
 if($packageRoot){[void][IO.Directory]::CreateDirectory($packageRoot);[IO.File]::WriteAllText((Join-Path $packageRoot 'keep.txt'),'keep')}
 $refused=$false;$result=$null
 try{$result=Invoke-SetupDesktopSettings -ModuleRoot (Join-Path $root 'modules/desktop') -SourcePackageRoot $packageRoot -DesktopRoots $fixtureDesktopRoots -VerifyOnly}catch{if($packageRoot){$refused=$_.Exception.Message -match '工具包不可位於桌面'}else{$refused=$_.Exception -is [System.Management.Automation.ParameterBindingException]};if(-not $case.Reject -or -not $refused){throw}}
 Assert ($refused -eq $case.Reject) ('actual desktop module pre-mutation guard: '+$case.Name)
 if(-not $case.Reject){Assert ($null -ne $result -and @($result.DesktopRoots).Count -eq 2 -and @($result.DeletedItems).Count -eq 0 -and -not $result.Success) ('safe desktop returns verification result: '+$case.Name)}
 if($packageRoot){Assert (([IO.File]::ReadAllText((Join-Path $packageRoot 'keep.txt'))) -eq 'keep') ('package contents retained: '+$case.Name)}
}
# The main preflight uses the same named guard with actual system desktop roots.
$preflight=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'core/prerequisites_library.ps1'),[ref]$tokens,[ref]$errors)
$guard=$preflight.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert-DesktopSourceLocation'},$true)
Assert ($null -ne $guard -and $guard.Extent.Text -match '\-SourceRoot\s+\$SourceRoot' -and $guard.Extent.Text -match 'DesktopDirectory' -and $guard.Extent.Text -match 'CommonDesktopDirectory') 'actual complete preflight still contains the desktop source guard'
[void][IO.Directory]::CreateDirectory((Join-Path $desktop '中文 子目錄'))
$index=0
foreach($location in @($desktop,(Join-Path $desktop '中文 子目錄'),$common,$desktop.ToUpperInvariant())){
 $refused=$false
 try{Assert-DesktopSourceLocation -SourceRoot $location -DesktopRoots $fixtureDesktopRoots}catch{$refused=$_.Exception.Message -match '工具包不可位於桌面'}
 Assert $refused ('actual main preflight rejects desktop equality and descendants: case '+(++$index))
}
# Fixed private worker must use the protected original root, not its copied code directory.
$gui=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'core/gui_stage_library.ps1'),[ref]$tokens,[ref]$errors)
$call=$gui.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-SetupDesktopSettings'},$true)
Assert ($call.Extent.Text.Contains('-SourcePackageRoot $context.SourcePackageRoot') -and -not $call.Extent.Text.Contains('-SourcePackageRoot $CodeRoot')) 'fixed worker receives bound original source identity'
. (Join-Path $root 'core/gui_stage_library.ps1')
Assert (@(Get-SetupGuiStageFiles Desktop) -contains 'modules/desktop/desktop_safety.ps1') 'fixed private worker includes its original safety dependency'
