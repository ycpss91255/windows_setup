#Requires -Version 5.1
$ErrorActionPreference='Stop'
$packageRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $packageRoot 'core\hardware.ps1')
$count=0
function Assert([bool]$Condition,[string]$Message){Write-Host ('@@ASSERT@@'+(@{Name=$Message;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw ('FAIL: '+$Message)};$script:count++;Write-Host ('PASS: '+$Message)}
$preflightFixture=& {
 $calls=New-Object 'System.Collections.Generic.List[string]';$state=@{Applicable=$true;Specified=$null;Interactive=$null}
 function Test-SetupInteractiveHost {$null=$calls.Add('interactive');return $true}
 function Select-SetupDriverRequest {param($PackageRoot,$DriverPackagePath,[switch]$PathSpecified,$ConfirmedBoard,$ConfirmationComputer,[bool]$Interactive);$null=$calls.Add('select');$state.Specified=[bool]$PathSpecified;$state.Interactive=$Interactive;[pscustomobject]@{DriverPackagePath=$DriverPackagePath;ConfirmedBoard=$ConfirmedBoard;ConfirmationComputer=$ConfirmationComputer}}
 function Get-SetupHardwareProfile {param($BoardProduct,$DriverPackagePath,$ConfirmedBoard,$ConfirmationComputer);$null=$calls.Add('hardware');[pscustomobject]@{DriverBoard=$ConfirmedBoard;BoardProduct=''}}
 function Get-SetupModuleDecision {param($Module,$Hardware);$null=$calls.Add('decision');[pscustomobject]@{Applicable=$state.Applicable;Reason='fixture'}}
 function Test-SetupDriverPayload {param($Hardware,$DriverPackagePath);$null=$calls.Add('payload');[pscustomobject]@{Status='Passed'}}
 $ready=Get-SetupDriverPreflight -PackageRoot $env:TEMP -DriverPackagePath '' -PathSpecified -NonInteractive -ConfirmedBoard 'NUC8i7HNB' -ConfirmationComputer 'fixture'
 $readyOrder=$calls -join ',';$explicit=$state.Specified;$interactive=$state.Interactive;$calls.Clear()
 $state.Applicable=$false;$skipped=Get-SetupDriverPreflight -PackageRoot $env:TEMP -DriverPackagePath '' -VerifyOnly
 $skipOrder=$calls -join ',';$omitted=$state.Specified;$verifyInteractive=$state.Interactive;$calls.Clear()
 $none=Get-SetupDriverPreflight -PackageRoot $env:TEMP -PackageOnly
 [pscustomobject]@{Ready=$ready;ReadyOrder=$readyOrder;Explicit=$explicit;Interactive=$interactive;Skipped=$skipped;SkipOrder=$skipOrder;Omitted=$omitted;VerifyInteractive=$verifyInteractive;None=$none;NoneCalls=$calls.Count}
}
Assert ($preflightFixture.Ready.Disposition -ceq 'Ready' -and $preflightFixture.ReadyOrder -ceq 'interactive,select,hardware,decision,payload' -and $preflightFixture.Explicit -and -not $preflightFixture.Interactive) '前置函式保留明確空路徑及非互動選擇與驗包順序'
Assert ($preflightFixture.Skipped.Disposition -ceq 'NotApplicable' -and $preflightFixture.SkipOrder -ceq 'interactive,select,hardware,decision' -and -not $preflightFixture.Omitted -and -not $preflightFixture.VerifyInteractive) '未指定路徑和VerifyOnly不互動，非適用時不驗payload'
Assert ($preflightFixture.None.Disposition -ceq 'NoPackage' -and $preflightFixture.NoneCalls -eq 0) 'PackageOnly無包直接略過且不偵測硬體'
$generic=Get-SetupHardwareProfile -BoardProduct 'Other Board' -UICulture 'en-US'
$hv=Get-SetupHardwareProfile -BoardProduct 'NUC8i7HVB' -UICulture 'zh-TW' -DriverPackagePath 'selected_package'
$hn=Get-SetupHardwareProfile -BoardProduct 'NUC8i7HNB' -UICulture 'zh-TW' -DriverPackagePath 'selected_package'
$fixture=Join-Path $env:TEMP ('windows_setup_hardware_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture|Out-Null
Assert ((Test-SetupDriverPayload $generic $fixture).Status -eq 'Skipped') '通用主機在完全無 payload 的目錄通過適用性判斷'
$caught=$false;try{Test-SetupDriverPayload $hv (Join-Path $fixture 'missing')|Out-Null}catch{$caught=$true}
Assert $caught 'NUC 選擇缺少的 payload 仍失敗'
$payload=Join-Path $fixture 'modules\drivers\Payload'
New-Item -ItemType Directory -Path $payload -Force|Out-Null
@{SchemaVersion=1;HardwareProfile='NUC8';Architecture='x64';SupportedBoards=@('NUC8i7HVB','NUC8i7HNB')}|ConvertTo-Json|Set-Content (Join-Path $payload 'package.json') -Encoding UTF8
$manifest=@(1..4|ForEach-Object {$file=('driver'+$_+'.zip');[IO.File]::WriteAllText((Join-Path $payload $file),'fixture');[pscustomobject]@{File=$file;SHA256=(Get-FileHash (Join-Path $payload $file)).Hash}})
$manifest|ConvertTo-Json|Set-Content (Join-Path $payload 'manifest.json') -Encoding UTF8
Assert ((Test-SetupDriverPayload $hn $payload).Count -eq 4) 'NUC 四個獨立檔案雜湊通過'
[IO.File]::WriteAllText((Join-Path $payload 'driver1.zip'),'changed')
$caught=$false;try{Test-SetupDriverPayload $hv $payload|Out-Null}catch{$caught=$true}
Assert $caught 'NUC 雜湊錯誤仍失敗'
@($manifest[1],$manifest[1],$manifest[1],$manifest[1])|ConvertTo-Json|Set-Content (Join-Path $payload 'manifest.json') -Encoding UTF8
$caught=$false;try{Test-SetupDriverPayload $hv $payload|Out-Null}catch{$caught=$true}
Assert $caught '重複四次同一驅動不算完整清單'
# Execute the actual early guards with mocked hardware; remove only the elevation directive.
# Any unexpected mutation is trapped before it can touch the host.
foreach($relative in @('modules\drivers\install_drivers.ps1','modules\amd\apply_amd_privacy_settings.ps1')){
 $target=Join-Path $packageRoot $relative
 $runner=Join-Path $fixture ([IO.Path]::GetFileName($relative))
 $code=[IO.File]::ReadAllText($target) -replace '(?m)^#Requires -RunAsAdministrator\r?\n',''
 $code=$code.Replace('$PSScriptRoot',("'"+(Split-Path $target -Parent).Replace("'","''")+"'"))
 [IO.File]::WriteAllText($runner,$code,(New-Object Text.UTF8Encoding($true)))
 $out=& {
  function Get-CimInstance { [pscustomobject]@{Product='Generic Fixture'} }
  function New-Item {throw 'Unexpected host write'}
  function New-ItemProperty {throw 'Unexpected registry write'}
  function Get-PnpDevice {throw 'Unexpected driver scan'}
  & $runner
 }
 Assert (@($out|Where-Object Status -eq 'Skipped').Count -eq 1) ('獨立入口安全略過且不寫主機：'+$relative)
}
# Build a source-only package with no driver payload; Autologon is only an existence fixture.
$genericPackage=Join-Path $fixture 'generic_package'
New-Item -ItemType Directory -Path $genericPackage|Out-Null
foreach($dir in @('core','modules','drivers')){
 foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $packageRoot $dir) -Recurse -File|Where-Object {$_.FullName -notmatch '[\\/]Payload[\\/]|[\\/]Reports[\\/]' -and $_.Extension -notin @('.exe','.zip','.log')})){
  $relative=$file.FullName.Substring($packageRoot.Length).TrimStart('\')
  $destination=Join-Path $genericPackage $relative
  New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force|Out-Null
  Copy-Item -LiteralPath $file.FullName -Destination $destination
 }
}
foreach($entry in @('init.cmd','windows.cmd','readme.md')){Copy-Item -LiteralPath (Join-Path $packageRoot $entry) -Destination $genericPackage}
[IO.File]::WriteAllText((Join-Path $genericPackage 'modules\accounts\Autologon64.exe'),'existence fixture, never executed')
& (Join-Path $genericPackage 'core\test_setup_prerequisites.ps1') -PackageOnly -HardwareProfile Generic
# PackageOnly must remain a source check on Server: never query/install native provisioning.
function Get-ProvisioningPackage {throw 'PackageOnly must not invoke client provisioning APIs'}
function Install-ProvisioningPackage {throw 'PackageOnly must not install provisioning assets'}
foreach($relative in @('core/verification_library.ps1','modules/ssh/hosts_sync_library.ps1','modules/init/provisioning_library.ps1','modules/init/provisioning_asset_library.ps1','modules/init/provisioning_launcher_library.ps1','modules/init/assets/hide_oobe.ppkg','modules/init/assets/hide_oobe.xml','modules/init/assets/provenance.json')){
 $path=Join-Path $genericPackage $relative;$backup=$path+'.fixture-backup'
 [IO.File]::Move($path,$backup)
 $rejected=$false
 try{& (Join-Path $genericPackage 'core/test_setup_prerequisites.ps1') -PackageOnly -HardwareProfile Generic}catch{$rejected=$true}finally{[IO.File]::Move($backup,$path)}
 Assert $rejected ('PackageOnly 拒絕遺失 Init runtime 相依：'+$relative)
}
foreach($mutation in @('package','source','manifest','source_with_updated_hash')){
 $assets=Join-Path $genericPackage 'modules/init/assets';$packageFile=Join-Path $assets 'hide_oobe.ppkg';$sourceFile=Join-Path $assets 'hide_oobe.xml';$manifestFile=Join-Path $assets 'provenance.json'
 $originalPackage=[IO.File]::ReadAllBytes($packageFile);$originalSource=[IO.File]::ReadAllBytes($sourceFile);$originalManifest=[IO.File]::ReadAllBytes($manifestFile)
 $rejected=$false
 try{
  switch($mutation){
   package{[IO.File]::AppendAllText($packageFile,'corrupt')}
   source{[IO.File]::AppendAllText($sourceFile,'corrupt')}
   manifest{$data=Get-Content $manifestFile -Raw|ConvertFrom-Json;$data.SourceSHA256='0'*64;[IO.File]::WriteAllText($manifestFile,($data|ConvertTo-Json))}
   source_with_updated_hash{$text=[IO.File]::ReadAllText($sourceFile).Replace('>True<','>False<');[IO.File]::WriteAllText($sourceFile,$text);$data=Get-Content $manifestFile -Raw|ConvertFrom-Json;$data.SourceSHA256=(Get-FileHash $sourceFile).Hash;[IO.File]::WriteAllText($manifestFile,($data|ConvertTo-Json))}
  }
  & (Join-Path $genericPackage 'core/test_setup_prerequisites.ps1') -PackageOnly -HardwareProfile Generic
 }catch{$rejected=$true}finally{[IO.File]::WriteAllBytes($packageFile,$originalPackage);[IO.File]::WriteAllBytes($sourceFile,$originalSource);[IO.File]::WriteAllBytes($manifestFile,$originalManifest)}
 Assert $rejected ('PackageOnly 拒絕 Init 資產竄改：'+$mutation)
}
& (Join-Path $genericPackage 'core/test_setup_prerequisites.ps1') -PackageOnly -HardwareProfile Generic
Assert $true 'PackageOnly 完整 Init source 驗證不依賴 Windows client API'
$verificationHelper=Join-Path $genericPackage 'core\verification.ps1'
Move-Item -LiteralPath $verificationHelper -Destination ($verificationHelper+'.fixture-backup')
$missingHelperRejected=$false
try{& (Join-Path $genericPackage 'core\test_setup_prerequisites.ps1') -PackageOnly -HardwareProfile Generic}catch{$missingHelperRejected=$_.Exception.Message -match 'verification.ps1'}finally{Move-Item -LiteralPath ($verificationHelper+'.fixture-backup') -Destination $verificationHelper}
Assert $missingHelperRejected '缺少 Verification helper 的套件不得通過 PackageOnly'
$entryBoundary=Join-Path $genericPackage 'core\entry_os_boundary.ps1'
[IO.File]::Move($entryBoundary,($entryBoundary+'.fixture-backup'))
$missingBoundaryRejected=$false
try{& (Join-Path $genericPackage 'core\test_setup_prerequisites.ps1') -PackageOnly -HardwareProfile Generic}catch{$missingBoundaryRejected=$_.Exception.Message -match 'entry_os_boundary.ps1'}finally{[IO.File]::Move(($entryBoundary+'.fixture-backup'),$entryBoundary)}
Assert $missingBoundaryRejected 'PackageOnly rejects missing entry OS boundary'
Assert (-not(Test-Path (Join-Path $genericPackage 'modules\drivers\Payload'))) '通用 PackageOnly 完整檢查成功且未建立或要求 NUC payload'
$caught=$false;try{& (Join-Path $genericPackage 'core\test_setup_prerequisites.ps1') -PackageOnly -HardwareProfile NUC8 -DriverPackagePath (Join-Path $fixture 'missing')}catch{$caught=$true}
Assert $caught '相同無驅動包指定 NUC8 仍拒絕'
$selectionFile=Join-Path $fixture 'selection.json'
@{Computer='machine_a';UserSID='sid_a';HardwareProfile=@{DriverPackagePath=$payload}}|ConvertTo-Json -Depth 4|Set-Content $selectionFile -Encoding UTF8
Assert ((Get-SetupSavedDriverSelection $selectionFile 'machine_a' 'sid_a') -eq $payload) '相同電腦與使用者續用明確選擇'
Assert ((Get-SetupSavedDriverSelection $selectionFile 'machine_b' 'sid_a') -eq '') '其他電腦不沿用驅動包'
Assert ((Get-SetupSavedDriverSelection $selectionFile 'machine_a' 'sid_b') -eq '') '其他帳號不沿用驅動包'
# Restore small fixture files, then export a standalone package and validate it from another directory.
[IO.File]::WriteAllText((Join-Path $payload 'driver1.zip'),'fixture')
$manifest|ConvertTo-Json|Set-Content (Join-Path $payload 'manifest.json') -Encoding UTF8
$exported=Join-Path $fixture '獨立 驅動包'
Push-Location $fixture
# GitHub runner TEMP may use RUNNER~1 while the provider resolves runneradmin.
# Derive the expected directory from the actual PowerShell location, not its 8.3 alias.
$expectedProviderOutput=Join-Path (Get-Location).ProviderPath '獨立 驅動包'
Assert ((Get-Location).ProviderPath -ine [Environment]::CurrentDirectory) '回歸測試確保 PowerShell 位置與 NET cwd 不同'
Write-Host ('Export diagnostic: ProviderLocation=['+(Get-Location).ProviderPath+']; NETcwd=['+[Environment]::CurrentDirectory+']; TEMP=['+$env:TEMP+']')
try{$exportResult=& (Join-Path $packageRoot 'script\package\export_driver_package.ps1') -SourceDirectory $payload -OutputDirectory '.\獨立 驅動包'}finally{Pop-Location}
Write-Host ('Export diagnostic: Actual=['+$exportResult.OutputDirectory+']; ExpectedProvider=['+$expectedProviderOutput+']; FixtureAlias=['+$exported+']; ActualExists=['+(Test-Path -LiteralPath $exportResult.OutputDirectory)+']; ExpectedExists=['+(Test-Path -LiteralPath $exported)+']')
Assert ($exportResult.OutputDirectory -eq $expectedProviderOutput -and (Test-Path -LiteralPath $expectedProviderOutput -PathType Container) -and (Test-Path -LiteralPath $exported -PathType Container)) '獨立包相對輸出依 PowerShell 位置解析'
Assert ($exportResult.Count -eq 4 -and (Test-Path (Join-Path $exported 'install.cmd'))) '導出獨立驅動包與可攜入口'
$standalone=& (Join-Path $exported 'modules\drivers\install_drivers.ps1') -DriverPackagePath $exported -PackageOnly
Assert ($standalone.Status -eq 'Passed') '獨立包只用自身 helper 完成唯讀驗證'
Assert (-not(Test-Path (Join-Path $exported 'script')) -and -not(Test-Path (Join-Path $exported 'test')) -and -not(Test-Path (Join-Path $exported '.github'))) '獨立包不攜帶維護工具且已獨立執行驗證'
$installer=Join-Path $exported 'modules/drivers/install_drivers.ps1'
$skipWithoutDetection=& {function Get-CimInstance {throw 'PackageOnly must not detect hardware'};& $installer -PackageOnly}
Assert ($skipWithoutDetection.Status -ceq 'Skipped') '匯出安裝入口無包PackageOnly直接略過且不偵測'
foreach($case in @('manual','verify')){
 $guard='';try{if($case -eq 'manual'){& $installer -PackageOnly -ConfirmedBoard 'NUC8i7HNB'|Out-Null}else{& $installer -PackageOnly -VerifyOnly|Out-Null}}catch{$guard=$_.Exception.Message}
 Assert (($case -eq 'manual' -and $guard -match '不可混用手動') -or ($case -eq 'verify' -and $guard -match '不可混用')) ('匯出入口先拒絕PackageOnly互斥參數 '+$case)
}
$badPackage=Join-Path $fixture 'untrusted-profile';New-Item -ItemType Directory -Path $badPackage|Out-Null
@{SchemaVersion=2;ProfileId='unknown_fixture'}|ConvertTo-Json|Set-Content (Join-Path $badPackage 'package.json') -Encoding UTF8
$badProfileError=& {function Get-CimInstance {throw 'unexpected CIM'};try{& $installer -PackageOnly -DriverPackagePath $badPackage|Out-Null;return ''}catch{return $_.Exception.Message}}
Assert ($badProfileError -match '不在可信設定檔清單') '未知機型在任何硬體偵測之前遭拒絕'
# Exercise the same named preflight used by the exported installer.
. (Join-Path $exported 'core/hardware.ps1')
function Get-CimInstance {param($ClassName,$ErrorAction);[pscustomobject]@{Product=''}}
$preflight=Get-SetupDriverPreflight -PackageRoot $exported -DriverPackagePath $exported -PathSpecified -NonInteractive -ConfirmedBoard 'NUC8i7HNB' -ConfirmationComputer $env:COMPUTERNAME
Assert ($preflight.Disposition -ceq 'Ready' -and $preflight.Hardware.DriverBoard -eq 'NUC8i7HNB' -and $preflight.Hardware.BoardProduct -eq '' -and $preflight.Payload.Status -eq 'Passed') '匯出包具名前置函式可獨立選型並驗包，不呼叫安裝或UAC'
$wrongConfirmation='';try{Get-SetupDriverPreflight -PackageRoot $exported -DriverPackagePath $exported -PathSpecified -NonInteractive -ConfirmedBoard 'NUC8i7HNB' -ConfirmationComputer 'other-machine-fixture'|Out-Null}catch{$wrongConfirmation=$_.Exception.Message}
Assert ($wrongConfirmation -match '不屬於目前電腦') '未知硬體的跨電腦手動確認被拒絕'
$tokens=$null;$errors=$null;$installerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $exported 'modules/drivers/install_drivers.ps1'),[ref]$tokens,[ref]$errors)
$preflightCalls=@($installerAst.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Get-SetupDriverPreflight'},$true))
Assert ($errors.Count -eq 0 -and $preflightCalls.Count -eq 1) '匯出包真安裝入口呼叫同一具名前置函式'
$principalAssignments=@($installerAst.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq 'principal'},$true))
$verifyBranches=@($installerAst.FindAll({param($node) if($node -isnot [Management.Automation.Language.IfStatementAst]){return $false};$vars=@($node.Clauses[0].Item1.FindAll({param($inner) $inner -is [Management.Automation.Language.VariableExpressionAst] -and $inner.VariablePath.UserPath -ceq 'VerifyOnly'},$true));return $vars.Count -gt 0},$true)|Where-Object {$_.Extent.StartOffset -gt $preflightCalls[0].Extent.StartOffset -and $principalAssignments.Count -eq 1 -and $_.Extent.StartOffset -lt $principalAssignments[0].Extent.StartOffset})
Assert ($principalAssignments.Count -eq 1 -and $verifyBranches.Count -eq 1 -and @($verifyBranches[0].FindAll({param($node) $node -is [Management.Automation.Language.ReturnStatementAst]},$true)).Count -gt 0) 'VerifyOnly在前置檢查後且UAC之前返回'
Remove-Item Function:Get-CimInstance
@{SchemaVersion=1;HardwareProfile='Other';Architecture='x64';SupportedBoards=@('Other')}|ConvertTo-Json|Set-Content (Join-Path $exported 'package.json') -Encoding UTF8
$caught=$false;try{Test-SetupDriverPayload $hv $exported|Out-Null}catch{$caught=$true}
Assert $caught '其他型號的獨立包被拒絕'
Write-Host ('ALL PASS: '+$count+' hardware assertions; temporary fixtures only, no Windows settings changed.')
