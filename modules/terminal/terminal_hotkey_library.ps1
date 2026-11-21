#Requires -Version 5.1
# Named runtime implementation: dot-sourcing defines functions without changing Windows.
function Get-SetupTerminalKnownFolder {
 param([Environment+SpecialFolder]$Folder,[Environment+SpecialFolderOption]$Option=[Environment+SpecialFolderOption]::None)
 [Environment]::GetFolderPath($Folder,$Option)
}
function Get-SetupTerminalContext {
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 $startupRoot=Get-SetupTerminalKnownFolder -Folder Startup
 if([string]::IsNullOrWhiteSpace($startupRoot)){$startupRoot=Get-SetupTerminalKnownFolder -Folder Startup -Option DoNotVerify}
 if([string]::IsNullOrWhiteSpace($startupRoot)){
  $appData=Get-SetupTerminalKnownFolder -Folder ApplicationData -Option DoNotVerify
  if([string]::IsNullOrWhiteSpace($appData)){throw '無法解析目前使用者的啟動目錄。'}
  $startupRoot=Join-Path $appData 'Microsoft/Windows/Start Menu/Programs/Startup'
 }
 [pscustomobject]@{Folder=(Join-Path $env:LOCALAPPDATA 'NUC8-Setup\TerminalHotkey');Startup=(Join-Path $startupRoot 'Terminal Hotkey.lnk');IdentityName=$identity.Name;UserSID=$identity.User.Value;UserHome=$env:USERPROFILE;PowerShell=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe');ReportPath=(Join-Path $env:ProgramData 'NUC8-Setup/TerminalHotkey-Result.json')}
}
function Get-SetupTerminalCallerSession {[Diagnostics.Process]::GetCurrentProcess().SessionId}
function Get-SetupTerminalDesktopSession {
 param([string]$UserSID)
 $caller=Get-SetupTerminalCallerSession
 if($caller -gt 0){return $caller}
 if($caller -ne 0){throw '無法識別互動桌面。'}
 $matching=@(foreach($process in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)){
  if($process.SessionId -le 0){continue}
  $owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop
  if(($owner.ReturnValue -is [uint32] -or $owner.ReturnValue -is [int]) -and $owner.ReturnValue -eq 0 -and $owner.Sid -ceq $UserSID){[int]$process.SessionId}
 })
 $sessions=@($matching|Select-Object -Unique)
 if($sessions.Count -ne 1){throw '找不到同一使用者唯一的互動桌面。'}
 return $sessions[0]
}
function New-SetupTerminalShell {New-Object -ComObject WScript.Shell}
function Copy-SetupTerminalFiles {
 param([string]$ModuleRoot,[string]$DestinationRoot)
 . (Join-Path $ModuleRoot '../native/managed_source_library.ps1')
 foreach($name in @('terminal_hotkey_listener.ps1','terminal_hotkey_library.ps1')){Copy-Item -LiteralPath (Join-Path $ModuleRoot $name) -Destination (Join-Path $DestinationRoot $name) -Force}
 $null=Copy-SetupManagedSource -SourceRoot $ModuleRoot -DestinationRoot $DestinationRoot -FileName 'terminal_hotkey.cs'
}
function Invoke-SetupTerminalHotkey {
 param([Parameter(Mandatory=$true)][string]$ModuleRoot,[switch]$VerifyOnly)
 $ErrorActionPreference='Stop'
 $context=Get-SetupTerminalContext
 $desktopSession=Get-SetupTerminalDesktopSession -UserSID $context.UserSID
 $folder=$context.Folder;$listener=Join-Path $folder 'terminal_hotkey_listener.ps1';$log=Join-Path $folder ('status-'+$desktopSession+'.log');$startup=$context.Startup
 $taskName='NUC8-TerminalHotkey-'+$context.UserSID+'-'+$desktopSession;$exe=$context.PowerShell
$argsText='-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$listener+'"'
if(-not $VerifyOnly){
 if(-not(Get-Command wt.exe -ErrorAction SilentlyContinue)){throw '找不到 Windows Terminal，請先安裝。'}
 New-Item -ItemType Directory $folder -Force|Out-Null
 New-Item -ItemType Directory (Split-Path -Parent $startup) -Force|Out-Null
 Copy-SetupTerminalFiles -ModuleRoot $ModuleRoot -DestinationRoot $folder
 $shell=New-SetupTerminalShell
 $link=$shell.CreateShortcut($startup)
 $link.TargetPath=$exe;$link.Arguments=$argsText;$link.WorkingDirectory=$context.UserHome;$link.WindowStyle=7;$link.Hotkey='';$link.Save()
 $action=New-ScheduledTaskAction -Execute $exe -Argument $argsText
 $principal=New-ScheduledTaskPrincipal -UserId $context.IdentityName -LogonType Interactive -RunLevel Limited
 $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
 if(-not $task -or $task.State -ne 'Running'){
  Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force|Out-Null
  $alreadyRunning=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object {$_.SessionId -eq $desktopSession -and $_.CommandLine -and $_.CommandLine.Contains($listener)})
  if($alreadyRunning.Count -eq 0){Start-ScheduledTask $taskName}
 }
 for($i=0;$i -lt 20;$i++){if((Test-Path $log) -and ([IO.File]::ReadAllText($log)) -match 'REGISTERED|FAILED'){break};Start-Sleep -Seconds 1}
}
$legacyLog=Join-Path $folder 'status.log'
$text=if(Test-Path $log){[IO.File]::ReadAllText($log)}elseif(Test-Path $legacyLog){[IO.File]::ReadAllText($legacyLog)}else{''}
$currentSession=$desktopSession
$running=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object {$_.CommandLine -and $_.CommandLine.Contains($listener) -and $_.SessionId -eq $currentSession})
$linkOK=$false
if(Test-Path $startup){$link=(New-SetupTerminalShell).CreateShortcut($startup);$linkOK=$link.Arguments.Contains($listener)}
$registeredPID=if($text -match '^REGISTERED: PID=([0-9]+) '){$Matches[1]}else{''}
$success=($registeredPID -ne '' -and $text -notmatch 'FAILED' -and @($running|Where-Object {[string]$_.ProcessId -ceq $registeredPID}).Count -gt 0 -and $linkOK)
New-Item -ItemType Directory (Split-Path $context.ReportPath) -Force|Out-Null
[ordered]@{Success=$success;User=$context.IdentityName;Shortcut='Ctrl+Alt+T';StartupLink=$startup;ListenerPath=$listener;ProcessIDs=@($running.ProcessId);Log=$text;CheckedAt=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 4|Set-Content $context.ReportPath -Encoding UTF8
if(-not $success){throw ('Terminal 快捷鍵未成功註冊：'+$text)}
Write-Host 'Ctrl + Alt + T 已註冊，登入後自動啟用，以一般使用者權限開啟 Terminal。' -ForegroundColor Green
}
function New-SetupTerminalMutex {New-Object Threading.Mutex($false,'Local\NUC8TerminalHotkey')}
function Invoke-SetupTerminalNative {
 param([string]$ModuleRoot,[string]$Terminal,[string]$LogPath,[string]$UserHome)
 Add-Type -Path (Join-Path $ModuleRoot 'native/terminal_hotkey.cs')
 [WindowsSetupTerminalHotkey]::Run($Terminal,$LogPath,$UserHome)
}
function Invoke-SetupTerminalListener {
 param([Parameter(Mandatory=$true)][string]$ModuleRoot)
 $ErrorActionPreference='Stop'
 $context=Get-SetupTerminalContext;$session=Get-SetupTerminalCallerSession
 if($session -le 0){throw 'Terminal listener 必須在互動桌面執行。'}
 $log=Join-Path $context.Folder ('status-'+$session+'.log')
 New-Item -ItemType Directory $context.Folder -Force|Out-Null
 $mutex=New-SetupTerminalMutex;$owned=$false
 try{
  $owned=$mutex.WaitOne(0)
  if(-not $owned){return}
  Invoke-SetupTerminalNative -ModuleRoot $ModuleRoot -Terminal (Get-Command wt.exe -ErrorAction Stop).Source -LogPath $log -UserHome $context.UserHome
 }finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
