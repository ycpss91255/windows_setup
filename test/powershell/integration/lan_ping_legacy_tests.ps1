#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
$library=Join-Path $root 'modules/ssh/lan_ping_library.ps1'
Assert (Test-Path -LiteralPath $library -PathType Leaf) 'named LAN Ping definitions exist'
. $library
Assert ([bool](Get-Command Invoke-SetupLanPingSettings -ErrorAction SilentlyContinue)) 'named LAN Ping boundary exists'
$script:rules=@{};$script:operations=[Collections.Generic.List[object]]::new();$script:fail=''
function Get-NetFirewallRule {param($Name,$ErrorAction) if($script:fail -eq 'read'){throw 'fixture read failure'};if($script:rules.ContainsKey($Name)){return $script:rules[$Name]}}
function Set-NetFirewallRule {[CmdletBinding()]param($Name,$Enabled,$Direction,$Action,$Profile,$Protocol,$IcmpType,$RemoteAddress) if($script:fail -eq 'write'){throw 'fixture write failure'};$script:operations.Add(@{Operation='Set';Name=$Name;Profile=$Profile;Protocol=$Protocol;Type=$IcmpType;RemoteAddress=$RemoteAddress});$script:rules[$Name]=[pscustomobject]@{Name=$Name;Enabled=$Enabled;Direction=$Direction;Action=$Action;Protocol=$Protocol;IcmpType=$IcmpType;RemoteAddress=$RemoteAddress}}
function New-NetFirewallRule {[CmdletBinding()]param($Name,$DisplayName,$Enabled,$Direction,$Action,$Profile,$Protocol,$IcmpType,$RemoteAddress) if($script:fail -eq 'write'){throw 'fixture write failure'};$script:operations.Add(@{Operation='New';Name=$Name;DisplayName=$DisplayName;Profile=$Profile;Protocol=$Protocol;Type=$IcmpType;RemoteAddress=$RemoteAddress});$script:rules[$Name]=[pscustomobject]@{Name=$Name;Enabled=$Enabled;Direction=$Direction;Action=$Action;Protocol=$Protocol;IcmpType=$IcmpType;RemoteAddress=$RemoteAddress}}
function Get-NetFirewallAddressFilter {param([Parameter(ValueFromPipeline=$true)]$InputObject) process{[pscustomobject]@{RemoteAddress=$InputObject.RemoteAddress}}}
function Get-NetFirewallPortFilter {param([Parameter(ValueFromPipeline=$true)]$InputObject) process{[pscustomobject]@{Protocol=$InputObject.Protocol;IcmpType=$InputObject.IcmpType}}}
$cases=@(@{Name='NUC8-LAN-Ping-v4';Protocol='ICMPv4';Type=8},@{Name='NUC8-LAN-Ping-v6';Protocol='ICMPv6';Type=128})
foreach($exists in @($true,$false)){
 $script:rules=@{};$script:operations.Clear()
 if($exists){foreach($item in $cases){$script:rules[$item.Name]=[pscustomobject]@{Name=$item.Name;Enabled='False';Direction='Outbound';Action='Block';Protocol='bad';IcmpType=0;RemoteAddress='Any'}}}
 Invoke-SetupLanPingSettings
 Assert ($script:operations.Count -eq 2) ('exactly two legacy rules converged existing='+$exists)
 foreach($item in $cases){$op=@($script:operations|Where-Object {$_.Name -ceq $item.Name});Assert ($op.Count -eq 1 -and $op[0].Operation -ceq $(if($exists){'Set'}else{'New'}) -and $op[0].Profile -ceq 'Any' -and $op[0].Protocol -ceq $item.Protocol -and $op[0].Type -eq $item.Type -and $op[0].RemoteAddress -ceq 'LocalSubnet' -and ($exists -or $op[0].DisplayName -ceq ('NUC LAN Ping '+$item.Protocol))) ('legacy rule uses expected provider parameters '+$item.Name)}
}
$script:operations.Clear();Invoke-SetupLanPingSettings -VerifyOnly;Assert ($script:operations.Count -eq 0) 'VerifyOnly accepts both legacy rules without writes'
foreach($mode in @('missing','scope','protocol','type','read','write')){
 $script:rules=@{};$script:operations.Clear();$script:fail=''
 foreach($item in $cases){$script:rules[$item.Name]=[pscustomobject]@{Name=$item.Name;Enabled='True';Direction='Inbound';Action='Allow';Protocol=$item.Protocol;IcmpType=$item.Type;RemoteAddress='LocalSubnet'}}
 switch($mode){missing{$script:rules.Remove('NUC8-LAN-Ping-v4')} scope{$script:rules['NUC8-LAN-Ping-v4'].RemoteAddress='Any'} protocol{$script:rules['NUC8-LAN-Ping-v4'].Protocol='UDP'} type{$script:rules['NUC8-LAN-Ping-v4'].IcmpType=9} read{$script:fail='read'} write{$script:fail='write'}}
 $message='';try{if($mode -eq 'write'){Invoke-SetupLanPingSettings}else{Invoke-SetupLanPingSettings -VerifyOnly}}catch{$message=$_.Exception.Message}
 $expected=switch($mode){missing{'缺少區域網路 Ping 規則：NUC8-LAN-Ping-v4'} read{'fixture read failure'} write{'fixture write failure'} default{'Ping 規則內容不符：NUC8-LAN-Ping-v4'}}
 Assert ($message -ceq $expected -and ($mode -eq 'write' -or $script:operations.Count -eq 0)) ('failure is not accepted '+$mode)
}
$entry=Join-Path $root 'modules/ssh/apply_lan_ping_settings.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0 -and $ast.ScriptRequirements.IsElevationRequired) 'public entry retains administrator requirement'
$calls=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-SetupLanPingSettings'},$true))
Assert ($calls.Count -eq 1) 'public entry invokes named boundary once'
$flags=@($calls[0].CommandElements | Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'VerifyOnly'})
Assert ($flags.Count -eq 1 -and $flags[0].Argument -is [Management.Automation.Language.VariableExpressionAst] -and $flags[0].Argument.VariablePath.UserPath -eq 'VerifyOnly') 'public entry forwards VerifyOnly switch'
$text=[IO.File]::ReadAllText($entry)
Assert ($text.Contains("'mdns_library.ps1'") -and $text.Contains('Get-SetupMdnsStatus') -and $text.Contains('Format-SetupMdnsConnectionInfo')) 'public entry retains mDNS tail'
$map=Get-Content -LiteralPath (Join-Path $root 'core/paths.json') -Raw|ConvertFrom-Json
Assert ($map.'lan_ping_library.ps1' -ceq 'modules/ssh/lan_ping_library.ps1') 'named library has package mapping'
Assert ([IO.File]::ReadAllText((Join-Path $root 'core/test_setup_prerequisites.ps1')).Contains("'lan_ping_library.ps1'")) 'named library required by preflight'
