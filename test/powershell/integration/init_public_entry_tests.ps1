#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$fixture=Join-Path $env:TEMP ('init_public_entry_'+[guid]::NewGuid().ToString('N'))
$module=Join-Path $fixture 'package/modules/init';[void][IO.Directory]::CreateDirectory($module)
$utf=New-Object Text.UTF8Encoding($true)
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
function SamePath([string]$Left,[string]$Right){if(-not [IO.Path]::IsPathRooted($Left) -or -not [IO.Path]::IsPathRooted($Right)){return $false};try{return [string]::Equals([IO.Path]::GetFullPath($Left),[IO.Path]::GetFullPath($Right),[StringComparison]::OrdinalIgnoreCase)}catch{return $false}}
Assert (SamePath (Join-Path $module './x.ps1') (Join-Path $module 'x.ps1')) 'equivalent rooted fixture paths match'
Assert (-not(SamePath (Join-Path $module 'other.ps1') (Join-Path $module 'x.ps1'))) 'different fixture paths do not match'
Assert (-not(SamePath 'x.ps1' (Join-Path $module 'x.ps1'))) 'relative fixture path rejected'
$canonical=Join-Path $root 'modules/init/initialize_setup.ps1';$legacy=Join-Path $root 'modules/init/initialize_nuc.ps1'
Assert (Test-Path -LiteralPath $canonical -PathType Leaf) 'canonical init public entry exists'
foreach($entry in @($canonical,$legacy)){Copy-Item -LiteralPath $entry -Destination $module}
[IO.File]::WriteAllText((Join-Path $module 'init_entry_library.ps1'),@'
function Invoke-SetupInit {param($EntryPath,$ModuleRoot,$SshScriptPath,$ExpectedUserSID,$ResumeStatePath)
 if($ExpectedUserSID -ne 'fixture-sid'){throw 'fixture SID rejected'}
 if($env:INIT_FIXTURE_FAIL -eq 'true'){throw 'fixture init failure'}
 @{EntryPath=$EntryPath;ModuleRoot=$ModuleRoot;SshScriptPath=$SshScriptPath;ExpectedUserSID=$ExpectedUserSID;ResumeStatePath=$ResumeStatePath}|ConvertTo-Json -Compress|Set-Content -LiteralPath $env:INIT_FIXTURE_CAPTURE -Encoding UTF8
}
'@,$utf)
$oldCapture=$env:INIT_FIXTURE_CAPTURE;$oldFail=$env:INIT_FIXTURE_FAIL
try{
 $env:INIT_FIXTURE_FAIL=''
 $env:INIT_FIXTURE_CAPTURE=Join-Path $fixture 'capture.json'
 foreach($name in @('initialize_setup.ps1','initialize_nuc.ps1')){
  $entry=Join-Path $module $name;$ssh=Join-Path $fixture "ssh ' 中文.ps1";$resume=Join-Path $fixture 'state.json'
  if(Test-Path -LiteralPath $env:INIT_FIXTURE_CAPTURE){[IO.File]::Delete($env:INIT_FIXTURE_CAPTURE)}
  & $entry -SshScriptPath $ssh -ExpectedUserSID 'fixture-sid' -ResumeStatePath $resume
  $result=Get-Content -LiteralPath $env:INIT_FIXTURE_CAPTURE -Raw|ConvertFrom-Json
  Assert ((SamePath $result.EntryPath $entry) -and (SamePath $result.ModuleRoot $module) -and $result.SshScriptPath -ceq $ssh -and $result.ExpectedUserSID -ceq 'fixture-sid' -and $result.ResumeStatePath -ceq $resume) ('entry forwards its own path and all parameters: '+$name)
  [IO.File]::Delete($env:INIT_FIXTURE_CAPTURE);$rejected=$false;try{& $entry -ExpectedUserSID 'other-sid'}catch{$rejected=$_.Exception.Message -ceq 'fixture SID rejected'}
  Assert ($rejected -and -not(Test-Path -LiteralPath $env:INIT_FIXTURE_CAPTURE)) ('entry propagates fake SID rejection: '+$name)
  $env:INIT_FIXTURE_FAIL='true';$failed=$false;try{& $entry -ExpectedUserSID 'fixture-sid'}catch{$failed=$_.Exception.Message -ceq 'fixture init failure'}finally{$env:INIT_FIXTURE_FAIL=''}
  Assert ($failed -and -not(Test-Path -LiteralPath $env:INIT_FIXTURE_CAPTURE)) ('entry propagates fake failure: '+$name)
 }
}finally{$env:INIT_FIXTURE_CAPTURE=$oldCapture;$env:INIT_FIXTURE_FAIL=$oldFail}
$mapping=Get-Content -LiteralPath (Join-Path $root 'core/paths.json') -Raw|ConvertFrom-Json
Assert ($mapping.'initialize_setup.ps1' -ceq 'modules/init/initialize_setup.ps1' -and $mapping.'Initialize-NUC.ps1' -ceq 'modules/init/initialize_nuc.ps1') 'canonical and legacy mappings remain available'
$cmd=[IO.File]::ReadAllText((Join-Path $root 'init.cmd'))
Assert ($cmd -match '(?im)^powershell\.exe\s+.*-File\s+"%~dp0modules\\init\\initialize_setup\.ps1"\s*$') 'public command selects canonical entry'
$prereq=[IO.File]::ReadAllText((Join-Path $root 'core/test_setup_prerequisites.ps1'))
Assert ($prereq.Contains("'initialize_setup.ps1'") -and $prereq.Contains("'initialize_nuc.ps1'")) 'preflight requires both public entries'
$stage=[IO.File]::ReadAllText((Join-Path $root 'modules/init/provisioning_library.ps1'))
$launcher=[IO.File]::ReadAllText((Join-Path $root 'modules/init/provisioning_launcher_library.ps1'))
Assert ($stage.Contains("'modules/init/initialize_nuc.ps1'") -and $stage.Contains('runtime\modules\init\initialize_nuc.ps1') -and $launcher.Contains('runtime\modules\init\initialize_nuc.ps1')) 'existing stage and launchers retain legacy entry'
