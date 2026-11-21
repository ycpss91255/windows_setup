#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Message){Write-Host ('@@ASSERT@@'+(@{Name=$Message;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Message}}
$helper=Join-Path $root 'modules/ssh/ssh_firewall.ps1'
$tokens=$null;$errors=$null
$helperAst=[System.Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
if($errors.Count -ne 0){throw 'SSH helper parse failed'}
$qualified=@($helperAst.FindAll({param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $null -ne $node.GetCommandName() -and $node.GetCommandName().Contains('\')},$true))
if($qualified.Count -ne 0){throw 'module-qualified commands bypass fixture stubs'}
. $helper
Assert ([bool](Get-Command Add-SetupSSHFirewallVerificationCheck -CommandType Function -ErrorAction SilentlyContinue)) 'named VerifyOnly firewall entry exists'
Assert ([bool](Get-Command Set-SetupSSHFirewallRule -CommandType Function -ErrorAction SilentlyContinue)) 'named installer firewall entry exists'
# All firewall, registry and service commands are intercepted; unexpected operations fail closed.
function Get-ItemProperty {throw 'unexpected registry read'}
function Set-ItemProperty {throw 'unexpected registry write'}
function New-ItemProperty {throw 'unexpected registry write'}
function Remove-ItemProperty {throw 'unexpected registry write'}
function Get-Service {throw 'unexpected service read'}
function Set-Service {throw 'unexpected service write'}
function Start-Service {throw 'unexpected service write'}
function Stop-Service {throw 'unexpected service write'}
function Get-NetFirewallRule {[CmdletBinding()]param($Name);if($Name -cne 'OpenSSH-Server-In-TCP'){throw 'unexpected firewall rule lookup'};if(-not $script:missing){$script:rule}}
function Get-NetFirewallAddressFilter {[CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject);process{if($InputObject -ne $script:rule){throw 'unexpected address filter input'};[pscustomobject]@{RemoteAddress=$script:addresses}}}
function Get-NetFirewallPortFilter {[CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject);process{if($InputObject -ne $script:rule){throw 'unexpected port filter input'};[pscustomobject]@{Protocol=$script:protocol;LocalPort=$script:ports}}}
function Invoke-VerifyFixture {
 $checks=New-Object Collections.Generic.List[object]
 function Add-Check([string]$Name,[bool]$Passed,[string]$Detail){$checks.Add([pscustomobject]@{Name=$Name;Passed=$Passed;Detail=$Detail})}
 Add-SetupSSHFirewallVerificationCheck
 return $checks.ToArray()
}
foreach($kind in @('disabled','outbound','blocked','udp','wrong_port','extra_port','broad_scope','limited_profile','missing','valid','numeric_tcp')){
 $script:rule=[pscustomobject]@{Enabled='True';Direction='Inbound';Action='Allow';Profile='Any'};$script:addresses=@('LocalSubnet');$script:protocol='TCP';$script:ports=@('22');$script:missing=$false
 switch($kind){
  disabled{$script:rule.Enabled='False'}
  outbound{$script:rule.Direction='Outbound'}
  blocked{$script:rule.Action='Block'}
  udp{$script:protocol='UDP'}
  wrong_port{$script:ports=@('2222')}
  extra_port{$script:ports=@('22','80')}
  broad_scope{$script:addresses=@('LocalSubnet','Any')}
  limited_profile{$script:rule.Profile='Private'}
  missing{$script:missing=$true}
  numeric_tcp{$script:protocol='6'}
 }
 $result=@(Invoke-VerifyFixture)
 Assert ($result.Count -eq 1 -and $result[0].Name -ceq 'SSH 防火牆規則' -and $result[0].Passed -eq ($kind -in @('valid','numeric_tcp')) -and -not [string]::IsNullOrEmpty($result[0].Detail)) ('actual VerifyOnly SSH firewall contract: '+$kind)
}
function Set-NetFirewallRule {[CmdletBinding()]param($Name,$Enabled,$Direction,$Action,$Profile,$RemoteAddress,$Protocol,$LocalPort);if($Name -cne 'OpenSSH-Server-In-TCP'){throw 'unexpected Set rule'};$script:updated=$PSBoundParameters;$script:rule=[pscustomobject]@{Enabled=$Enabled;Direction=$Direction;Action=$Action;Profile=$Profile};if($script:rejectWrite){$script:rule.Enabled='False'};$script:addresses=@($RemoteAddress);$script:protocol=$Protocol;$script:ports=@($LocalPort);'set-output'}
function New-NetFirewallRule {[CmdletBinding()]param($Name,$DisplayName,$Enabled,$Direction,$Action,$Profile,$RemoteAddress,$Protocol,$LocalPort);if($Name -cne 'OpenSSH-Server-In-TCP' -or $DisplayName -cne 'OpenSSH Server (sshd)'){throw 'unexpected New rule'};$script:updated=$PSBoundParameters;$script:missing=$false;$script:rule=[pscustomobject]@{Enabled=$Enabled;Direction=$Direction;Action=$Action;Profile=$Profile};if($script:rejectWrite){$script:rule.Enabled='False'};$script:addresses=@($RemoteAddress);$script:protocol=$Protocol;$script:ports=@($LocalPort);'new-output'}
$script:rejectWrite=$false
foreach($exists in @($true,$false)){
 $script:missing=-not $exists;$script:rule=[pscustomobject]@{Enabled='False';Direction='Outbound';Action='Block'};$script:protocol='UDP';$script:ports=@('80');$script:addresses=@('Any');$script:updated=$null
 $output=@(Set-SetupSSHFirewallRule)
 Assert ($script:updated.Protocol -eq 'TCP' -and $script:updated.LocalPort -eq '22' -and $script:updated.RemoteAddress -eq 'LocalSubnet' -and $script:updated.Enabled -eq 'True' -and $script:updated.Direction -eq 'Inbound' -and $script:updated.Action -eq 'Allow' -and $script:updated.Profile -eq 'Any') ('installer converges existing or new rule including protocol and port: '+$exists)
 Assert (($exists -and $output.Count -eq 1 -and $output[0] -ceq 'set-output') -or (-not $exists -and $output.Count -eq 0)) ('installer preserves Set output and suppresses New output: '+$exists)
}
$script:missing=$false;$script:rejectWrite=$true;$failure=''
try{Set-SetupSSHFirewallRule|Out-Null}catch{$failure=$_.Exception.Message}
Assert ($failure -match '^Enabled=False;') 'installer throws readback detail when configured rule is invalid'
# Parse real entry points without executing service, registry, or system commands.
$tokens=$null;$errors=$null
$verifyAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'core/verification_library.ps1'),[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'verification entry parses'
$verifyFunction=$verifyAst.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-SetupVerification'},$true)
$verifyCalls=@($verifyFunction.FindAll({param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-SetupSSHFirewallVerificationCheck'},$true))
Assert ($verifyCalls.Count -eq 1) 'real VerifyOnly entry invokes named firewall check'
$tokens=$null;$errors=$null
$installAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'modules/ssh/apply_ssh_settings.ps1'),[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'installer entry parses'
$installCalls=@($installAst.FindAll({param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Start-Service','Set-SetupSSHFirewallRule','Get-Service')},$true))
Assert ($installCalls.Count -eq 3 -and $installCalls[0].GetCommandName() -eq 'Start-Service' -and $installCalls[1].GetCommandName() -eq 'Set-SetupSSHFirewallRule' -and $installCalls[2].GetCommandName() -eq 'Get-Service') 'real installer calls firewall entry after service start and before service status'
