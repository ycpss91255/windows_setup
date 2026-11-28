#Requires -Version 5.1
# 重開後自動驗收：登記與移除、工具包／驅動包不在、雜湊不符、次數上限、驅動已安裝狀態讀回。
# 只在 TEMP 內建立替身；排程、ACL 與桌面等待都以替身取代，不變更本機系統狀態。
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$script:count=0
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Name};$script:count++}
$library=Join-Path $root 'core/resume_library.ps1'
Assert (Test-Path -LiteralPath $library -PathType Leaf) '重開後自動驗收提供本機續跑程式庫'
Assert (Test-Path -LiteralPath (Join-Path $root 'core/resume_after_restart.ps1') -PathType Leaf) '重開後自動驗收提供登入後入口'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('after_restart_resume_'+[guid]::NewGuid().ToString('N'))
$program=Join-Path $temp 'programdata';$usb=Join-Path $temp 'usb';$package=Join-Path $usb 'kit';$driverPackage=Join-Path $usb 'windows_driver_packages\nuc8'
$utf=New-Object Text.UTF8Encoding($true)
function Write-Fixture([string]$Path,[string]$Text){[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text,$utf)}
function Get-Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
$oldProgram=$env:ProgramData
try{
 $env:ProgramData=$program;[void][IO.Directory]::CreateDirectory($program)
 . (Join-Path $root 'core/paths.ps1')
 . $library
 # ACL 與排程替身：只允許 TEMP 內路徑，記錄要求的保護方式與排程內容。
 $script:acl=@();$script:tasks=@{};$script:registerCount=0;$script:unregisterCount=0;$script:afterCalls=0;$script:rebootPending=$false
 function Assert-SetupGuiAncestors {param($CommonDataRoot) if(-not $CommonDataRoot.StartsWith($temp)){throw 'fixture outside TEMP'}}
 function New-SetupGuiProtectedDirectory {param($Path,$UserSid) if(-not $Path.StartsWith($temp)){throw 'fixture outside TEMP'};[void][IO.Directory]::CreateDirectory($Path);$script:acl+=@([pscustomobject]@{Path=$Path;UserSid=$UserSid})}
 $script:untrusted=''
 function Assert-SetupGuiProtectedPath {param($Path,[switch]$Directory,$UserSid) if(-not $Path.StartsWith($temp) -or -not(Test-Path -LiteralPath $Path)){throw ('fixture path absent: '+$Path)};if($script:untrusted -and ($Path -eq $script:untrusted -or $Path.StartsWith($script:untrusted+'\'))){throw 'GUI worker路徑擁有者不可信，保留原資料並拒絕接管。'}}
 function Get-ScheduledTask {param($TaskName,$ErrorAction) if($script:tasks.ContainsKey($TaskName)){$script:tasks[$TaskName]}}
 function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm,$ErrorAction) $script:unregisterCount++;$script:tasks.Remove($TaskName)}
 function New-ScheduledTaskTrigger {param([switch]$AtLogOn,$User) [pscustomobject]@{AtLogOn=[bool]$AtLogOn;User=$User;Delay=''}}
 function New-ScheduledTaskAction {param($Execute,$Argument) [pscustomobject]@{Execute=$Execute;Arguments=$Argument}}
 function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel) [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel}}
 function New-ScheduledTaskSettingsSet {param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$ExecutionTimeLimit,$MultipleInstances) [pscustomobject]@{ExecutionTimeLimit=$ExecutionTimeLimit;MultipleInstances=$MultipleInstances;Batteries=([bool]$AllowStartIfOnBatteries -and [bool]$DontStopIfGoingOnBatteries)}}
 function Register-ScheduledTask {param($TaskName,$TaskPath,$Description,$Action,$Trigger,$Principal,$Settings,$ErrorAction) $script:registerCount++;$script:tasks[$TaskName]=[pscustomobject]@{TaskName=$TaskName;Description=$Description;Actions=@($Action);Triggers=@($Trigger);Principal=$Principal;Settings=$Settings}}
 function Wait-SetupResumeDesktop {param($UserSid,$TimeoutSeconds) $true}
 function Test-SetupResumeRebootPending {$script:rebootPending}
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $account=(New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount]).Value
 $taskName='WindowsSetup-AfterRestart-Resume'

 # 工具包替身：含 runtime、驅動設定檔、驅動封存檔、維護工具、文件與每機結果。
 foreach($name in @('init.cmd','windows.cmd','readme.md','core/paths.ps1','core/resume_after_restart.ps1','modules/display/apply_display_settings.ps1','modules/debloat/win11debloat/Assets/Start/What is this file.txt','drivers/p1/profile.json','drivers/p1/manifest.json','drivers/p1/readme.md','drivers/p1/payload.zip','script/test/run_ci.ps1','test/powershell/unit/x_tests.ps1','doc/guide.md','reports/Setup-Result.json','core/Old-Result.json','modules/display/Display-Verification.json')){Write-Fixture (Join-Path $package $name) ('fixture '+$name)}
 Write-Fixture (Join-Path $package '.version') 'v9.9.9'
 $expected=@('.version','core/paths.ps1','core/resume_after_restart.ps1','drivers/p1/manifest.json','drivers/p1/profile.json','init.cmd','modules/debloat/win11debloat/Assets/Start/What is this file.txt','modules/display/apply_display_settings.ps1','readme.md','windows.cmd')
 $list=@(Get-SetupResumeRuntimeFiles -PackageRoot $package)
 Assert ((@($list|Sort-Object) -join '|') -ceq (@($expected|Sort-Object) -join '|')) ('只複製續跑必需的 runtime，不含驅動封存檔、維護工具、文件與每機結果；actual='+($list -join ','))
 $real=@(Get-SetupResumeRuntimeFiles -PackageRoot $root)
 Assert ($real -contains 'core/resume_after_restart.ps1' -and $real -contains 'core/verify_after_restart.ps1' -and $real -contains 'modules/drivers/install_drivers.ps1' -and $real -contains 'drivers/nuc8i7hvk_hnk/profile.json' -and $real -contains 'windows.cmd') '實際工具包的 runtime 清單包含重開後驗收需要的入口、模組與驅動設定檔'
 Assert (@($real|Where-Object {$_ -match '^(script|test|doc|vendor|reports|\.github|\.git)/' -or $_ -match '\.(zip|exe)$' -and $_ -notmatch '^modules/'}).Count -eq 0) '實際 runtime 清單不含維護工具、測試、文件、報告與驅動封存檔'
 $pathMap=[IO.File]::ReadAllText((Join-Path $root 'core/paths.json'))|ConvertFrom-Json
 $registered=@($pathMap.PSObject.Properties|ForEach-Object {[string]$_.Value}|Where-Object {$_ -match '^(core|modules)/' -and $_ -notmatch '-(Result|Verification)\.json$' -and (Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf)}|Sort-Object -Unique)
 Assert (@($registered|Where-Object {$_ -notin $real}).Count -eq 0) '路徑登錄表中每個存在的 runtime 檔案都會複製到本機'

 # 驅動包替身：身分與清單小檔加上大封存檔；登記只保存身分與清單。
 Write-Fixture (Join-Path $driverPackage 'package.json') '{"SchemaVersion":2}'
 Write-Fixture (Join-Path $driverPackage 'manifest.json') '{"SchemaVersion":2,"Packages":[]}'
 Write-Fixture (Join-Path $driverPackage 'lan.zip') 'archive payload'
 $selection=[pscustomobject]@{SchemaVersion=1;RelativePath='..\windows_driver_packages\nuc8';AbsolutePath=$driverPackage;PackageSHA256=(Get-Hash (Join-Path $driverPackage 'package.json')).ToUpperInvariant();ManifestSHA256=(Get-Hash (Join-Path $driverPackage 'manifest.json')).ToUpperInvariant()}
 $hardware=[pscustomobject]@{DriverProfileId='p1';DriverPackagePath=$driverPackage;DriverSelection=$selection}
 $script:NucPackageRoot=$package
 function Write-SetupResultFixture([datetime]$CompletedAt){[void][IO.Directory]::CreateDirectory((Join-Path $package 'reports'));@{Computer=$env:COMPUTERNAME;UserSID=$sid;CompletedAt=$CompletedAt.ToString('o');FailedModules=@();HardwareProfile=@{DriverPackagePath=$driverPackage;DriverSelection=$selection}}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $package 'reports/Setup-Result.json') -Encoding UTF8}
 Write-SetupResultFixture (Get-Date)
 $registration=Invoke-SetupResumeRegistration -PackageRoot $package -Hardware $hardware -StartedAt (Get-Date).AddMinutes(-5)
 $paths=Get-SetupResumePaths
 Assert ($registration.Registered -and $paths.Root.StartsWith($program) -and $paths.Root -like '*\NUC8-Setup\resume') ('一鍵流程結束時登記重開後自動驗收；error='+$registration.Error)
 $task=$script:tasks[$taskName]
 Assert ($null -ne $task -and $script:registerCount -eq 1 -and $task.Description -ceq 'windows_setup after-restart resume v1') '登記一次固定名稱與所有權描述的排程'
 Assert ($task.Principal.UserId -ceq $sid -and $task.Principal.LogonType -ceq 'Interactive' -and $task.Principal.RunLevel -ceq 'Highest') '排程以原帳號、互動桌面、最高權限執行，不跳 UAC'
 Assert ($task.Triggers.Count -eq 1 -and $task.Triggers[0].AtLogOn -and $task.Triggers[0].User -ceq $account -and $task.Triggers[0].Delay -ceq 'PT30S') '只在原帳號登入後觸發，並等待桌面穩定'
 $entry=Join-Path $paths.Runtime 'core\resume_after_restart.ps1'
 $arguments=[string]$task.Actions[0].Arguments
 Assert ($task.Actions.Count -eq 1 -and ([string]$task.Actions[0].Execute).EndsWith('WindowsPowerShell\v1.0\powershell.exe') -and $arguments.Contains('-NoExit') -and $arguments.Contains('-File "'+$entry+'"') -and -not $arguments.Contains('Hidden')) '登入後只開一個可見的 Windows PowerShell 終端機執行本機入口'
 Assert ($arguments.EndsWith('-ManifestSHA256 '+$registration.ManifestSHA256) -and $registration.ManifestSHA256 -ceq (Get-Hash $paths.Manifest)) '排程參數帶登記時的清單雜湊'
 Assert ($task.Settings.ExecutionTimeLimit -eq [TimeSpan]::Zero -and $task.Settings.Batteries -and [string]$task.Settings.MultipleInstances -ceq 'IgnoreNew') '排程不因時間上限或電池中斷，也不重複啟動'
 Assert ((Test-Path -LiteralPath (Join-Path $paths.Runtime 'core\paths.ps1')) -and (Test-Path -LiteralPath (Join-Path $paths.Runtime 'drivers\p1\profile.json')) -and -not(Test-Path -LiteralPath (Join-Path $paths.Runtime 'drivers\p1\payload.zip')) -and -not(Test-Path -LiteralPath (Join-Path $paths.Runtime 'script')) -and -not(Test-Path -LiteralPath (Join-Path $paths.Runtime 'test')) -and -not(Test-Path -LiteralPath (Join-Path $paths.Runtime 'reports'))) '本機 runtime 只有必需檔案'
 Assert ((Test-Path -LiteralPath (Join-Path $paths.Driver 'package.json')) -and (Test-Path -LiteralPath (Join-Path $paths.Driver 'manifest.json')) -and -not(Test-Path -LiteralPath (Join-Path $paths.Driver 'lan.zip'))) '驅動只保存身分與清單，不複製封存檔'
 $manifest=Get-Content -LiteralPath $paths.Manifest -Raw -Encoding UTF8|ConvertFrom-Json
 $hashesMatch=@($manifest.Files|Where-Object {$_.SHA256 -cne (Get-Hash (Join-Path $package $_.Path))}).Count -eq 0
 Assert ($manifest.Schema -eq 1 -and $manifest.SourceVersion -ceq 'v9.9.9' -and $manifest.Computer -ceq $env:COMPUTERNAME -and $manifest.UserSID -ceq $sid -and @($manifest.Files).Count -eq $expected.Count -and $hashesMatch -and $manifest.Driver.ManifestSHA256 -ceq $selection.ManifestSHA256.ToLowerInvariant()) '清單記錄來源版本、同機同帳號與逐檔 SHA256'
 Assert ((Get-Content -LiteralPath $paths.Attempts -Raw|ConvertFrom-Json).Attempts -eq 0) '登記時自動驗收次數歸零'
 Assert ((Get-Hash (Join-Path $paths.Reports 'Setup-Result.json')) -ceq (Get-Hash (Join-Path $package 'reports/Setup-Result.json'))) '本輪續跑紀錄複製到本機報告位置'
 Assert (@($script:acl|Where-Object {$_.Path -eq $paths.Root -and -not $_.UserSid}).Count -eq 1 -and @($script:acl|Where-Object {$_.Path -eq $paths.Runtime -and -not $_.UserSid}).Count -eq 1 -and @($script:acl|Where-Object {$_.Path -eq $paths.Reports -and $_.UserSid -ceq $sid}).Count -eq 1) 'runtime 只給 SYSTEM 與管理員；報告另給原帳號讀取'

 $again=Invoke-SetupResumeRegistration -PackageRoot $package -Hardware $hardware -StartedAt (Get-Date).AddMinutes(-5)
 Assert ($again.Registered -and $script:registerCount -eq 2 -and $script:unregisterCount -eq 1 -and $script:tasks.Count -eq 1) '再次執行一鍵流程只取代本工具自己的登記'

 Write-SetupResultFixture (Get-Date).AddHours(-1)
 $stale=Invoke-SetupResumeRegistration -PackageRoot $package -Hardware $hardware -StartedAt (Get-Date).AddMinutes(-5)
 Assert (-not $stale.Registered -and $stale.Error.Contains('不是本輪') -and -not $script:tasks.ContainsKey($taskName) -and -not(Test-Path -LiteralPath $paths.Root)) '本輪沒有新的續跑紀錄時不登記，並移除先前的登記與暫存'
 Write-SetupResultFixture (Get-Date)

 $script:tasks[$taskName]=[pscustomobject]@{TaskName=$taskName;Description='someone else';Actions=@([pscustomobject]@{Execute='cmd.exe';Arguments='/c other'})}
 $foreign=Invoke-SetupResumeRegistration -PackageRoot $package -Hardware $hardware -StartedAt (Get-Date).AddMinutes(-5)
 Assert (-not $foreign.Registered -and $foreign.Error.Contains('拒絕覆寫') -and $script:tasks[$taskName].Description -ceq 'someone else') '同名但不是本工具的排程不覆寫'
 $script:tasks.Remove($taskName)

 # resume 目錄不是本工具建立的受保護目錄：停止接管，保留原資料，不登記。
 [void][IO.Directory]::CreateDirectory($paths.Root);$marker=Join-Path $paths.Root 'someone_else.txt';[IO.File]::WriteAllText($marker,'keep')
 $script:untrusted=$paths.Root
 $untrustedRun=Invoke-SetupResumeRegistration -PackageRoot $package -Hardware $hardware -StartedAt (Get-Date).AddMinutes(-5)
 $script:untrusted=''
 Assert (-not $untrustedRun.Registered -and $untrustedRun.Error.Contains('不可信') -and (Test-Path -LiteralPath $marker) -and -not $script:tasks.ContainsKey($taskName)) ('不可信的 resume 目錄停止接管並保留原資料；error='+$untrustedRun.Error)
 Remove-Item -LiteralPath $paths.Root -Recurse -Force

 $badHardware=[pscustomobject]@{DriverProfileId='p1';DriverPackagePath=$driverPackage;DriverSelection=[pscustomobject]@{SchemaVersion=1;PackageSHA256=$selection.PackageSHA256;ManifestSHA256=('0'*64)}}
 $badDriver=Invoke-SetupResumeRegistration -PackageRoot $package -Hardware $badHardware -StartedAt (Get-Date).AddMinutes(-5)
 Assert (-not $badDriver.Registered -and $badDriver.Error.Contains('驅動包清單') -and -not $script:tasks.ContainsKey($taskName) -and -not(Test-Path -LiteralPath $paths.Root)) '驅動清單與本輪選擇不同時不登記'

 # 以下續跑情境都先拔除 USB：工具包與驅動包都不在。
 function New-ResumeFixture {$r=Invoke-SetupResumeRegistration -PackageRoot $package -Hardware $hardware -StartedAt (Get-Date).AddMinutes(-5);if(-not $r.Registered){throw ('fixture registration failed: '+$r.Error)};$script:afterCalls=0;$script:rebootPending=$false;return $r.ManifestSHA256}
 function Write-AcceptanceFixture([string[]]$Failed){@{CheckedAt=(Get-Date).ToString('o');Success=$false;FailedChecks=@($Failed|ForEach-Object {@{Name=$_;Passed=$false;Status='Failed'}})}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $paths.Reports 'Acceptance-Result.json') -Encoding UTF8}
 $hash=New-ResumeFixture
 $stagedHashes=@{};foreach($file in @((Get-Content -LiteralPath $paths.Manifest -Raw|ConvertFrom-Json).Files)){$stagedHashes[$file.Path]=$file.SHA256}
 Remove-Item -LiteralPath $usb -Recurse -Force
 Assert (-not(Test-Path -LiteralPath $usb)) 'USB 已拔除：工具包與驅動包都不在'
 Assert ((Test-SetupResumeRuntime -PackageRoot $paths.Runtime) -and -not(Test-SetupResumeRuntime -PackageRoot $package)) '只有本機續跑位置被視為自動驗收 runtime'
 $script:NucPackageRoot=$paths.Runtime
 Assert ((Resolve-NucPath 'Acceptance-Result.json') -eq (Join-Path $paths.Reports 'Acceptance-Result.json') -and (Resolve-NucPath 'Setup-Result.json') -eq (Join-Path $paths.Reports 'Setup-Result.json')) '自動驗收的報告寫在本機 ProgramData，不寫 USB'
 $script:NucPackageRoot=$package
 Assert ((Resolve-NucPath 'Setup-Result.json') -eq (Join-Path $package 'reports\Setup-Result.json')) '從工具包手動執行時報告位置維持工具包旁'
 Write-Fixture (Join-Path $paths.Runtime 'modules\display\Display-Verification.json') 'per-machine result'
 $done=Invoke-SetupResumeAfterRestart -ManifestSHA256 $hash -RuntimeRoot $paths.Runtime -AfterRestart {$script:afterCalls++}
 Assert ($done.Status -ceq 'Completed' -and $script:afterCalls -eq 1) ('USB 不在時以本機複本完成驗收；actual='+$done.Status+' '+$done.Message)
 Assert (-not $script:tasks.ContainsKey($taskName) -and -not(Test-Path -LiteralPath $paths.Root)) '驗收通過後移除登記與本機暫存'
 $saved=Get-Content -LiteralPath (Join-Path $paths.Reports 'AfterRestartResume-Result.json') -Raw|ConvertFrom-Json
 Assert ($saved.Status -ceq 'Completed' -and $saved.Attempt -eq 1 -and (Test-Path -LiteralPath (Join-Path $paths.Reports 'Setup-Result.json'))) '本機報告保留自動驗收結果'

 # 本機複本被改動：不執行驗收、移除登記並保留檔案供檢查。這裡沒有 USB，登記改由已保存的本機狀態重建。
 function Restore-ResumeFixture {
  # USB 已拔除；以測試前保存的工具包替身重建，模擬另一輪一鍵流程的登記。
  foreach($name in $expected){Write-Fixture (Join-Path $package $name) $(if($name -eq '.version'){'v9.9.9'}else{'fixture '+$name})}
  Write-Fixture (Join-Path $driverPackage 'package.json') '{"SchemaVersion":2}'
  Write-Fixture (Join-Path $driverPackage 'manifest.json') '{"SchemaVersion":2,"Packages":[]}'
  Write-SetupResultFixture (Get-Date)
  $value=New-ResumeFixture
  Remove-Item -LiteralPath $usb -Recurse -Force
  return $value
 }
 $hash=Restore-ResumeFixture
 Assert (@((Get-Content -LiteralPath $paths.Manifest -Raw|ConvertFrom-Json).Files|Where-Object {$stagedHashes[$_.Path] -cne $_.SHA256}).Count -eq 0) '重建的替身與原工具包雜湊相同'
 [IO.File]::AppendAllText((Join-Path $paths.Runtime 'core\paths.ps1'),'tampered')
 $tampered=Invoke-SetupResumeAfterRestart -ManifestSHA256 $hash -RuntimeRoot $paths.Runtime -AfterRestart {$script:afterCalls++}
 Assert ($tampered.Status -ceq 'IntegrityFailed' -and $script:afterCalls -eq 0 -and $tampered.Message.Contains('core/paths.ps1')) '本機檔案雜湊不符時停止並說明哪個檔案'
 Assert (-not $script:tasks.ContainsKey($taskName) -and (Test-Path -LiteralPath $paths.Root)) '雜湊不符時移除登記，保留本機檔案供檢查'

 $hash=Restore-ResumeFixture
 Write-Fixture (Join-Path $paths.Runtime 'core\extra.ps1') 'unexpected code'
 $extra=Invoke-SetupResumeAfterRestart -ManifestSHA256 $hash -RuntimeRoot $paths.Runtime -AfterRestart {$script:afterCalls++}
 Assert ($extra.Status -ceq 'IntegrityFailed' -and $script:afterCalls -eq 0 -and $extra.Message.Contains('core/extra.ps1')) '本機續跑位置有未登記程式檔時停止'

 $hash=Restore-ResumeFixture
 $wrong=Invoke-SetupResumeAfterRestart -ManifestSHA256 ('a'*64) -RuntimeRoot $paths.Runtime -AfterRestart {$script:afterCalls++}
 Assert ($wrong.Status -ceq 'IntegrityFailed' -and $script:afterCalls -eq 0 -and $wrong.Message.Contains('清單')) '清單雜湊與排程登記值不同時停止'

 # 清單的同機、同帳號比對：清單雜湊相符但內容屬於另一臺電腦或另一個帳號時停止。
 foreach($field in @('Computer','UserSID')){
  $hash=Restore-ResumeFixture
  $value=Get-Content -LiteralPath $paths.Manifest -Raw -Encoding UTF8|ConvertFrom-Json
  $value.$field='fixture-foreign-'+$field
  Write-SetupGuiAtomicJson -Path $paths.Manifest -Value $value
  $foreignHash=Get-Hash $paths.Manifest
  $identity=Invoke-SetupResumeAfterRestart -ManifestSHA256 $foreignHash -RuntimeRoot $paths.Runtime -AfterRestart {$script:afterCalls++}
  Assert ($identity.Status -ceq 'IntegrityFailed' -and $script:afterCalls -eq 0 -and $identity.Message.Contains('同機、同帳號')) ('續跑清單不是同機、同帳號時停止：'+$field)
 }

 # 次數紀錄因目錄 ACL 不符而判定超過上限：移除登記，但不刪除未確認擁有權的目錄。
 $hash=Restore-ResumeFixture
 $script:untrusted=$paths.Root
 $foreignRoot=Invoke-SetupResumeAfterRestart -ManifestSHA256 $hash -RuntimeRoot $paths.Runtime -AfterRestart {$script:afterCalls++}
 $script:untrusted=''
 Assert ($foreignRoot.Status -ceq 'AttemptLimit' -and $script:afterCalls -eq 0 -and -not $script:tasks.ContainsKey($taskName) -and (Test-Path -LiteralPath $paths.Runtime) -and $foreignRoot.Message.Contains('保留')) ('未確認擁有權的續跑目錄只移除登記並保留；message='+$foreignRoot.Message)

 $hash=Restore-ResumeFixture
 Remove-Item -LiteralPath (Join-Path $paths.Driver 'manifest.json') -Force
 $driverMissing=Invoke-SetupResumeAfterRestart -ManifestSHA256 $hash -RuntimeRoot $paths.Runtime -AfterRestart {$script:afterCalls++}
 Assert ($driverMissing.Status -ceq 'IntegrityFailed' -and $script:afterCalls -eq 0) '本機保存的驅動清單缺少時停止'

 # 仍需重開：保留登記並提示；第三次仍需重開就停止並移除登記。
 $hash=Restore-ResumeFixture
 $needRestart={$script:afterCalls++;Write-AcceptanceFixture @('無待處理重新開機');throw '驗收尚未全部通過。'}
 $first=Invoke-SetupResumeAfterRestart -ManifestSHA256 $hash -RuntimeRoot $paths.Runtime -AfterRestart $needRestart
 Assert ($first.Status -ceq 'RestartRequired' -and $first.Attempt -eq 1 -and $script:tasks.ContainsKey($taskName) -and (Test-Path -LiteralPath $paths.Runtime) -and $first.Message.Contains('1/3')) '仍需重開時保留登記並提示次數'
 $second=Invoke-SetupResumeAfterRestart -ManifestSHA256 $hash -RuntimeRoot $paths.Runtime -AfterRestart $needRestart
 Assert ($second.Status -ceq 'RestartRequired' -and $second.Attempt -eq 2 -and $script:tasks.ContainsKey($taskName)) '第二次仍需重開時繼續保留'
 $third=Invoke-SetupResumeAfterRestart -ManifestSHA256 $hash -RuntimeRoot $paths.Runtime -AfterRestart $needRestart
 Assert ($third.Status -ceq 'AttemptLimit' -and $third.Attempt -eq 3 -and $script:afterCalls -eq 3 -and -not $script:tasks.ContainsKey($taskName) -and -not(Test-Path -LiteralPath $paths.Root) -and $third.Message.Contains('windows.cmd -AfterRestart')) '達到 3 次上限時停止、說明並移除登記'

 $hash=Restore-ResumeFixture
 Write-SetupGuiAtomicJson -Path $paths.Attempts -Value ([ordered]@{Attempts=3})
 $limit=Invoke-SetupResumeAfterRestart -ManifestSHA256 $hash -RuntimeRoot $paths.Runtime -AfterRestart {$script:afterCalls++}
 Assert ($limit.Status -ceq 'AttemptLimit' -and $script:afterCalls -eq 0 -and -not $script:tasks.ContainsKey($taskName) -and -not(Test-Path -LiteralPath $paths.Root)) '超過次數時不再執行驗收（例如前次中途當掉）'

 $hash=Restore-ResumeFixture
 '{broken'|Set-Content -LiteralPath $paths.Attempts -Encoding UTF8
 $broken=Invoke-SetupResumeAfterRestart -ManifestSHA256 $hash -RuntimeRoot $paths.Runtime -AfterRestart {$script:afterCalls++}
 Assert ($broken.Status -ceq 'AttemptLimit' -and $script:afterCalls -eq 0) '次數紀錄損壞時視為超過上限，不會無限重跑'

 $hash=Restore-ResumeFixture
 $script:rebootPending=$true
 $pending=Invoke-SetupResumeAfterRestart -ManifestSHA256 $hash -RuntimeRoot $paths.Runtime -AfterRestart {$script:afterCalls++;throw '更新後要求重新開機'}
 Assert ($pending.Status -ceq 'RestartRequired' -and $script:tasks.ContainsKey($taskName)) 'Windows 要求重開時保留登記'

 $hash=Restore-ResumeFixture
 $failed=Invoke-SetupResumeAfterRestart -ManifestSHA256 $hash -RuntimeRoot $paths.Runtime -AfterRestart {$script:afterCalls++;Write-AcceptanceFixture @('SSH');throw '驗收尚未全部通過。'}
 Assert ($failed.Status -ceq 'Failed' -and -not $script:tasks.ContainsKey($taskName) -and -not(Test-Path -LiteralPath $paths.Root) -and $failed.Message.Contains('windows.cmd -AfterRestart')) '不是重開可解決的失敗時移除登記並說明手動入口'

 $hash=Restore-ResumeFixture
 $outside=$null;try{Invoke-SetupResumeAfterRestart -ManifestSHA256 $hash -RuntimeRoot $temp -AfterRestart {$script:afterCalls++}|Out-Null}catch{$outside=$_.Exception.Message}
 Assert ($outside -and $outside.Contains('本機續跑位置') -and $script:afterCalls -eq 0) '自動驗收只能從本機續跑位置執行'
 Remove-SetupResumeRegistration -Paths $paths
 Assert (-not $script:tasks.ContainsKey($taskName) -and -not(Test-Path -LiteralPath $paths.Root) -and (Test-Path -LiteralPath $paths.Reports)) '移除登記只清除排程與本機暫存，保留報告'

 # 驅動包不在：改以本機保存的清單核對身分並讀回已安裝驅動，不把找不到驅動包當失敗。
 $original=Join-Path $temp 'driver_original';$staged=Join-Path $temp 'driver_staged'
 $profileFile=Join-Path $root 'drivers/nuc8i7hvk_hnk/profile.json'
 $hw=Get-SetupHardwareProfile -BoardProduct 'NUC8i7HVB' -UICulture 'zh-TW'
 $identity=[ordered]@{SchemaVersion=2;ProfileId=$hw.DriverProfileId;Architecture=$hw.DriverProfileData.Architecture;ProfileSHA256=$hw.DriverProfileData.ProfileSHA256;SupportedBoards=@($hw.DriverProfileData.SupportedBoards)}
 foreach($dir in @($original,$staged)){
  Write-Fixture (Join-Path $dir 'package.json') ($identity|ConvertTo-Json -Depth 4)
  Copy-Item -LiteralPath (Join-Path $root 'drivers/nuc8i7hvk_hnk/manifest.json') -Destination (Join-Path $dir 'manifest.json')
 }
 $driverSelection=[pscustomobject]@{SchemaVersion=1;RelativePath='';AbsolutePath=$original;PackageSHA256=(Get-FileHash -LiteralPath (Join-Path $original 'package.json')).Hash;ManifestSHA256=(Get-FileHash -LiteralPath (Join-Path $original 'manifest.json')).Hash}
 $resultFile=Join-Path $temp 'driver_result.json'
 @{Computer=$env:COMPUTERNAME;UserSID=$sid;HardwareProfile=@{DriverPackagePath=$original;DriverSelection=$driverSelection}}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $resultFile -Encoding UTF8
 $present=Get-SetupResumeDriverSelection -ResultPath $resultFile -StagedDriverRoot $staged
 Assert ($present.Path -eq $original -and -not $present.PayloadAbsent -and $present.Selection.ManifestSHA256 -eq $driverSelection.ManifestSHA256) '原驅動包仍在原位置且身分相同時維持現行完整驗證'
 Remove-Item -LiteralPath $original -Recurse -Force
 $absent=Get-SetupResumeDriverSelection -ResultPath $resultFile -StagedDriverRoot $staged
 Assert ($absent.Path -eq $staged -and $absent.PayloadAbsent) '驅動包不在時改用本機保存的清單'
 [IO.File]::AppendAllText((Join-Path $staged 'manifest.json'),' ')
 $mismatch=$null;try{$null=Get-SetupResumeDriverSelection -ResultPath $resultFile -StagedDriverRoot $staged}catch{$mismatch=$_.Exception.Message}
 Assert ($mismatch -and $mismatch.Contains('本機保存的驅動清單與原選擇不同')) '本機保存的驅動清單被改動時拒絕驗收'
 Copy-Item -LiteralPath (Join-Path $root 'drivers/nuc8i7hvk_hnk/manifest.json') -Destination (Join-Path $staged 'manifest.json') -Force
 @{Computer=$env:COMPUTERNAME;UserSID=$sid;HardwareProfile=@{DriverPackagePath=''}}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $resultFile -Encoding UTF8
 $none=Get-SetupResumeDriverSelection -ResultPath $resultFile -StagedDriverRoot $staged
 Assert ($none.Path -eq '' -and -not $none.PayloadAbsent) '本輪未選驅動包時不驗收驅動'

 $missing=$null;try{$null=Test-SetupDriverPayload -Hardware $hw -DriverPackagePath $staged}catch{$missing=$_.Exception.Message}
 Assert ($null -ne $missing) ('一般入口仍要求驅動包在場並驗證包內設定檔與封存檔；actual='+$missing)
 $installed=Test-SetupDriverPayload -Hardware $hw -DriverPackagePath $staged -InstalledStateOnly
 Assert ($installed.Status -ceq 'InstalledState' -and $installed.Reason.Contains('已安裝')) '驅動包不在時只核清單身分，找不到封存檔不算失敗'
 $foreignPackage=Join-Path $temp 'driver_foreign';Write-Fixture (Join-Path $foreignPackage 'package.json') ((@{SchemaVersion=2;ProfileId=$hw.DriverProfileId;Architecture='x64';ProfileSHA256=('0'*64);SupportedBoards=@($hw.DriverProfileData.SupportedBoards)})|ConvertTo-Json)
 Copy-Item -LiteralPath (Join-Path $staged 'manifest.json') -Destination (Join-Path $foreignPackage 'manifest.json')
 $foreignIdentity=$null;try{$null=Test-SetupDriverPayload -Hardware $hw -DriverPackagePath $foreignPackage -InstalledStateOnly}catch{$foreignIdentity=$_.Exception.Message}
 Assert ($foreignIdentity -and $foreignIdentity.Contains('識別不符')) '已安裝狀態驗收仍核對驅動清單與目前硬體身分'

 . (Join-Path $root 'modules/drivers/driver_installation_library.ps1')
 $synthetic=Join-Path $temp 'driver_synthetic'
 Write-Fixture (Join-Path $synthetic 'manifest.json') (@{SchemaVersion=2;AuditedAt='2026-11-01';Packages=@(@{Id='fixture_lan';PackageVersion='1.0';File='fixture_lan.zip';SHA256=('a'*64);SourceUrl='https://www.intel.com/fixture';Drivers=@(@{InfPath='lan/e1d.inf';DriverVersion='12.19.1.37';Provider='Intel';Architecture='amd64';MinimumBuild=10240;HardwareIds=@('PCI\VEN_8086&DEV_15BC')})})}|ConvertTo-Json -Depth 8)
 $script:deviceVersion='12.19.1.37'
 function Get-SetupDriverDeviceInventory {param($Targets) @([pscustomobject]@{InstanceId='PCI\VEN_8086&DEV_15BC\FIXTURE';Name='fixture';Class='Net';HardwareIds=@('PCI\VEN_8086&DEV_15BC');HardwareIdsReadError='';Status='OK';Present=$true;ProblemCode=$null;DriverInfPath='oem1.inf';DriverInfName='oem1.inf';DriverMetadataReadError='';DriverSignatureKnown=$true;DriverSigner='fixture';DriverProvider='Intel';DriverVersion=$script:deviceVersion;DriverSigned=$true})}
 $archiveMissing=$null;try{$null=Invoke-SetupDriverVerification -DriverRoot $synthetic}catch{$archiveMissing=$_.Exception.Message}
 Assert ($null -ne $archiveMissing) '一般驗證缺少封存檔時仍失敗'
 $current=Invoke-SetupDriverVerification -DriverRoot $synthetic -InstalledStateOnly
 Assert ($current.Success -and @($current.Targets).Count -eq 1 -and $current.Targets[0].Status -ceq 'Current' -and $current.Targets[0].CurrentVersion -ceq '12.19.1.37') '驅動包不在時讀回裝置無異常且版本符合紀錄即通過'
 $script:deviceVersion='12.18.0.1'
 $older=Invoke-SetupDriverVerification -DriverRoot $synthetic -InstalledStateOnly
 Assert (-not $older.Success -and $older.Targets[0].Status -ceq 'UpdateRequired') '已安裝驅動版本低於紀錄時如實失敗'
 Write-Host ('ALL PASS: '+$script:count+' after-restart resume assertions; TEMP fixtures and command stubs only.')
}finally{
 $env:ProgramData=$oldProgram
 Set-Location -LiteralPath $root
 if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
}
