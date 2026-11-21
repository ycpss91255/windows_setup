param([Parameter(Mandatory=$true)][string]$Module,[switch]$VerifyOnly,[switch]$Restore,[switch]$SyncOnly,[ValidateSet('All','Hosts','SSH')][string]$Mode='All',[string]$DriverPackagePath,[string]$ExpectedUserSID,[string]$ConfirmedBoard,[string]$ConfirmationComputer,[switch]$NonInteractive,[switch]$ApplyPolicy)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'entry_os_boundary.ps1')
$sid=Get-SetupEntryIdentity
if($ExpectedUserSID -and $ExpectedUserSID -ne $sid){throw '請用原本登入帳號提權，不可改用另一個管理員帳號執行獨立模組。'}
if($DriverPackagePath){$DriverPackagePath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DriverPackagePath)}
. (Join-Path $PSScriptRoot 'paths.ps1')
$allowed=@('Apply-UACSettings','Apply-PrivacySettings','Apply-HostsSync','Remove-OneDrive','Remove-SetupResidue','Apply-ExplorerSettings','Apply-TerminalHotkey','Apply-InputMethodSettings','Apply-StartMenuSettings','Apply-AMDPrivacySettings','Apply-CopilotSettings','Apply-AutologonSettings','Apply-PowerSettings','Apply-SSHSettings','Apply-MdnsSettings','Install-Drivers','Install-WindowsUpdates','Apply-Debloat','Apply-TaskbarSettings','Apply-DisplaySettings','Apply-DesktopSettings','Apply-ThemeSettings','Desktop-IconLayout','Apply-PagefileSettings')
if($ApplyPolicy -and $Module -ne 'Apply-StartMenuSettings'){throw 'ApplyPolicy 僅適用開始選單。'}
if($Restore -and ($Module -ne 'Apply-UACSettings' -or $VerifyOnly)){throw 'Restore僅適用UAC且不可與VerifyOnly同時使用。'}
if($Module -notin $allowed){throw 'Unknown module'}
if($Module -ne 'Apply-HostsSync' -and ($SyncOnly -or $Mode -ne 'All')){throw 'SyncOnly/Mode only apply to Apply-HostsSync.'}
$isAdmin=Test-SetupEntryAdministrator
if(-not $isAdmin){
 $command="& '"+$PSCommandPath.Replace("'","''")+"' -Module '"+$Module.Replace("'","''")+"'"
 $command+=" -ExpectedUserSID '"+$sid.Replace("'","''")+"'"
 if($VerifyOnly){$command+=' -VerifyOnly'}
 if($ApplyPolicy -and -not $VerifyOnly){$command+=' -ApplyPolicy'}
 if($Restore){$command+=' -Restore'}
 if($Module -eq 'Apply-HostsSync'){$command+=' -Mode '+$Mode;if($SyncOnly){$command+=' -SyncOnly'}}
 if($PSBoundParameters.ContainsKey('DriverPackagePath')){$command+=" -DriverPackagePath '"+$DriverPackagePath.Replace("'","''")+"'"}
 if($NonInteractive){$command+=' -NonInteractive'}
 if($ConfirmedBoard){$command+=" -ConfirmedBoard '"+$ConfirmedBoard.Replace("'","''")+"' -ConfirmationComputer '"+$ConfirmationComputer.Replace("'","''")+"'"}
 Start-SetupEntryElevated -Command $command;return
}
$driverArguments=@{ConfirmedBoard=$ConfirmedBoard;ConfirmationComputer=$ConfirmationComputer;NonInteractive=$NonInteractive}
if($PSBoundParameters.ContainsKey('DriverPackagePath')){$driverArguments.DriverPackagePath=$DriverPackagePath}
$path=Resolve-SetupPath ($Module+'.ps1')
if($Restore){& $path -Restore}
elseif($Module -eq 'Apply-HostsSync'){
 $options=@{Mode=$Mode}
 if($VerifyOnly){$options.VerifyOnly=$true}elseif($SyncOnly){$options.SyncOnly=$true}
 & $path @options
}elseif($Module -eq 'Apply-StartMenuSettings'){
 & $path -VerifyOnly:$VerifyOnly -ApplyPolicy:($ApplyPolicy -and -not $VerifyOnly) -NonInteractive:$NonInteractive
}elseif($Module -eq 'Install-Drivers'){
 & $path -VerifyOnly:$VerifyOnly @driverArguments
}elseif($VerifyOnly){
 if($Module -eq 'Desktop-IconLayout'){& $path -Mode Verify}
 else{if(-not (Get-Command $path).Parameters.ContainsKey('VerifyOnly')){throw 'This module does not support VerifyOnly. Use windows.cmd -VerifyOnly.'};& $path -VerifyOnly}
}else{& $path}
