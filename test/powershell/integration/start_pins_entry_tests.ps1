#Requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
function Parse($File){$t=$null;$e=$null;[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $File),[ref]$t,[ref]$e)}
. (Join-Path $repo 'test/powershell/helpers/run_module_fixture.ps1')
$ast=Parse 'core/run_module.ps1'
Assert ($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -contains 'ApplyPolicy') 'standalone accepts explicit policy confirmation mode'
$runFixture=New-RunModuleFixture -SourceRoot $repo
$arguments=@{Module='Apply-StartMenuSettings';ApplyPolicy=$true;NonInteractive=$true}
Invoke-RunModuleFixture $runFixture $arguments
$r=Read-RunModuleCapturedCommand $runFixture
Assert ($r.ApplyPolicy -and $r.NonInteractive) 'real UAC command preserves explicit apply and noninteractive'
Invoke-RunModuleFixture $runFixture $arguments -Admin $true
$r=Get-Content (Join-Path $runFixture.Root 'dummy.json') -Raw|ConvertFrom-Json
Assert ($r.ApplyPolicy.IsPresent -and $r.NonInteractive.IsPresent) 'real direct dispatch preserves Start flags'
$arguments.VerifyOnly=$true;Invoke-RunModuleFixture $runFixture $arguments -Admin $true
$r=Get-Content (Join-Path $runFixture.Root 'dummy.json') -Raw|ConvertFrom-Json
Assert ($r.VerifyOnly.IsPresent -and -not $r.ApplyPolicy.IsPresent) 'verification dispatch never forwards policy installation'
$fixture=Join-Path $env:TEMP ('start_full_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$source=Join-Path $repo 'core/start_windows.ps1'
foreach($path in @($source,$fixture)){
 Assert-RunModuleSafePath $path
}
$testAst=Parse 'test/powershell/integration/start_pins_entry_tests.ps1'
$guardLoop=$testAst.Find({param($node)
 if($node -isnot [Management.Automation.Language.ForEachStatementAst] -or $node.Variable.VariablePath.UserPath -ne 'path'){return $false}
 $arrays=@($node.Condition.FindAll({param($child) $child -is [Management.Automation.Language.ArrayLiteralAst]},$true))
 if($arrays.Count -ne 1 -or $arrays[0].Elements.Count -ne 2){return $false}
 $elements=$arrays[0].Elements
 return ($elements[0] -is [Management.Automation.Language.VariableExpressionAst] -and $elements[0].VariablePath.UserPath -eq 'source' -and $elements[1] -is [Management.Automation.Language.VariableExpressionAst] -and $elements[1].VariablePath.UserPath -eq 'fixture')
},$true)
$guardCalls=@($guardLoop.Body.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Assert-RunModuleSafePath' -and $node.CommandElements.Count -eq 2 -and $node.CommandElements[1] -is [Management.Automation.Language.VariableExpressionAst] -and $node.CommandElements[1].VariablePath.UserPath -eq 'path'},$true))
Assert ($guardCalls.Count -eq 1) 'source file and fixture both use shared ancestor guard'
$core=Join-Path $fixture 'core';[void][IO.Directory]::CreateDirectory($core)
$entry=Join-Path $core 'start_windows.ps1';Copy-Item -LiteralPath $source -Destination $entry
Assert ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash) 'Windows entry fixture copies exact source'
$hardware=@'
function Test-SetupInteractiveHost { $true }
function Select-SetupDriverRequest {
 param($PackageRoot,$DriverPackagePath,$PathSpecified,$ConfirmedBoard,$ConfirmationComputer,$Interactive)
 @{PathSpecified=$PathSpecified;Path=$DriverPackagePath;Board=$ConfirmedBoard;Computer=$ConfirmationComputer;Interactive=$Interactive}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'selection.json') -Encoding UTF8
 [pscustomobject]@{DriverPackagePath="fixture ' 中文";ConfirmedBoard='fixture-board';ConfirmationComputer='fixture-computer'}
}
'@
$configure=@'
param($DriverPackagePath,$ConfirmedBoard,$ConfirmationComputer,[switch]$NonInteractive)
@{Path=$DriverPackagePath;Board=$ConfirmedBoard;Computer=$ConfirmationComputer;NonInteractive=$NonInteractive.IsPresent}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'result.json') -Encoding UTF8
'@
[IO.File]::WriteAllText((Join-Path $core 'hardware.ps1'),$hardware,[Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText((Join-Path $core 'configure_setup.ps1'),$configure,[Text.UTF8Encoding]::new($true))
foreach($name in @('verify_only','verify_after_restart')){[IO.File]::WriteAllText((Join-Path $core ($name+'.ps1')),"[IO.File]::WriteAllText((Join-Path `$PSScriptRoot 'result.json'),'`"$name`"')",[Text.UTF8Encoding]::new($true))}
$hashes=@{};foreach($name in @('start_windows.ps1','hardware.ps1','configure_setup.ps1','verify_only.ps1','verify_after_restart.ps1')){$hashes[$name]=(Get-FileHash -LiteralPath (Join-Path $core $name) -Algorithm SHA256).Hash}
$wrapper=Join-Path $fixture 'wrapper.ps1'
[IO.File]::WriteAllText($wrapper,@'
param([string]$Config)
$ErrorActionPreference='Stop'
function global:Start-Process {throw 'blocked process'}
function global:Add-Type {throw 'blocked native'}
function global:Get-ItemProperty {throw 'blocked registry'}
function global:Set-ItemProperty {throw 'blocked registry'}
function global:New-ItemProperty {throw 'blocked registry'}
function global:Remove-ItemProperty {throw 'blocked registry'}
function global:Get-Service {throw 'blocked service'}
function global:Set-Service {throw 'blocked service'}
function global:Start-Service {throw 'blocked service'}
function global:Stop-Service {throw 'blocked service'}
function global:Register-ScheduledTask {throw 'blocked task'}
function global:Unregister-ScheduledTask {throw 'blocked task'}
function global:reg.exe {throw 'blocked registry process'}
function global:schtasks.exe {throw 'blocked task process'}
function global:cmd.exe {throw 'blocked process'}
$cfg=Get-Content -LiteralPath $Config -Raw|ConvertFrom-Json
$core=Join-Path $PSScriptRoot 'core'
foreach($dir in @($PSScriptRoot,$core)){if((Get-Item -LiteralPath $dir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'fixture directory changed'}}
foreach($p in $cfg.Hashes.PSObject.Properties){$file=Join-Path $core $p.Name;if(-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -cne $p.Value){throw 'fixture dependency missing or changed'}}
$arguments=@{};foreach($p in $cfg.Arguments.PSObject.Properties){$arguments[$p.Name]=$p.Value}
& (Join-Path $core 'start_windows.ps1') @arguments
'@,[Text.UTF8Encoding]::new($true))
function Invoke-StartFixture([hashtable]$Arguments){
 foreach($name in @('selection.json','result.json')){[IO.File]::Delete((Join-Path $core $name))}
 $config=Join-Path $fixture 'config.json';@{Hashes=$hashes;Arguments=$Arguments}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $config -Encoding UTF8
 $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
 $systemPowerShell=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell/v1.0/powershell.exe'
 try{& $systemPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $wrapper -Config $config *> (Join-Path $fixture 'child.log');$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
 return $code
}
$code=Invoke-StartFixture @{NonInteractive=$true};$r=Get-Content (Join-Path $core 'result.json') -Raw|ConvertFrom-Json;$selection=Get-Content (Join-Path $core 'selection.json') -Raw|ConvertFrom-Json
Assert ($code -eq 0 -and $r.NonInteractive) 'Windows entry forwards noninteractive to late policy gate'
Assert ($r.Path -ceq "fixture ' 中文" -and $r.Board -ceq 'fixture-board' -and $r.Computer -ceq 'fixture-computer' -and -not $selection.Interactive -and -not $selection.PathSpecified) 'Windows entry forwards selected values and omitted path'
$code=Invoke-StartFixture @{DriverPackagePath='';ConfirmedBoard='input-board';ConfirmationComputer='input-computer'};$r=Get-Content (Join-Path $core 'selection.json') -Raw|ConvertFrom-Json;$direct=Get-Content (Join-Path $core 'result.json') -Raw|ConvertFrom-Json
Assert ($code -eq 0 -and $r.PathSpecified -and $r.Path -ceq '' -and $r.Interactive -and $r.Board -ceq 'input-board' -and $r.Computer -ceq 'input-computer' -and -not $direct.NonInteractive) 'Windows entry preserves empty path and interactive choice'
foreach($pair in @(@('VerifyOnly','verify_only'),@('AfterRestart','verify_after_restart'))){$a=@{};$a[$pair[0]]=$true;$code=Invoke-StartFixture $a;$r=Get-Content (Join-Path $core 'result.json') -Raw|ConvertFrom-Json;Assert ($code -eq 0 -and $r -ceq $pair[1] -and -not (Test-Path (Join-Path $core 'selection.json'))) ('Windows entry reaches only fixed fake '+$pair[0])}
foreach($a in @(@{VerifyOnly=$true;AfterRestart=$true},@{VerifyOnly=$true;DriverPackagePath='nonempty'},@{AfterRestart=$true;ConfirmedBoard='board'})){$code=Invoke-StartFixture $a;Assert ($code -ne 0 -and -not (Test-Path (Join-Path $core 'result.json')) -and -not (Test-Path (Join-Path $core 'selection.json'))) 'invalid Windows entry combination stops before fake dependencies'}
$fake=Join-Path $core 'hardware.ps1';$backup=Join-Path $core 'hardware.saved';[IO.File]::Move($fake,$backup)
try{$code=Invoke-StartFixture @{};Assert ($code -ne 0 -and -not (Test-Path (Join-Path $core 'result.json'))) 'missing fake dependency fails closed'}finally{[IO.File]::Move($backup,$fake)}
. (Join-Path $repo 'core/paths.ps1')
foreach($name in @('start_pins_policy_library.ps1','start_pins_asset_library.ps1')){Assert (Test-Path -LiteralPath (Resolve-NucPath $name)) ('runtime dependency resolves '+$name)}
$pre=[IO.File]::ReadAllText((Join-Path $repo 'core/test_setup_prerequisites.ps1'))
Assert ($pre.Contains('Assert-StartPinsAssetSource')) 'offline preflight checks actual Start asset source without client native API'
