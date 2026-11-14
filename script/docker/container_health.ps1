#Requires -Version 5.1
function Test-ContainerToolHealth {
 try {
  if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){return $false}
  Assert-CIRequiredTools -Managed | Out-Null
  Invoke-CINative -File cmd.exe -Arguments @('/d','/c','exit 0') | Out-Null
  return $true
 } catch {
  return $false
 }
}
