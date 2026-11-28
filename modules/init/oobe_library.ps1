#Requires -Version 5.1
function Get-InitRoute {
 param([string]$Sid,[string]$ImageState,[bool]$IsAdministrator,[bool]$DesktopOwned,$ModeFacts)
 if($Sid -eq 'S-1-5-18'){return 'OobeProvisioning'}
 if($null -ne $ModeFacts){
  if($ModeFacts.ReadSucceeded -isnot [bool] -or -not $ModeFacts.ReadSucceeded){return 'RejectUnknownSetupState'}
  foreach($flag in @('IsWinPE','OobeApiSucceeded','OobeComplete','OobeProcessInSession','SetupProcessInSession','ProfileMatches','LocalBuiltin')){if($ModeFacts.$flag -isnot [bool]){return 'RejectUnknownSetupState'}}
  if($ModeFacts.Build -lt 22621 -or $ModeFacts.ProductType -ne 1 -or $ModeFacts.IsWinPE -or -not $ModeFacts.OobeApiSucceeded -or $ModeFacts.SetupProcessInSession -or $ModeFacts.OobeProcessInSession -or -not $ModeFacts.ProfileMatches -or -not $DesktopOwned){return 'RejectUnknownSetupState'}
  if($ImageState -eq 'IMAGE_STATE_COMPLETE' -and $ModeFacts.OobeComplete -and $Sid -notmatch '-500$'){if(-not $IsAdministrator){return 'ElevationRequired'};return 'DesktopReady'}
  # Operational eligibility only: no public IsAuditMode contract is inferred here.
  if($IsAdministrator -and $Sid -match '-500$' -and $ModeFacts.LocalBuiltin -and -not $ModeFacts.OobeComplete -and $ImageState -in (Get-InitPreparableImageState)){return 'PrepareOobe'}
  return 'RejectUnknownSetupState'
 }
 if(-not $IsAdministrator){return 'ElevationRequired'}
 if($Sid -match '-500$'){
  return 'RejectBuiltinAdministrator'
 }
 if($ImageState -eq 'IMAGE_STATE_COMPLETE' -and $DesktopOwned){return 'DesktopReady'}
 return 'RejectUnknownSetupState'
}
function Get-InitPreparableImageState {
 return @('IMAGE_STATE_UNDEPLOYABLE','IMAGE_STATE_GENERALIZE_RESEAL_TO_AUDIT','IMAGE_STATE_SPECIALIZE_RESEAL_TO_AUDIT','IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE','IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE')
}
function Format-InitProcessNames($Names) {
 $list=@($Names|Where-Object {$null -ne $_ -and [string]$_ -ne ''}|ForEach-Object {[string]$_})
 if($list.Count -eq 0){return '名稱未知'}
 return ($list -join '、')
}
# Plain-language reasons for RejectUnknownSetupState; never includes SID, user name or path.
function Get-InitRouteRejectReasons {
 param([string]$Sid,[string]$ImageState,[bool]$IsAdministrator,[bool]$DesktopOwned,$ModeFacts)
 if((Get-InitRoute -Sid $Sid -ImageState $ImageState -IsAdministrator $IsAdministrator -DesktopOwned $DesktopOwned -ModeFacts $ModeFacts) -cne 'RejectUnknownSetupState'){return @()}
 $reasons=New-Object 'System.Collections.Generic.List[string]'
 $stateText=$(if($ImageState){$ImageState}else{'（未讀到）'})
 $desktopText='不是目前帳號擁有的本機桌面（例如遠端、服務或其他使用者的工作階段）'
 if($null -eq $ModeFacts){
  if(-not $DesktopOwned){$reasons.Add($desktopText)}
  if($ImageState -ne 'IMAGE_STATE_COMPLETE'){$reasons.Add('映像狀態 '+$stateText+' 尚未完成，無法確認帳號準備條件')}
 }elseif($ModeFacts.ReadSucceeded -isnot [bool] -or -not $ModeFacts.ReadSucceeded){
  $reasons.Add('無法讀取系統狀態（Windows 版本、安裝狀態、OOBE 或使用者設定檔讀取失敗）')
 }else{
  $missing=@(@('IsWinPE','OobeApiSucceeded','OobeComplete','OobeProcessInSession','SetupProcessInSession','ProfileMatches','LocalBuiltin')|Where-Object {$ModeFacts.$_ -isnot [bool]})
  if($missing.Count){$reasons.Add('系統狀態資料不完整，缺少或無法判斷：'+($missing -join '、'))}
  if($ModeFacts.Build -lt 22621){$reasons.Add('Windows 組建 '+$(if($null -ne $ModeFacts.Build){$ModeFacts.Build}else{'未知'})+' 低於支援的 22621')}
  if($ModeFacts.ProductType -ne 1){$reasons.Add('不是 Windows 用戶端版本（ProductType='+$(if($null -ne $ModeFacts.ProductType){$ModeFacts.ProductType}else{'未知'})+'）')}
  if($ModeFacts.IsWinPE -eq $true){$reasons.Add('目前在 WinPE 環境，不是已安裝的 Windows')}
  if($ModeFacts.OobeApiSucceeded -eq $false){$reasons.Add('無法查詢 OOBE 是否完成')}
  if($ModeFacts.SetupProcessInSession -eq $true){
   $text='同一工作階段仍有安裝或系統準備程序（'+(Format-InitProcessNames $ModeFacts.SetupProcessNames)+'）'
   if(@($ModeFacts.SetupProcessNames|Where-Object {[string]$_ -ieq 'sysprep.exe'}).Count){$text+='；若是 Sysprep（系統準備工具）對話框，請按「取消」關閉後重跑 init.cmd'}
   $reasons.Add($text)
  }
  if($ModeFacts.OobeProcessInSession -eq $true){$reasons.Add('同一工作階段仍有 OOBE 程序（'+(Format-InitProcessNames $ModeFacts.OobeProcessNames)+'）')}
  if($ModeFacts.ProfileMatches -eq $false){$reasons.Add('目前帳號的使用者設定檔路徑與登錄紀錄不一致')}
  if(-not $DesktopOwned){$reasons.Add($desktopText)}
  if($reasons.Count -eq 0){
   if($Sid -match '-500$'){
    if(-not $IsAdministrator){$reasons.Add('未以系統管理員權限執行')}
    if($ModeFacts.LocalBuiltin -ne $true){$reasons.Add('目前帳號不是本機內建 Administrator')}
    if($ModeFacts.OobeComplete -eq $true){$reasons.Add('OOBE 已完成，不再準備新帳號')}
    if($ImageState -notin (Get-InitPreparableImageState)){$reasons.Add('映像狀態 '+$stateText+' 不是可準備新帳號的稽核或 OOBE 狀態')}
   }elseif($ImageState -eq 'IMAGE_STATE_COMPLETE'){$reasons.Add('映像狀態已完成，但 OOBE 尚未完成，兩者矛盾')}
   else{$reasons.Add('映像狀態 '+$stateText+' 尚未完成，且目前帳號不是內建 Administrator')}
  }
 }
 if($reasons.Count -eq 0){$reasons.Add('狀態組合無法判斷')}
 return [string[]]$reasons.ToArray()
}
# True when same-session Setup/OOBE processes are the only blockers, e.g. still finishing early in an Audit boot.
function Test-InitTransientSetupBlocker {
 param([string]$Sid,[string]$ImageState,[bool]$IsAdministrator,[bool]$DesktopOwned,$ModeFacts)
 if($Sid -notmatch '-500$' -or -not $IsAdministrator -or $ImageState -notin (Get-InitPreparableImageState)){return $false}
 if($ModeFacts -isnot [Collections.IDictionary] -or $ModeFacts.ReadSucceeded -isnot [bool] -or -not $ModeFacts.ReadSucceeded){return $false}
 if($ModeFacts.SetupProcessInSession -ne $true -and $ModeFacts.OobeProcessInSession -ne $true){return $false}
 $probe=@{};foreach($key in $ModeFacts.Keys){$probe[$key]=$ModeFacts[$key]};$probe['SetupProcessInSession']=$false;$probe['OobeProcessInSession']=$false
 return ((Get-InitRoute -Sid $Sid -ImageState $ImageState -IsAdministrator $IsAdministrator -DesktopOwned $DesktopOwned -ModeFacts $probe) -ceq 'PrepareOobe')
}
# True only when the sole blocker is the Sysprep dialog that Audit mode opens by itself.
function Test-InitSysprepDialogOnlyBlocker {
 param([string]$Sid,[string]$ImageState,[bool]$IsAdministrator,[bool]$DesktopOwned,$ModeFacts)
 if($Sid -notmatch '-500$' -or -not $IsAdministrator -or $ImageState -notmatch '^IMAGE_STATE_(GENERALIZE|SPECIALIZE)_RESEAL_TO_AUDIT$'){return $false}
 if($ModeFacts -isnot [Collections.IDictionary] -or $ModeFacts.SetupProcessInSession -isnot [bool] -or -not $ModeFacts.SetupProcessInSession -or $ModeFacts.OobeProcessInSession -isnot [bool] -or $ModeFacts.OobeProcessInSession -or $ModeFacts.LocalBuiltin -isnot [bool] -or -not $ModeFacts.LocalBuiltin -or $ModeFacts.OobeComplete -isnot [bool] -or $ModeFacts.OobeComplete){return $false}
 $names=@($ModeFacts.SetupProcessNames|Where-Object {$null -ne $_})
 $ids=@($ModeFacts.SysprepProcessIds|Where-Object {$_ -is [int] -and $_ -gt 0})
 if($names.Count -eq 0 -or @($names|Where-Object {[string]$_ -ine 'sysprep.exe'}).Count -or $ids.Count -eq 0){return $false}
 $probe=@{};foreach($key in $ModeFacts.Keys){$probe[$key]=$ModeFacts[$key]};$probe['SetupProcessInSession']=$false
 return ((Get-InitRoute -Sid $Sid -ImageState $ImageState -IsAdministrator $IsAdministrator -DesktopOwned $DesktopOwned -ModeFacts $probe) -ceq 'PrepareOobe')
}
function Test-InitUserName {
 param([string]$Name,[string[]]$ExistingNames)
 if([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 20 -or $Name -match '["/\\\[\]:;|=,+*?<>@\x00-\x1f]' -or $Name -match '^[. ]+$' -or $Name -ne $Name.Trim() -or $Name.EndsWith('.')){return $false}
 if($Name -in @('Administrator','Guest','DefaultAccount','defaultuser0','WDAGUtilityAccount','SYSTEM','Public') -or $Name -in $ExistingNames){return $false}
 return $true
}
function Test-InitPassword {
 param([string]$Password)
 return (-not [string]::IsNullOrEmpty($Password) -and $Password.Length -le 127 -and $Password -notmatch '[\x00-\x1f]')
}
function New-InitAnswerXml {
 param([string]$UserName,[string]$Password,[string]$CleanupCommand,[string]$Marker)
 if($Marker -notmatch '^NUC-INIT-[a-f0-9]{32}$'){throw 'Invalid ownership marker.'}
 $ns='urn:schemas-microsoft-com:unattend';$wcm='http://schemas.microsoft.com/WMIConfig/2002/State'
 $doc=New-Object Xml.XmlDocument
 [void]$doc.AppendChild($doc.CreateXmlDeclaration('1.0','utf-8',$null))
 [void]$doc.AppendChild($doc.CreateComment($Marker))
 $root=$doc.CreateElement('unattend',$ns);[void]$doc.AppendChild($root)
 function Element($Parent,[string]$Name,[string]$Text){$e=$doc.CreateElement($Name,$ns);if($PSBoundParameters.ContainsKey('Text')){$e.InnerText=$Text};[void]$Parent.AppendChild($e);return $e}
 $settings=Element $root 'settings';$settings.SetAttribute('pass','oobeSystem')
 $component=Element $settings 'component'
 foreach($pair in @(@('name','Microsoft-Windows-Shell-Setup'),@('processorArchitecture','amd64'),@('publicKeyToken','31bf3856ad364e35'),@('language','neutral'),@('versionScope','nonSxS'))){$component.SetAttribute($pair[0],$pair[1])}
 $oobe=Element $component 'OOBE'
 [void](Element $oobe 'HideOnlineAccountScreens' 'true')
 [void](Element $oobe 'HideWirelessSetupInOOBE' 'true')
 $accounts=Element $component 'UserAccounts';$locals=Element $accounts 'LocalAccounts';$account=Element $locals 'LocalAccount'
 [void]$account.SetAttribute('action',$wcm,'add')
 [void](Element $account 'Name' $UserName)
 [void](Element $account 'Group' 'Administrators')
 $passwordNode=Element $account 'Password'
 # Unattend encoding obscures the value; it is NOT encryption.
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Password+'Password'))
 [void](Element $passwordNode 'Value' $encoded);[void](Element $passwordNode 'PlainText' 'false')
 $first=Element $component 'FirstLogonCommands';$command=Element $first 'SynchronousCommand'
 [void]$command.SetAttribute('action',$wcm,'add')
 [void](Element $command 'Order' '1');[void](Element $command 'Description' 'Remove NUC Init temporary answer file')
 [void](Element $command 'CommandLine' $CleanupCommand)
 return $doc.OuterXml
}
function Get-InitAnswerCandidates {
 param([string]$WindowsPath)
 return @((Join-Path $WindowsPath 'Panther\unattend.xml'),(Join-Path $WindowsPath 'Panther\autounattend.xml'),(Join-Path $WindowsPath 'Panther\Unattend\unattend.xml'),(Join-Path $WindowsPath 'Panther\Unattend\autounattend.xml'),(Join-Path $WindowsPath 'System32\Sysprep\unattend.xml'))
}
function Assert-InitPlainPath {
 param([string]$Path)
 $current=[IO.Path]::GetFullPath($Path)
 while($current){
  if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('不接受重新解析點路徑：'+$current)}}
  $parent=Split-Path $current -Parent;if($parent -eq $current){break};$current=$parent
 }
}
function Protect-InitFolder {
 param([string]$Path)
 $acl=New-Object Security.AccessControl.DirectorySecurity
 $acl.SetAccessRuleProtection($true,$false)
 $admin=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
 $system=New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
 $acl.SetOwner($admin)
 foreach($sid in @($admin,$system)){$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))}
 Set-Acl -LiteralPath $Path -AclObject $acl
}
