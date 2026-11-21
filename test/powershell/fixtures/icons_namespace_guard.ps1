param([Parameter(Mandatory=$true)][string]$Root,[ValidateSet('OldOnly','NewOnly')][string]$Case)
$ErrorActionPreference='Stop'
$fake='using System; namespace WindowsSetupIcons { public static class Desktop { public static int Captures; public static object Capture(){Captures++;return new {Width=1920,Height=1080,Icons=new[]{new {Name="a",X=0,Y=0},new {Name="b",X=1,Y=0},new {Name="c",X=2,Y=0},new {Name="d",X=3,Y=0}}};} public static void Position(int i,int x,int y){throw new Exception("unexpected Position");} } }'
if($Case -eq 'OldOnly'){Microsoft.PowerShell.Utility\Add-Type -TypeDefinition 'using System; namespace NUC8Icons { public static class Desktop { public static object Capture(){throw new Exception("old type used");} } }'}else{Microsoft.PowerShell.Utility\Add-Type -TypeDefinition $fake}
$script:loads=0
function Add-Type {param([string]$Path) $script:loads++; if($script:loads -ne 1 -or $Case -ne 'OldOnly' -or $Path -ne (Join-Path $Root 'modules/desktop/native/desktop_icons.cs')){throw 'unexpected managed load'}; Microsoft.PowerShell.Utility\Add-Type -TypeDefinition $fake}
. (Join-Path $Root 'modules/desktop/icons_settings_library.ps1')
function Get-SetupSystemIconNames {@('a','b','c','d')}
foreach($i in 1..2){$r=Invoke-SetupIconsSettings -ModuleRoot (Join-Path $Root 'modules/desktop') -Mode Save;if(-not $r.Success){throw 'fake Save failed'}}
if($script:loads -ne $(if($Case -eq 'OldOnly'){1}else{0})){throw 'incorrect load count'}
if([WindowsSetupIcons.Desktop]::Captures -ne 2){throw 'new type not selected twice'}
Write-Output ('PASS: '+$Case)
