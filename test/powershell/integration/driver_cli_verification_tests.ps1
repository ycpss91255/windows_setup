#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
$entry=Join-Path $root 'modules/drivers/install_drivers.ps1'
Assert ((Get-Command $entry).Parameters.ContainsKey('VerifyOnly')) '獨立驅動入口明確接受唯讀驗證而非忽略未知參數'
$fixture=Join-Path $env:TEMP ('driver_cli_'+[guid]::NewGuid().ToString('N'));$module=Join-Path $fixture 'modules/drivers';[void][IO.Directory]::CreateDirectory($module);[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'core'))
$utf=[Text.UTF8Encoding]::new($true)
Copy-Item -LiteralPath $entry -Destination $module
[IO.File]::WriteAllText((Join-Path $module 'driver_archive_library.ps1'),'# inert definitions', $utf)
$hardware=@'
function Select-SetupDriverRequest {param($DriverPackagePath) [pscustomobject]@{DriverPackagePath=$DriverPackagePath}}
function Test-SetupInteractiveHost {return $false}
function Get-SetupHardwareProfile {[pscustomobject]@{IsNuc8=$true}}
function Get-SetupModuleDecision {[pscustomobject]@{Applicable=$true}}
function Test-SetupDriverPayload {[pscustomobject]@{Status='Passed'}}
'@
[IO.File]::WriteAllText((Join-Path $fixture 'core/hardware.ps1'),$hardware,$utf)
$library=@'
function Invoke-SetupDriverInstallation {throw 'CLI fixture forbids install'}
function Invoke-SetupDriverVerification {param($DriverRoot,$VerificationRunId) @{Root=$DriverRoot;Run=$VerificationRunId;Success=$true}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'called.json') -Encoding UTF8;[pscustomobject]@{Success=$true}}
'@
[IO.File]::WriteAllText((Join-Path $module 'driver_installation_library.ps1'),$library,$utf)
$bundle=Join-Path $fixture '驅動 包';$run=[guid]::NewGuid().ToString()
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $module 'install_drivers.ps1') -VerifyOnly -DriverPackagePath $bundle -VerificationRunId $run -NonInteractive *> (Join-Path $fixture 'entry.log')
Assert ($LASTEXITCODE -eq 0) '真公開CLI子程序唯讀路由成功，不碰安裝或管理員提權'
$called=Get-Content -LiteralPath (Join-Path $module 'called.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert ($called.Root -ceq $bundle -and $called.Run -ceq $run) '公開CLI保留動態中文包路徑與本輪ID'
[IO.File]::WriteAllText((Join-Path $module 'driver_installation_library.ps1'),'function Invoke-SetupDriverVerification {[pscustomobject]@{Success=$false}}', $utf)
$oldPreference=$ErrorActionPreference;$ErrorActionPreference='Continue'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $module 'install_drivers.ps1') -VerifyOnly -DriverPackagePath $bundle -VerificationRunId $run -NonInteractive *> (Join-Path $fixture 'failed_entry.log')
$failedCode=$LASTEXITCODE;$ErrorActionPreference=$oldPreference
Assert ($failedCode -ne 0) '公開CLI未核實結果保留非零退出碼'
Copy-Item -LiteralPath (Join-Path $root 'core/run_module.ps1') -Destination (Join-Path $fixture 'core')
$boundary=@'
function Get-SetupEntryIdentity {return 'fixture-sid'}
function Test-SetupEntryAdministrator {return $true}
function Start-SetupEntryElevated {throw 'CLI fixture forbids elevation'}
'@
[IO.File]::WriteAllText((Join-Path $fixture 'core/entry_os_boundary.ps1'),$boundary,$utf)
$paths=@'
function Resolve-NucPath {throw 'legacy resolver reached'}
function Resolve-SetupPath {return (Join-Path $PSScriptRoot '../modules/drivers/driver_stub.ps1')}
'@
[IO.File]::WriteAllText((Join-Path $fixture 'core/paths.ps1'),$paths,$utf)
[IO.File]::WriteAllText((Join-Path $module 'driver_stub.ps1'),'param([switch]$VerifyOnly,[string]$DriverPackagePath,[switch]$NonInteractive,[string]$ConfirmedBoard,[string]$ConfirmationComputer);@{Verify=[bool]$VerifyOnly;Root=$DriverPackagePath;Quiet=[bool]$NonInteractive}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $PSScriptRoot ''module_called.json'') -Encoding UTF8',$utf)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'core/run_module.ps1') -Module Install-Drivers -VerifyOnly -DriverPackagePath $bundle -NonInteractive *> (Join-Path $fixture 'module.log')
Assert ($LASTEXITCODE -eq 0) '真正run_module只替換原生privilege邊界後可安全驗證driver路由'
$called=Get-Content -LiteralPath (Join-Path $module 'module_called.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert ($called.Verify -and $called.Root -ceq $bundle -and $called.Quiet) 'Install-Drivers VerifyOnly完整傳遞路徑及非互動，不走共用丟參數分支'
