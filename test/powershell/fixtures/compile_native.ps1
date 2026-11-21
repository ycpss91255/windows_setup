#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$SourcePath,[Parameter(Mandatory=$true)][string]$TypeName,[Parameter(Mandatory=$true)][string]$Methods)
$ErrorActionPreference='Stop'
Add-Type -Path $SourcePath -ReferencedAssemblies 'System.dll','System.Core.dll','System.Xml.dll'
$type=$TypeName -as [type]
if(-not $type){throw ('Compiled public type is missing: '+$TypeName)}
foreach($method in ($Methods -split ',')){if(-not $type.GetMethod($method,[Reflection.BindingFlags]'Public,Static')){throw ('Public API is missing: '+$method)}}
if($TypeName -eq 'WindowsSetupDisplay.Display'){
 $mode='WindowsSetupDisplay.Mode' -as [type]
 if([Runtime.InteropServices.Marshal]::SizeOf([Activator]::CreateInstance($mode)) -ne 220){throw 'DEVMODEW ABI size changed'}
 $newMode=$type.GetMethod('NewMode',[Reflection.BindingFlags]'NonPublic,Static').Invoke($null,@())
 if($newMode.dmSize -ne 220){throw 'Managed mode initializer does not preserve ABI header'}
}
Write-Output ('PASS: original source compiled under PS '+$PSVersionTable.PSVersion+'; ABI '+$TypeName)