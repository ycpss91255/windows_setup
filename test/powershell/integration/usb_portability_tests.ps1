#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'core/hardware.ps1')
. (Join-Path $root 'modules/init/oobe_library.ps1')
function Assert([bool]$Condition,[string]$Message){Write-Host ('@@ASSERT@@'+(@{Name=$Message;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Message}}
function Refuse([scriptblock]$Action,[string]$Message){$caught=$false;try{& $Action|Out-Null}catch{$caught=$true};Assert $caught $Message}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('windows_usb_'+[guid]::NewGuid().ToString('N'))
$old=Join-Path $fixture "old_media\工具 ' 中文"
$new=Join-Path $fixture "new_media\工具 ' 中文"
$pack=Join-Path $old 'windows_setup'
$driver=Join-Path $old 'windows_driver_packages\nuc8'
New-Item -ItemType Directory $pack,$driver -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $driver 'package.json'),'{"SchemaVersion":1}')
[IO.File]::WriteAllText((Join-Path $driver 'manifest.json'),'[]')
$selection=New-SetupDriverSelection -PackageRoot $pack -DriverPackagePath $driver
Assert ($selection.RelativePath -eq '..\windows_driver_packages\nuc8') '同媒體主包與驅動包保存相對位置而非固定磁碟代號'
$result=Join-Path $pack 'result.json'
@{Computer='fixture_machine';UserSID='fixture_user_a';HardwareProfile=@{DriverPackagePath=$driver;DriverSelection=$selection}}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $result -Encoding UTF8
New-Item -ItemType Directory (Split-Path $new) -Force|Out-Null
Move-Item -LiteralPath $old -Destination $new
$newPack=Join-Path $new 'windows_setup';$newDriver=Join-Path $new 'windows_driver_packages\nuc8';$newResult=Join-Path $newPack 'result.json'
$actual=Get-SetupSavedDriverSelection -ResultPath $newResult -Computer fixture_machine -UserSID fixture_user_a -PackageRoot $newPack
Assert ($actual -eq $newDriver -and -not(Test-Path -LiteralPath $driver)) '媒體根路徑移動且舊路徑不存在仍恢復原驅動包'
Assert ((Get-SetupSavedDriverSelection $newResult other_machine fixture_user_a $newPack) -eq '') '其他電腦不沿用舊選擇'
Assert ((Get-SetupSavedDriverSelection $newResult fixture_machine fixture_user_b $newPack) -eq '') '另一使用者不沿用舊選擇'
[IO.File]::WriteAllText((Join-Path $newDriver 'manifest.json'),'["changed"]')
Refuse {Get-SetupSavedDriverSelection $newResult fixture_machine fixture_user_a $newPack} '相對位置相同但驅動身分改變即拒絕'
[IO.File]::WriteAllText((Join-Path $newDriver 'manifest.json'),'[]')
$legacy=Join-Path $fixture 'legacy.json'
@{Computer='fixture_machine';UserSID='fixture_user_a';HardwareProfile=@{DriverPackagePath=$driver}}|ConvertTo-Json -Depth 4|Set-Content $legacy -Encoding UTF8
Refuse {Get-SetupSavedDriverSelection $legacy fixture_machine fixture_user_a $newPack} '舊紀錄失效絕對位置不可猜盤符恢復'
$selection.RelativePath='';$selection.AbsolutePath=$newDriver
@{Computer='fixture_machine';UserSID='fixture_user_a';HardwareProfile=@{DriverPackagePath=$newDriver;DriverSelection=$selection}}|ConvertTo-Json -Depth 8|Set-Content $newResult -Encoding UTF8
Assert ((Get-SetupSavedDriverSelection $newResult fixture_machine fixture_user_a $newPack) -eq $newDriver) '外部獨立媒體固定位置仍核對包身分'
$selection.RelativePath='Z:\unknown'
@{Computer='fixture_machine';UserSID='fixture_user_a';HardwareProfile=@{DriverPackagePath=$newDriver;DriverSelection=$selection}}|ConvertTo-Json -Depth 8|Set-Content $newResult -Encoding UTF8
Refuse {Get-SetupSavedDriverSelection $newResult fixture_machine fixture_user_a $newPack} '相對紀錄不得夾帶磁碟代號'
# Exercise the actual named Init source with read-only/mocked platform context.
. (Join-Path $root 'modules/init/init_entry_library.ps1')
$source=[IO.File]::ReadAllText((Join-Path $root 'modules/init/init_entry_library.ps1'))
function Invoke-InitProvisioningEntry {return $false}
function Get-SetupInitContext {[pscustomobject]@{Sid='fixture_user_b';UserSID='fixture_user_b';IsAdministrator=$false;ImageState='IMAGE_STATE_COMPLETE';DesktopOwned=$true}}
function Start-Process {param($FilePath,$Verb,$ArgumentList);$script:elevation=$ArgumentList}
$fakeEntry=Join-Path $newPack "init ' 測試.ps1"
[IO.File]::WriteAllText($fakeEntry,'param($ExpectedUserSID,$SshScriptPath);[pscustomobject]@{SID=$ExpectedUserSID;SSH=$SshScriptPath}',[Text.UTF8Encoding]::new($true))
$SshScriptPath=Join-Path $newPack "ssh ' 中文.ps1"
Invoke-SetupInit -EntryPath $fakeEntry -ModuleRoot (Join-Path $root 'modules/init') -SshScriptPath $SshScriptPath
$decoded=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($script:elevation -split '-EncodedCommand ')[1]))
$invoked=& ([scriptblock]::Create($decoded))
Assert ($invoked.SID -eq 'fixture_user_b' -and $invoked.SSH -eq $SshScriptPath) '提權命令保留動態使用者與中文空白單引號路徑'
Refuse {Invoke-SetupInit -EntryPath $fakeEntry -ModuleRoot (Join-Path $root 'modules/init') -ExpectedUserSID original_user} 'Init原始函式拒絕提權換帳號'
# First-logon command must be independent of the removable package.
$stage=Join-Path $fixture 'local_program_data\NUC-Init'
$cleanup='powershell.exe -File "'+(Join-Path $stage 'cleanup_oobe.ps1')+'"'
[xml]$xml=New-InitAnswerXml -UserName 'different_user' -Password 'fixture_password' -CleanupCommand $cleanup -Marker ('NUC-INIT-'+('a'*32))
Assert ($xml.OuterXml.Contains('local_program_data') -and -not $xml.OuterXml.Contains('old_media')) '首次登入清理指令使用本機暫存而非可移除媒體'
Assert ($source.Contains("`$stage=Join-Path `$env:ProgramData 'NUC-Init'") -and $source.Contains("@('oobe_library.ps1','cleanup_oobe.ps1')")) 'Init 實作將清理依賴及密碼暫存放本機 ProgramData'
$otherRoot='\\fixture.invalid\share\package'
$external=New-SetupDriverSelection -PackageRoot $otherRoot -DriverPackagePath $newDriver
Assert (-not $external.RelativePath -and $external.AbsolutePath -eq $newDriver) '跨磁碟不產生假的相對路徑或掃描其他媒體'
foreach($entry in @('core/configure_setup.ps1','core/verify_only.ps1','core/verify_after_restart.ps1')){
 $text=[IO.File]::ReadAllText((Join-Path $root $entry))
 $guard=($text -split "`r?`n"|Where-Object {$_ -match '^if\(\$ExpectedUserSID -and'})
 $ExpectedUserSID='original_user';$sid='different_user';$currentSID='different_user'
 Refuse { . ([scriptblock]::Create($guard)) } ('提權換帳號立即拒絕：'+$entry)
}
