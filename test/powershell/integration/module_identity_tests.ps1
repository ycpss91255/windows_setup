#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Message){Write-Host ('@@ASSERT@@'+(@{Name=$Message;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Message}}
. (Join-Path $root 'core/hardware.ps1')
. (Join-Path $root 'core/entry_os_boundary.ps1')
Assert ((Test-SetupAdministrator) -eq (Test-SetupEntryAdministrator)) 'old and entry administrator boundaries agree for current identity'
. (Join-Path $root 'test/powershell/helpers/run_module_fixture.ps1')
$fixture=New-RunModuleFixture -SourceRoot $root
$boundaryFixture=$fixture.Root;$boundaryEntry=$fixture.Entry;$admin=$false
$boundaryError='';try{Invoke-RunModuleFixture $fixture @{Module='Apply-HostsSync';ExpectedUserSID='fixture-sid';VerifyOnly=$true;Mode='SSH'}}catch{$boundaryError=$_.Exception.Message}
Assert (Test-Path -LiteralPath (Join-Path $boundaryFixture 'captured.txt')) ('run_module uses replaceable identity and elevation boundary: '+$boundaryError)
Invoke-RunModuleFixture $fixture @{Module='Apply-UACSettings';ExpectedUserSID='fixture-sid';VerifyOnly=$true} -Admin $true
$resolverMarker=Join-Path $boundaryFixture 'resolver_called.txt'
Assert ((Test-Path -LiteralPath $resolverMarker) -and [IO.File]::ReadAllText($resolverMarker) -ceq 'Apply-UACSettings.ps1') '真入口以中性解析器分派固定模組'
Invoke-RunModuleFixture $fixture @{Module='Apply-HostsSync';ExpectedUserSID='fixture-sid';VerifyOnly=$true;Mode='SSH'}
$capturePath=Join-Path $boundaryFixture 'captured.txt'
$originalCapture=[IO.File]::ReadAllText($capturePath)
$equivalent=Join-Path $boundaryFixture './run_module.ps1'
$different=Join-Path $boundaryFixture 'other.ps1'
$controlSuffix=" -Module 'Apply-HostsSync' -ExpectedUserSID 'fixture-sid' -VerifyOnly -Mode 'SSH'"
$equivalentControl="& '"+$equivalent.Replace("'","''")+"'"+$controlSuffix
$differentControl="& '"+$different.Replace("'","''")+"'"+$controlSuffix
[IO.File]::WriteAllText($capturePath,$equivalentControl)
$equivalentAccepted=$true;try{Read-RunModuleCapturedCommand $fixture|Out-Null}catch{$equivalentAccepted=$false}
Assert $equivalentAccepted 'equivalent fixture target path is accepted'
[IO.File]::WriteAllText($capturePath,$differentControl)
$differentRejected=$false;try{Read-RunModuleCapturedCommand $fixture|Out-Null}catch{$differentRejected=$true}
Assert $differentRejected 'different fixture target path is rejected'
[IO.File]::WriteAllText($capturePath,$originalCapture)
$capture=Read-RunModuleCapturedCommand $fixture
Assert ($capture.Module -ceq 'Apply-HostsSync' -and $capture.ExpectedUserSID -ceq 'fixture-sid' -and $capture.VerifyOnly -and $capture.Mode -ceq 'SSH') 'captured elevation retains original identity and requested flags'
foreach($provided in @($false,$true)){
 $args=@{Module='Install-Drivers';ExpectedUserSID='fixture-sid'};if($provided){$args.DriverPackagePath=''}
 Invoke-RunModuleFixture $fixture $args -Admin $admin;$capture=Read-RunModuleCapturedCommand $fixture
 Assert ($capture.ContainsKey('DriverPackagePath') -eq $provided -and (-not $provided -or $capture.DriverPackagePath -ceq '')) ('captured elevation preserves omitted versus empty driver path: '+$provided)
}
$quoted=Join-Path $boundaryFixture "drivers ' 中文"
$expectedQuoted=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($quoted)
Invoke-RunModuleFixture $fixture @{Module='Install-Drivers';ExpectedUserSID='fixture-sid';DriverPackagePath=$quoted;ConfirmedBoard="board'quoted";ConfirmationComputer="machine'quoted";NonInteractive=$true} -Admin $admin
$capture=Read-RunModuleCapturedCommand $fixture
Assert ($capture.DriverPackagePath -ceq $expectedQuoted -and $capture.ConfirmedBoard -ceq "board'quoted" -and $capture.ConfirmationComputer -ceq "machine'quoted" -and $capture.NonInteractive) 'captured elevation preserves quoted paths and hardware confirmation'
$capturePath=Join-Path $boundaryFixture 'captured.txt';$dummyPath=Join-Path $boundaryFixture 'dummy.json'
$pathsMarker=Join-Path $boundaryFixture 'paths_loaded.txt'
[IO.File]::Delete($capturePath);[IO.File]::Delete($dummyPath);[IO.File]::Delete($pathsMarker);$rejected=$false;try{Invoke-RunModuleFixture $fixture @{Module='Apply-UACSettings';ExpectedUserSID='other'} -Admin $admin}catch{$rejected=$true}
Assert ($rejected -and -not (Test-Path $capturePath) -and -not (Test-Path $dummyPath) -and -not (Test-Path $pathsMarker) -and -not (Test-Path $resolverMarker)) 'different elevation account is rejected before paths, launch or module'
foreach($admin in @('false','true')){
 $adminFlag=($admin -eq 'true')
 foreach($invalid in @(@{Module='Unknown'},@{Module='Apply-UACSettings';ApplyPolicy=$true},@{Module='Apply-UACSettings';Restore=$true;VerifyOnly=$true},@{Module='Apply-PrivacySettings';Restore=$true},@{Module='Apply-PrivacySettings';SyncOnly=$true},@{Module='Apply-PrivacySettings';Mode='SSH'})){
  [IO.File]::Delete($capturePath);[IO.File]::Delete($dummyPath);$rejected=$false
  try{Invoke-RunModuleFixture $fixture $invalid -Admin $adminFlag}catch{$rejected=$true}
  Assert ($rejected -and -not (Test-Path $capturePath) -and -not (Test-Path $dummyPath)) ('invalid arguments rejected before launcher or module '+$admin+': '+($invalid|ConvertTo-Json -Compress))
 }
}
$allowed=@('Apply-UACSettings','Apply-PrivacySettings','Apply-HostsSync','Remove-OneDrive','Remove-SetupResidue','Apply-ExplorerSettings','Apply-TerminalHotkey','Apply-InputMethodSettings','Apply-StartMenuSettings','Apply-AMDPrivacySettings','Apply-CopilotSettings','Apply-AutologonSettings','Apply-PowerSettings','Apply-SSHSettings','Apply-MdnsSettings','Install-Drivers','Install-WindowsUpdates','Apply-Debloat','Apply-TaskbarSettings','Apply-DisplaySettings','Apply-DesktopSettings','Apply-ThemeSettings','Desktop-IconLayout','Apply-PagefileSettings')
foreach($module in $allowed){$admin=$false;Invoke-RunModuleFixture $fixture @{Module=$module} -Admin $admin;$capture=Read-RunModuleCapturedCommand $fixture;Assert ($capture.Module -ceq $module -and $capture.ExpectedUserSID -ceq 'fixture-sid') ('allowed module reaches only fake elevation: '+$module)}
$admin=$false;Invoke-RunModuleFixture $fixture @{Module='Apply-UACSettings';Restore=$true} -Admin $admin;$capture=Read-RunModuleCapturedCommand $fixture
Assert $capture.Restore 'UAC restore survives elevation'
Invoke-RunModuleFixture $fixture @{Module='Apply-StartMenuSettings';ApplyPolicy=$true;VerifyOnly=$true} -Admin $admin;$capture=Read-RunModuleCapturedCommand $fixture
Assert ($capture.VerifyOnly -and -not $capture.ContainsKey('ApplyPolicy')) 'VerifyOnly suppresses ApplyPolicy during elevation'
$admin=$true
foreach($module in $allowed){[IO.File]::Delete($dummyPath);Invoke-RunModuleFixture $fixture @{Module=$module} -Admin $admin;Assert (Test-Path $dummyPath) ('allowed module reaches only fixed dummy: '+$module)}
foreach($provided in @($false,$true)){
 $args=@{Module='Install-Drivers'};if($provided){$args.DriverPackagePath=''}
 Invoke-RunModuleFixture $fixture $args -Admin $admin;$direct=Get-Content $dummyPath -Raw|ConvertFrom-Json
 Assert (($null -ne $direct.PSObject.Properties['DriverPackagePath']) -eq $provided) ('direct dispatch preserves omitted versus empty driver path: '+$provided)
}
Invoke-RunModuleFixture $fixture @{Module='Install-Drivers';DriverPackagePath=$quoted;ConfirmedBoard="board'quoted";ConfirmationComputer="machine'quoted";NonInteractive=$true;VerifyOnly=$true} -Admin $admin;$direct=Get-Content $dummyPath -Raw|ConvertFrom-Json
Assert ($direct.DriverPackagePath -ceq $expectedQuoted -and $direct.ConfirmedBoard -ceq "board'quoted" -and $direct.ConfirmationComputer -ceq "machine'quoted" -and $direct.NonInteractive.IsPresent -and $direct.VerifyOnly.IsPresent) 'direct dispatch preserves quoted path and hardware confirmation'
Invoke-RunModuleFixture $fixture @{Module='Apply-UACSettings';Restore=$true} -Admin $admin;$direct=Get-Content $dummyPath -Raw|ConvertFrom-Json
Assert $direct.Restore.IsPresent 'direct UAC restore reaches fixed dummy'
Invoke-RunModuleFixture $fixture @{Module='Apply-HostsSync';Mode='Hosts';SyncOnly=$true} -Admin $admin;$direct=Get-Content $dummyPath -Raw|ConvertFrom-Json
Assert ($direct.Mode -ceq 'Hosts' -and $direct.SyncOnly.IsPresent) 'direct hosts sync retains mode and sync-only'
Invoke-RunModuleFixture $fixture @{Module='Apply-HostsSync';Mode='SSH';VerifyOnly=$true;SyncOnly=$true} -Admin $admin;$direct=Get-Content $dummyPath -Raw|ConvertFrom-Json
Assert ($direct.Mode -ceq 'SSH' -and $direct.VerifyOnly.IsPresent -and $null -eq $direct.PSObject.Properties['SyncOnly']) 'hosts verification has priority over sync-only'
Invoke-RunModuleFixture $fixture @{Module='Apply-StartMenuSettings';VerifyOnly=$true;ApplyPolicy=$true;NonInteractive=$true} -Admin $admin;$direct=Get-Content $dummyPath -Raw|ConvertFrom-Json
Assert ($direct.VerifyOnly.IsPresent -and -not $direct.ApplyPolicy.IsPresent -and $direct.NonInteractive.IsPresent) 'start verification suppresses policy application'
Invoke-RunModuleFixture $fixture @{Module='Desktop-IconLayout';VerifyOnly=$true} -Admin $admin;$direct=Get-Content $dummyPath -Raw|ConvertFrom-Json
Assert ($direct.Mode -ceq 'Verify') 'desktop verification passes finite mode to fixed dummy'

