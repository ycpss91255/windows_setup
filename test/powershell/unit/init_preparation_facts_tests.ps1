#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'modules/init/init_entry_library.ps1')
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
$identity=[pscustomobject]@{Sid='S-1-5-21-1-2-3-500';UserSID='S-1-5-21-1-2-3-500';SessionId=44}
$nativeProfile=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile,[Environment+SpecialFolderOption]::DoNotVerify)
$script:setup=@{SystemSetupInProgress=0;OOBEInProgress=0};$script:throwRead=$false;$script:otherProfile=$false;$script:otherSession=$true;$script:localUser=$true;$script:processName='msoobe.exe'
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction);if($script:throwRead){throw 'fixture native failure'};if($ClassName -eq 'Win32_OperatingSystem'){return [pscustomobject]@{BuildNumber='26200';ProductType=1}};if($ClassName -ne 'Win32_Process' -or -not $Filter.Contains('msoobe.exe')){throw 'unapproved native query'};@([pscustomobject]@{Name=$script:processName;ProcessId=4242;SessionId=$(if($script:otherSession){99}else{44})})}
function Get-ItemProperty {param($LiteralPath,$ErrorAction);switch -Exact ($LiteralPath){'HKLM:\SYSTEM\Setup'{[pscustomobject]$script:setup} ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$identity.Sid){[pscustomobject]@{ProfileImagePath=$(if($script:otherProfile){$nativeProfile+'__other'}else{$nativeProfile})}} default{throw 'unapproved registry path'}}}
function Invoke-InitOobeCompleteNative {return @{Succeeded=$true;Complete=$false}}
function Get-LocalUser {param($SID,$ErrorAction);if(-not $script:localUser){throw 'not a local builtin account'};[pscustomobject]@{SID=$identity.Sid;Enabled=$false}}
function Test-Path {param($LiteralPath,$ErrorAction);if($LiteralPath -cne 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'){throw 'unapproved path probe'};return $false}
function Add-Type {throw 'SAFE_NATIVE_COMPILATION_TRAP'}
function New-Item {throw 'SAFE_MUTATION_TRAP'}
function CheckRoute($facts){Get-InitRoute $identity.Sid 'IMAGE_STATE_UNDEPLOYABLE' $true $true $facts}
$facts=Get-SetupInitPreparationFacts $identity
Assert ($facts.ReadSucceeded -and $facts.ProfileMatches -and $facts.LocalBuiltin -and -not $facts.OobeProcessInSession -and (CheckRoute $facts) -ceq 'PrepareOobe') 'native collector reads exact setup/profile paths and ignores other-session OOBE without relying on AuditBoot or requiring SAM Enabled (Microsoft KB3141410)'
$script:setup.SystemSetupInProgress=$null;$facts=Get-SetupInitPreparationFacts $identity
Assert ($null -eq $facts.SetupInProgress -and (CheckRoute $facts) -ceq 'PrepareOobe') 'absent undocumented flag is preserved as diagnostic instead of inventing zero'
$script:setup.SystemSetupInProgress='0';$facts=Get-SetupInitPreparationFacts $identity;Assert ($facts.SetupInProgress -is [string] -and (CheckRoute $facts) -ceq 'PrepareOobe') 'undocumented string flag is diagnostic and never coerced into mode proof'
$script:setup.SystemSetupInProgress=0;$script:otherProfile=$true
Assert ((CheckRoute (Get-SetupInitPreparationFacts $identity)) -ceq 'RejectUnknownSetupState') 'native profile does not match registered SID profile'
$script:otherProfile=$false;$script:otherSession=$false
Assert ((CheckRoute (Get-SetupInitPreparationFacts $identity)) -ceq 'RejectUnknownSetupState') 'current-session OOBE UI prevents preparation'
$script:processName='setup.exe';Assert ((CheckRoute (Get-SetupInitPreparationFacts $identity)) -ceq 'RejectUnknownSetupState') 'current-session Setup native process prevents preparation'
$script:otherSession=$true;$script:localUser=$false
Assert ((CheckRoute (Get-SetupInitPreparationFacts $identity)) -ceq 'RejectUnknownSetupState') 'domain or missing builtin SID500 is not accepted as local builtin'
$script:localUser=$true;$script:processName='msoobe.exe';$script:throwRead=$true;$facts=Get-SetupInitPreparationFacts $identity
Assert (-not $facts.ReadSucceeded -and (CheckRoute $facts) -ceq 'RejectUnknownSetupState') 'native read failures retain unknown state without writing or prompting'
$script:throwRead=$false;$script:otherSession=$false;$script:processName='sysprep.exe';$facts=Get-SetupInitPreparationFacts $identity
Assert ($facts.SetupProcessInSession -and @($facts.SetupProcessNames) -join ',' -ceq 'sysprep.exe' -and @($facts.SysprepProcessIds) -join ',' -ceq '4242' -and @($facts.OobeProcessNames).Count -eq 0 -and (CheckRoute $facts) -ceq 'RejectUnknownSetupState' -and (Test-InitSysprepDialogOnlyBlocker $identity.Sid 'IMAGE_STATE_SPECIALIZE_RESEAL_TO_AUDIT' $true $true $facts)) 'native collector records same-session Sysprep dialog name and process id so only that dialog can be closed (#481)'
$script:processName='setup.exe';$facts=Get-SetupInitPreparationFacts $identity
Assert (@($facts.SetupProcessNames) -join ',' -ceq 'setup.exe' -and @($facts.SysprepProcessIds).Count -eq 0 -and -not (Test-InitSysprepDialogOnlyBlocker $identity.Sid 'IMAGE_STATE_SPECIALIZE_RESEAL_TO_AUDIT' $true $true $facts)) 'same-session Setup process is never treated as the closable Sysprep dialog (#481)'
