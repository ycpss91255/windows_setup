#Requires -Version 5.1
$ErrorActionPreference='Stop'
. ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\modules\init\provisioning_library.ps1')))
$script:count=0
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw ('FAIL: '+$Name)};$script:count++}
Assert ([bool](Get-Command Confirm-InitAccountCheckpoint -ErrorAction SilentlyContinue)) 'Init completes account checkpoint without installing SSH'
$script:saves=New-Object Collections.Generic.List[object];$script:installed=$true
$sid='S-1-5-21-1-2-3-1001';$script:targetSid=$sid;$hash='a'*64
$context=@{OobeApiSucceeded=$true;OobeComplete=$true;MachineGuid='fixture';Sid=$sid;ProfilePath=$env:TEMP;RegisteredProfile=$env:TEMP;ImageState='IMAGE_STATE_COMPLETE';DesktopOwned=$true;IsAdministrator=$true}
function Get-LocalUser {param($SID,$ErrorAction) [pscustomobject]@{Name='fixture';SID=[pscustomobject]@{Value=$script:targetSid};Enabled=$true}}
function Get-LocalGroupMember {param($SID,$ErrorAction) [pscustomobject]@{SID=[pscustomobject]@{Value=$script:targetSid}}}
function Get-ProvisioningPackage {param([switch]$AllInstalledPackages,$ErrorAction) if($script:installed){[pscustomobject]@{IsInstalled=$true;PackageID='1c2605ea-96ae-42fc-8f11-45fc0cb9d133';Version='1.0';PackageName='windows_setup_hide_oobe'}}}
function Save-InitProvisioningState {param($State,$StatePath) $script:saves.Add(@{Path=$StatePath;Data=($State|ConvertTo-Json|ConvertFrom-Json)})}
function Test-Path {param($LiteralPath,$Path) $false}
function Get-Service {throw 'Init must not inspect SSH'}
function Start-Service {throw 'Init must not start SSH'}
function Add-WindowsCapability {throw 'Init must not install SSH'}
$path=Join-Path $env:TEMP 'fixture_checkpoint/state.json'
foreach($phase in @('AwaitingLogon','ApplyPending','SshPending','Complete')){
 $state=New-InitProvisioningState 'fixture' 'TEST' 'removed USB' $hash;$state.TargetSid=$sid;$state.TargetUserName='fixture';$state.Phase=$phase;$state.LastErrorCode='historical-marker'
 $script:saves.Clear()
 Confirm-InitAccountCheckpoint $state $path $context $hash
 Assert ($state.Phase -eq 'AccountConfirmed' -and $script:saves.Count -eq 2) ('account-only confirmation accepts '+$phase)
 Assert ($script:saves[0].Data.Phase -eq $phase -and $script:saves[0].Data.LastErrorCode -eq 'historical-marker' -and $script:saves[0].Path -ne $path) ('protected snapshot preserves original '+$phase+' state')
}
foreach($field in @('MachineGuid','Sid','RegisteredProfile','DesktopOwned','IsAdministrator')){
 $bad=$context.Clone();$bad[$field]=if($field -in @('DesktopOwned','IsAdministrator')){$false}else{'mismatch'}
 $before=$script:saves.Count;$rejected=$false;try{Confirm-InitAccountCheckpoint $state $path $bad $hash}catch{$rejected=$true}
 Assert ($rejected -and $script:saves.Count -eq $before) ('checkpoint rejects before changing state: '+$field)
}
$script:installed=$false;$before=$script:saves.Count
$rejected=$false;try{Confirm-InitAccountCheckpoint $state $path $context $hash}catch{$rejected=$true}
Assert ($rejected -and $script:saves.Count -eq $before) 'missing installed package cannot become account confirmed'
Assert ([bool](Get-Command Invoke-InitWindowsCheckpoint -ErrorAction SilentlyContinue)) 'Windows entry has an account-only Init checkpoint'
$script:hasStage=$false;$script:installed=$true
function Test-Path {param($LiteralPath,$Path) $script:hasStage}
function Get-InitProvisioningContext {return $context}
function Assert-InitProtectedDirectory {param($Path)}
function Assert-InitProvisioningAsset {param($AssetRoot) [pscustomobject]@{PackageSHA256=$hash}}
function Read-InitProvisioningState {param($StatePath,$MachineGuid,$PackageHash) return $state}
Assert (-not(Invoke-InitWindowsCheckpoint -StageRoot (Join-Path $env:TEMP 'fixture_checkpoint'))) 'Windows checkpoint is a no-op when no Init stage exists'
$script:hasStage=$true
Assert (Invoke-InitWindowsCheckpoint -StageRoot (Join-Path $env:TEMP 'fixture_checkpoint')) 'Windows entry validates existing Init account state without SSH'
$configure=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\core\configure_setup.ps1'))
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($configure,[ref]$tokens,[ref]$errors)
$hooks=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-InitWindowsCheckpoint'},$true))
Assert ($hooks.Count -eq 1) 'Windows main flow invokes exactly one Init account checkpoint'
$uac=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match 'principal\.IsInRole'},$true))[0]
$text=[IO.File]::ReadAllText($configure)
Assert ($hooks[0].Extent.StartOffset -gt $uac.Extent.EndOffset -and $hooks[0].Extent.StartOffset -lt $text.IndexOf("& (Resolve-NucPath 'test_setup_prerequisites.ps1')")) 'account checkpoint runs after elevation and before Windows work'
function Invoke-InitWindowsCheckpoint {param($StageRoot) $script:hookRoot=$StageRoot}
& ([scriptblock]::Create($hooks[0].Extent.Text))
Assert ($script:hookRoot -eq (Join-Path $env:ProgramData 'windows_setup_init')) 'actual Windows hook dynamically passes ProgramData stage without user or drive binding'
Write-Host ('ALL PASS: '+$script:count+' account checkpoint assertions; all OS operations mocked')