$desktopFixture=Join-Path $env:TEMP ('desktop_entry_boundary_'+[guid]::NewGuid().ToString('N'))
$desktopPackage=Join-Path $desktopFixture 'package';$desktopCore=Join-Path $desktopPackage 'core';$desktopDir=Join-Path $desktopPackage 'modules/desktop'
[void][IO.Directory]::CreateDirectory($desktopCore);[void][IO.Directory]::CreateDirectory($desktopDir)
$desktopEntry=Join-Path $desktopDir "desktop ' 中文.ps1"
Copy-Item -LiteralPath (Join-Path $root 'modules/desktop/desktop_icon_layout.ps1') -Destination $desktopEntry
[IO.File]::WriteAllText((Join-Path $desktopCore 'entry_os_boundary.ps1'),@'
function Get-SetupEntryIdentity { [IO.File]::WriteAllText($env:DESKTOP_FIXTURE_SID_MARKER,'called'); 'desktop-fixture-sid' }
function Test-SetupEntryAdministrator { [IO.File]::WriteAllText($env:DESKTOP_FIXTURE_ADMIN_MARKER,'called'); $env:DESKTOP_FIXTURE_ADMIN -eq 'true' }
function Start-SetupEntryElevated { param([string]$Command,[switch]$UseSystemPowerShell) @{Command=$Command;System=$UseSystemPowerShell.IsPresent}|ConvertTo-Json -Compress|Set-Content -LiteralPath $env:DESKTOP_FIXTURE_CAPTURE -Encoding UTF8 }
'@,[Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText((Join-Path $desktopCore 'gui_stage_library.ps1'),@'
function Invoke-SetupGuiPublicDispatch { param($PackageRoot,$Role,[switch]$Worker,[switch]$VerifyOnly,$IconMode,$VerificationRunId) if($env:DESKTOP_FIXTURE_GUI_FAILURE -eq 'true'){throw 'fake GUI failure'};@{PackageRoot=$PackageRoot;Role=$Role;Worker=$Worker.IsPresent;VerifyOnly=$VerifyOnly.IsPresent;IconMode=$IconMode;VerificationRunId=$VerificationRunId}|ConvertTo-Json -Compress|Set-Content -LiteralPath $env:DESKTOP_FIXTURE_CAPTURE -Encoding UTF8 }
'@,[Text.UTF8Encoding]::new($true))
$desktopWrapper=Join-Path $desktopFixture 'wrapper.ps1'
[IO.File]::WriteAllText($desktopWrapper,@'
param([string]$Entry,[string]$Mode,[string]$ExpectedSID,[switch]$Worker,[string]$RunId)
$ErrorActionPreference='Stop'
function global:Start-Process {throw 'blocked real process'}
function global:Add-Type {throw 'blocked native'}
function global:Get-ItemProperty {throw 'blocked registry'}
function global:Set-ItemProperty {throw 'blocked registry'}
function global:New-ItemProperty {throw 'blocked registry'}
function global:Remove-ItemProperty {throw 'blocked registry'}
function global:Get-Service {throw 'blocked service'}
function global:Set-Service {throw 'blocked service'}
function global:Start-Service {throw 'blocked service'}
function global:Register-ScheduledTask {throw 'blocked task'}
function global:Get-UICulture {[IO.File]::WriteAllText($env:DESKTOP_FIXTURE_CULTURE_MARKER,'called');[pscustomobject]@{Name=$env:DESKTOP_FIXTURE_CULTURE}}
$arguments=@{Mode=$Mode;ExpectedUserSID=$ExpectedSID};if($Worker){$arguments.Worker=$true};if($RunId){$arguments.VerificationRunId=$RunId}
& $Entry @arguments
'@,[Text.UTF8Encoding]::new($true))
$env:DESKTOP_FIXTURE_CAPTURE=Join-Path $desktopFixture 'desktop_capture.json';$env:DESKTOP_FIXTURE_SID_MARKER=Join-Path $desktopFixture 'sid.marker';$env:DESKTOP_FIXTURE_ADMIN_MARKER=Join-Path $desktopFixture 'admin.marker';$env:DESKTOP_FIXTURE_CULTURE_MARKER=Join-Path $desktopFixture 'culture.marker';$env:DESKTOP_FIXTURE_ADMIN='false';$env:DESKTOP_FIXTURE_CULTURE='zh-TW'
$priorPreference=$ErrorActionPreference;$ErrorActionPreference='Continue'
try{& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $desktopWrapper -Entry $desktopEntry -Mode Save -ExpectedSID 'desktop-fixture-sid' *> (Join-Path $desktopFixture 'red_or_green.log');$desktopExit=$LASTEXITCODE}finally{$ErrorActionPreference=$priorPreference}
Assert ($desktopExit -eq 0 -and (Test-Path -LiteralPath $env:DESKTOP_FIXTURE_CAPTURE)) 'desktop entry uses replaceable identity and system elevation boundary'
# Desktop boundary cases
function Read-DesktopCommand([string]$Text) {
 $tokens=$null;$errors=$null;$tree=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors);$statements=@($tree.EndBlock.Statements)
 if($errors.Count -or $statements.Count -ne 1 -or $statements[0] -isnot [Management.Automation.Language.PipelineAst] -or $statements[0].PipelineElements.Count -ne 1){throw 'unexpected desktop command syntax'}
 $cmd=$statements[0].PipelineElements[0]
 if($cmd -isnot [Management.Automation.Language.CommandAst] -or $cmd.InvocationOperator -ne 'Ampersand' -or $cmd.Redirections.Count){throw 'unexpected desktop command'}
 $parts=@($cmd.CommandElements);if($parts[0] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or -not (Test-BoundaryTarget $parts[0].Value $desktopEntry)){throw 'unexpected desktop target'}
 $values=@{};for($i=1;$i -lt $parts.Count;$i++){
  if($parts[$i] -isnot [Management.Automation.Language.CommandParameterAst] -or $null -ne $parts[$i].Argument){throw 'unexpected desktop argument'}
  $key=$parts[$i].ParameterName;if($key -notin @('ExpectedUserSID','Mode','Worker','VerificationRunId') -or $values.ContainsKey($key)){throw 'unexpected desktop parameter'}
  if($i+1 -lt $parts.Count -and $parts[$i+1] -is [Management.Automation.Language.StringConstantExpressionAst]){$i++;$values[$key]=$parts[$i].Value}else{$values[$key]=$true}
 }
 return $values
}
function Invoke-DesktopFixture([string]$Mode,[string]$Sid,[string]$Culture,[bool]$Admin,[bool]$Worker,[string]$RunId) {
 foreach($path in @($env:DESKTOP_FIXTURE_CAPTURE,$env:DESKTOP_FIXTURE_SID_MARKER,$env:DESKTOP_FIXTURE_ADMIN_MARKER,$env:DESKTOP_FIXTURE_CULTURE_MARKER)){[IO.File]::Delete($path)}
 $env:DESKTOP_FIXTURE_ADMIN=$Admin.ToString().ToLowerInvariant();$env:DESKTOP_FIXTURE_CULTURE=$Culture
 $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$desktopWrapper,'-Entry',$desktopEntry,'-Mode',$Mode,'-ExpectedSID',$Sid)
 if($Worker){$args+='-Worker'};if($RunId){$args+=@('-RunId',$RunId)}
 $prior=$ErrorActionPreference;$ErrorActionPreference='Continue'
 try{& powershell.exe @args *> (Join-Path $desktopFixture 'case.log');$code=$LASTEXITCODE}finally{$ErrorActionPreference=$prior}
 return $code
}
$equivalentDesktop=Join-Path $desktopDir './desktop '' 中文.ps1'
$otherDesktop=Join-Path $desktopDir 'other.ps1'
$equivalentCommand="& '"+$equivalentDesktop.Replace("'","''")+"' -Mode 'Save'"
$otherCommand="& '"+$otherDesktop.Replace("'","''")+"' -Mode 'Save'"
Assert ((Read-DesktopCommand $equivalentCommand).Mode -ceq 'Save') 'desktop parser accepts equivalent fixture target'
$otherRejected=$false;try{[void](Read-DesktopCommand $otherCommand)}catch{$otherRejected=$_.Exception.Message -ceq 'unexpected desktop target'}
Assert $otherRejected 'desktop parser rejects different fixture target'
$runId='11111111-2222-3333-4444-555555555555'
$case=Get-Content $env:DESKTOP_FIXTURE_CAPTURE -Raw|ConvertFrom-Json;$command=Read-DesktopCommand $case.Command
Assert ($case.System -and $command.ExpectedUserSID -ceq 'desktop-fixture-sid' -and $command.Mode -ceq 'Save' -and -not $command.ContainsKey('Worker')) 'Save elevation retains fixed System launcher, SID and mode'
$code=Invoke-DesktopFixture 'Load' 'other-sid' 'en-US' $false $false ''
Assert ($code -ne 0 -and (Test-Path $env:DESKTOP_FIXTURE_SID_MARKER) -and -not (Test-Path $env:DESKTOP_FIXTURE_CULTURE_MARKER) -and -not (Test-Path $env:DESKTOP_FIXTURE_ADMIN_MARKER) -and -not (Test-Path $env:DESKTOP_FIXTURE_CAPTURE)) 'different SID rejects before culture, admin and GUI'
foreach($mode in @('Load','Verify')){
 $code=Invoke-DesktopFixture $mode 'desktop-fixture-sid' 'en-US' $false $false ''
 Assert ($code -eq 0 -and (Test-Path $env:DESKTOP_FIXTURE_CULTURE_MARKER) -and -not (Test-Path $env:DESKTOP_FIXTURE_ADMIN_MARKER) -and -not (Test-Path $env:DESKTOP_FIXTURE_CAPTURE) -and ((Get-Content (Join-Path $desktopFixture 'case.log') -Raw) -match 'Skipped')) ('non-Save culture skip precedes admin: '+$mode)
}
$code=Invoke-DesktopFixture 'Save' 'desktop-fixture-sid' 'en-US' $false $true $runId
$case=Get-Content $env:DESKTOP_FIXTURE_CAPTURE -Raw|ConvertFrom-Json;$command=Read-DesktopCommand $case.Command
Assert ($code -eq 0 -and $case.System -and $command.Mode -ceq 'Save' -and $command.Worker -and $command.VerificationRunId -ceq $runId -and -not (Test-Path $env:DESKTOP_FIXTURE_CULTURE_MARKER)) 'Save bypasses culture and captures worker and run ID safely'
foreach($mode in @('Load','Verify')){
 $code=Invoke-DesktopFixture $mode 'desktop-fixture-sid' 'zh-TW' $false $true $runId
 $case=Get-Content $env:DESKTOP_FIXTURE_CAPTURE -Raw|ConvertFrom-Json;$command=Read-DesktopCommand $case.Command
 Assert ($code -eq 0 -and $case.System -and $command.Mode -ceq $mode -and $command.Worker -and $command.VerificationRunId -ceq $runId) ('desktop elevation retains literal parameters: '+$mode)
}
foreach($mode in @('Save','Load','Verify')){
 $code=Invoke-DesktopFixture $mode 'desktop-fixture-sid' 'zh-TW' $true $true $runId
 $case=Get-Content $env:DESKTOP_FIXTURE_CAPTURE -Raw|ConvertFrom-Json
 Assert ($code -eq 0 -and (Test-BoundaryTarget $case.PackageRoot $desktopPackage) -and $case.Role -ceq 'Icons' -and $case.Worker -and $case.IconMode -ceq $mode -and $case.VerificationRunId -ceq $runId -and $case.VerifyOnly -eq ($mode -eq 'Verify')) ('admin dispatch reaches only fixed fake Icons controller: '+$mode)
}
$code=Invoke-DesktopFixture 'Save' 'desktop-fixture-sid' 'zh-TW' $true $false 'bad'
Assert ($code -ne 0 -and -not (Test-Path $env:DESKTOP_FIXTURE_CAPTURE)) 'invalid run ID rejects before launcher or GUI'
$env:DESKTOP_FIXTURE_GUI_FAILURE='true'
try{$code=Invoke-DesktopFixture 'Save' 'desktop-fixture-sid' 'zh-TW' $true $false '';Assert ($code -ne 0 -and ((Get-Content (Join-Path $desktopFixture 'case.log') -Raw) -match 'fake GUI failure')) 'fake GUI failure propagates'}finally{Remove-Item Env:DESKTOP_FIXTURE_GUI_FAILURE}
$fakeBoundary=Join-Path $desktopCore 'entry_os_boundary.ps1';$backup=$fakeBoundary+'.owned-backup'
[IO.File]::Move($fakeBoundary,$backup)
try{$code=Invoke-DesktopFixture 'Save' 'desktop-fixture-sid' 'zh-TW' $true $false '';Assert ($code -ne 0 -and -not (Test-Path $env:DESKTOP_FIXTURE_CAPTURE)) 'missing boundary fails closed before GUI'}finally{[IO.File]::Move($backup,$fakeBoundary)}
Remove-Item Env:DESKTOP_FIXTURE_CAPTURE,Env:DESKTOP_FIXTURE_SID_MARKER,Env:DESKTOP_FIXTURE_ADMIN_MARKER,Env:DESKTOP_FIXTURE_CULTURE_MARKER,Env:DESKTOP_FIXTURE_ADMIN,Env:DESKTOP_FIXTURE_CULTURE
& {
 . (Join-Path $root 'core/entry_os_boundary.ps1')
 $script:launchFile='';$script:launchVerb='';$script:launchArgs=''
 function Start-Process {param($FilePath,$Verb,$ArgumentList);$script:launchFile=$FilePath;$script:launchVerb=$Verb;$script:launchArgs=$ArgumentList}
 $literal="fixture ' 中文"
 Start-SetupEntryElevated -Command $literal
 $defaultArgs=$script:launchArgs
 $parts=@($script:launchArgs -split ' ');$index=[Array]::IndexOf($parts,'-EncodedCommand')
 $options=@($parts|Where-Object {$_ -ne $parts[$index+1]})
 Assert ($script:launchFile -ceq 'powershell.exe' -and $script:launchVerb -ceq 'RunAs' -and $index -ge 0 -and $options.Count -eq 5 -and $options -contains '-NoProfile' -and $options -contains '-NoExit' -and $options -contains '-ExecutionPolicy' -and $options -contains 'Bypass' -and $options -contains '-EncodedCommand' -and [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($parts[$index+1])) -ceq $literal) 'existing entry launcher preserves same PowerShell options and encoded command data'
 Start-SetupEntryElevated -Command $literal -UseSystemPowerShell
 $parts=@($script:launchArgs -split ' ');$index=[Array]::IndexOf($parts,'-EncodedCommand')
 $expected=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell/v1.0/powershell.exe'
 Assert ($script:launchFile -ceq $expected -and $script:launchVerb -ceq 'RunAs' -and $script:launchArgs -ceq $defaultArgs -and $index -ge 0 -and [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($parts[$index+1])) -ceq $literal) 'system launcher uses fixed System path and retains default flags and encoded command data'
}
