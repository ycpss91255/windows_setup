#Requires -Version 5.1
function Get-SetupSSHFirewallStatus {
 try {
  $rules=@(Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue)
  if($rules.Count -ne 1){return [pscustomobject]@{Passed=$false;Detail='缺少或重複 OpenSSH 防火牆規則。'}}
  $rule=$rules[0]
  $addresses=@($rule|Get-NetFirewallAddressFilter -ErrorAction Stop|Select-Object -ExpandProperty RemoteAddress)
  $filters=@($rule|Get-NetFirewallPortFilter -ErrorAction Stop)
  $valid=$rule.Enabled.ToString() -eq 'True' -and $rule.Direction.ToString() -eq 'Inbound' -and $rule.Action.ToString() -eq 'Allow' -and $rule.Profile.ToString() -eq 'Any'
  $valid=$valid -and $addresses.Count -eq 1 -and $addresses[0] -eq 'LocalSubnet' -and $filters.Count -eq 1
  if($filters.Count -eq 1){$ports=@($filters[0].LocalPort);$valid=$valid -and $filters[0].Protocol.ToString() -in @('TCP','6') -and $ports.Count -eq 1 -and $ports[0] -eq '22'}
  [pscustomobject]@{Passed=[bool]$valid;Detail=('Enabled='+$rule.Enabled+'; Direction='+$rule.Direction+'; Action='+$rule.Action+'; Profile='+$rule.Profile+'; RemoteAddress='+($addresses -join ',')+'; Protocol/Port='+(@($filters|ForEach-Object {$_.Protocol.ToString()+'/'+($_.LocalPort -join ',')}) -join ';'))}
 } catch {[pscustomobject]@{Passed=$false;Detail=('無法驗證 SSH 防火牆：'+$_.Exception.Message)}}
}
function Add-SetupSSHFirewallVerificationCheck {
 $sshFirewall=Get-SetupSSHFirewallStatus
 Add-Check 'SSH 防火牆規則' $sshFirewall.Passed $sshFirewall.Detail
}
function Set-SetupSSHFirewallRule {
 $name='OpenSSH-Server-In-TCP'
 if(Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue){Set-NetFirewallRule -Name $name -Protocol TCP -LocalPort 22 -Enabled True -Direction Inbound -Action Allow -Profile Any -RemoteAddress LocalSubnet}
 else{New-NetFirewallRule -Name $name -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any -RemoteAddress LocalSubnet|Out-Null}
 $sshFirewall=Get-SetupSSHFirewallStatus
 if(-not $sshFirewall.Passed){throw $sshFirewall.Detail}
}
