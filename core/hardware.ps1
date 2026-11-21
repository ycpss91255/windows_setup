#Requires -Version 5.1
function Test-SetupAdministrator {
 return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-SetupDriverProfile {
 param([string]$BoardProduct,[string]$ProfileId='', [string]$ProfilesRoot='')
 if(-not $ProfilesRoot){$ProfilesRoot=Join-Path $PSScriptRoot '../drivers'}
 if(-not(Test-Path -LiteralPath $ProfilesRoot -PathType Container)){return $null}
 $profiles=@(Get-ChildItem -LiteralPath $ProfilesRoot -Directory|ForEach-Object {
  $file=Join-Path $_.FullName 'profile.json'
  if(Test-Path -LiteralPath $file -PathType Leaf){
   $p=Get-Content -LiteralPath $file -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
   if($p.SchemaVersion -ne 1 -or $p.ProfileId -cnotmatch '^[a-z0-9][a-z0-9_]{0,63}$' -or $p.ProfileId -cne $_.Name -or $p.PackageDirectory -cnotmatch '^[a-z0-9][a-z0-9_]{0,63}$' -or $p.Architecture -cne 'x64' -or @($p.SupportedBoards).Count -lt 1 -or @($p.SupportedBoards|Select-Object -Unique).Count -ne @($p.SupportedBoards).Count){throw '驅動設定檔識別、目錄、架構或板號無效。'}
   foreach($board in $p.SupportedBoards){if(-not $board -or $board -ne $board.Trim() -or $board -match '[\\/\r\n]'){throw '驅動設定檔板號無效。'}}
   $p|Add-Member NoteProperty ProfileSHA256 ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash) -Force
   $p|Add-Member NoteProperty ProfilePath $file -Force
   $p
  }
 })
 $allBoards=@{}
 foreach($p in $profiles){foreach($board in $p.SupportedBoards){if($allBoards.ContainsKey($board)){throw '多個驅動設定檔宣告相同板號，拒絕選型。'};$allBoards[$board]=$true}}
 $matches=@($profiles|Where-Object {if($ProfileId){$_.ProfileId -ceq $ProfileId}else{$BoardProduct.Trim() -in $_.SupportedBoards}})
 if($matches.Count -gt 1){throw '驅動設定檔識別重複。'}
 if($matches.Count -eq 1){return $matches[0]}
 return $null
}
function Get-SetupHardwareProfile {
 param([string]$BoardProduct,[string]$UICulture=(Get-UICulture).Name,[string]$DriverPackagePath='',
  [ValidateSet('','NUC8i7HVB','NUC8i7HNB')][string]$ConfirmedBoard='', [string]$ConfirmationComputer='', [string]$ProfilesRoot='')
 $detectionError='';$ambiguous=$false
 if(-not $PSBoundParameters.ContainsKey('BoardProduct')){
  try{
   $boards=@(Get-CimInstance Win32_BaseBoard -ErrorAction Stop)
   if($boards.Count -eq 1){$BoardProduct=[string]$boards[0].Product}
   elseif($boards.Count -gt 1){$BoardProduct=(@($boards|ForEach-Object {[string]$_.Product}) -join ' | ');$ambiguous=$true;$detectionError='回傳多塊主機板，無法安全選型。'}
   else{$BoardProduct='';$detectionError='未回傳主機板。'}
  }catch{$BoardProduct='';$detectionError=$_.Exception.Message}
 }
 $value=$BoardProduct.Trim()
 $detected=$value -in @('NUC8i7HVB','NUC8i7HNB')
 $unknown=(-not $value -or $value -in @('Unknown','To be filled by O.E.M.','Default string','Not specified')) -and -not $ambiguous
 $status=if($unknown){'Unknown'}elseif($ambiguous){'Ambiguous'}else{'Detected'}
 if($ConfirmedBoard){
  if(-not $ConfirmationComputer -or $ConfirmationComputer -ine $env:COMPUTERNAME){throw '手動驅動型號確認不屬於目前電腦。'}
  if(-not $unknown -and (-not $detected -or $value -ine $ConfirmedBoard)){throw '目前偵測硬體與手動確認不符，拒絕 NUC 驅動。'}
 }
 $profileBoard=if($ConfirmedBoard){$ConfirmedBoard}else{$value}
 $profile=Get-SetupDriverProfile -BoardProduct $profileBoard -ProfilesRoot $ProfilesRoot
 $driverBoard=if($profile){$profileBoard}else{''}
 [pscustomobject]@{Name=$(if($profile){$profile.ProfileId}else{'Generic'});DriverProfileId=$(if($profile){$profile.ProfileId}else{''});DriverProfileData=$profile;BoardProduct=$BoardProduct;DriverBoard=$driverBoard;IsNuc8=($driverBoard -in @('NUC8i7HVB','NUC8i7HNB'));IsDetectedNuc8=$detected;DetectionStatus=$status;DetectionError=$detectionError;ConfirmedBoard=$ConfirmedBoard;ConfirmationComputer=$ConfirmationComputer;UICulture=$UICulture;DriverPackagePath=$DriverPackagePath}
}
function Get-SetupModuleDecision {
 param([Parameter(Mandatory=$true)][string]$Module,[Parameter(Mandatory=$true)]$Hardware)
 $hasProfile=([bool]$Hardware.DriverProfileId -or $Hardware.IsNuc8)
 $skip=($Module -eq 'install_drivers.ps1' -and -not $hasProfile) -or ($Module -eq 'apply_amd_privacy_settings.ps1' -and -not $Hardware.IsNuc8)
 if($Module -eq 'apply_amd_privacy_settings.ps1' -and $Hardware.ConfirmedBoard -and -not $Hardware.IsDetectedNuc8){$skip=$true}
 $reason='非 NUC8i7HV/HN：略過 NUC 專屬驅動／AMD 設定'
 if($Module -eq 'install_drivers.ps1' -and $hasProfile -and -not $Hardware.DriverPackagePath){$skip=$true;$reason='未選擇獨立驅動包，略過驅動安裝'}
 if($Module -eq 'desktop_icon_layout.ps1' -and $Hardware.UICulture -ne 'zh-TW'){$skip=$true;$reason='目前排列範本使用繁體中文圖示名稱，略過其他語系的座標套用'}
 [pscustomobject]@{Module=$Module;Applicable=(-not $skip);Status=$(if($skip){'Skipped'}else{'Applicable'});Reason=$(if($skip){$reason}else{'適用目前硬體設定檔'})}
}
function Get-SetupDriverManifestEntries {
 param([Parameter(Mandatory=$true)]$Manifest)
 if($Manifest.SchemaVersion -eq 2){
  $entries=@($Manifest.Packages)
  if($entries.Count -lt 1 -or $entries.Count -gt 128 -or @($entries.Id|Select-Object -Unique).Count -ne $entries.Count){throw '版本2驅動清單數量或識別重複。'}
  foreach($entry in $entries){
   $uri=$null
   if(-not [Uri]::TryCreate([string]$entry.SourceUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Host -notin @('www.intel.com','downloadmirror.intel.com','www.asus.com','dlcdnets.asus.com','www.amd.com')){throw '驅動來源必須是已允許的官方 HTTPS 主機。'}
   if($entry.Id -notmatch '^[a-z0-9][a-z0-9_]{0,63}$' -or $entry.PackageVersion -notmatch '^\d+(\.\d+){1,3}$'){throw '驅動套件識別或版本不合法。'}
   $drivers=@($entry.Drivers)
   if($drivers.Count -lt 1 -or @($drivers.InfPath|Select-Object -Unique).Count -ne $drivers.Count){throw '驅動需要不重複的 INF 清單。'}
   foreach($driver in $drivers){
    if($driver.DriverVersion -notmatch '^\d+(\.\d+){3}$' -or -not $driver.Provider -or $driver.Architecture -ne 'amd64' -or $driver.MinimumBuild -lt 10240 -or $driver.MinimumBuild -gt 99999){throw '驅動版本、架構或最低作業系統規格不合法。'}
    if(@($driver.HardwareIds).Count -lt 1){throw '驅動需要明確硬體 ID。'}
    foreach($id in $driver.HardwareIds){if($id -notmatch '^(?:(PCI|ACPI|HDAUDIO|USB)\\[A-Z0-9_&]+|SWC\\[A-Z0-9_&.-]+|ROOT\\AMDLOG)$'){throw '驅動硬體 ID 不合法。'}}
    $inf=[string]$driver.InfPath
    if($inf -notmatch '^[a-zA-Z0-9_ .()/-]+\.inf$' -or $inf -match '(^|/)\.\.(/|$)' -or [IO.Path]::IsPathRooted($inf)){throw '驅動 INF 路徑必須是安全相對路徑。'}
   }
   $named=@($drivers|Where-Object Id)
   if(@($named.Id|Select-Object -Unique).Count -ne $named.Count){throw '驅動目標識別重複。'}
   foreach($child in @($drivers|Where-Object ParentTarget)){
    $parent=@($drivers|Where-Object {$_.Id -and $_.Id -ceq $child.ParentTarget})
    if(-not $child.Id -or $child.Id -ceq $child.ParentTarget -or $parent.Count -ne 1 -or $parent[0].ParentTarget -or $child.PreStage -ne $true -or @($child.HardwareIds|Where-Object {$_ -notmatch '^SWC\\'}).Count){throw '驅動依賴需唯一父目標、單層無循環且明確預先加入 SWC。'}
   }
   if($entry.ScopeTarget -and @($drivers|Where-Object {$_.Id -ceq $entry.ScopeTarget}).Count -ne 1){throw '套件範圍目標不存在。'}
   foreach($scoped in @($drivers|Where-Object ScopeParentTarget)){
    if($scoped.Id -ceq $scoped.ScopeParentTarget -or @($drivers|Where-Object {$_.Id -ceq $scoped.ScopeParentTarget -and -not $_.ScopeParentTarget}).Count -ne 1){throw '驅動範圍父目標不存在或循環。'}
   }
   $extensions=@($entry.Extensions)
   if(@($extensions|Where-Object {$null -ne $_}).Count){
    if(@($extensions.Id|Select-Object -Unique).Count -ne $extensions.Count){throw 'Extension 識別重複。'}
    foreach($extension in $extensions){
     $guid=[guid]::Empty
     if($extension.Kind -cne 'Extension' -or -not $extension.Id -or $extension.Id -in $named.Id -or @($drivers|Where-Object {$_.Id -ceq $extension.ParentTarget}).Count -ne 1 -or -not [guid]::TryParse([string]$extension.ExtensionId,[ref]$guid) -or $guid -eq [guid]::Empty -or $extension.ActiveAssociationRequired -ne $true){throw 'Extension 身分或父目標無效。'}
     if($extension.DriverVersion -notmatch '^\d+(\.\d+){3}$' -or -not $extension.Provider -or $extension.Architecture -cne 'amd64' -or $extension.MinimumBuild -lt 10240 -or $extension.MinimumBuild -gt 99999 -or @($extension.HardwareIds).Count -lt 1){throw 'Extension 裝置規格無效。'}
     foreach($id in $extension.HardwareIds){if($id -notmatch '^(PCI|ACPI|HDAUDIO|USB)\\[A-Z0-9_&]+$'){throw 'Extension 硬體 ID 無效。'}}
     foreach($kind in @('Inf','Catalog')){
      $relative=[string]$extension.($kind+'Path');$suffix=if($kind -eq 'Inf'){'inf'}else{'cat'}
      if($relative -notmatch ('^[a-zA-Z0-9_ .()/-]+\.'+$suffix+'$') -or $relative -match '(^|/)\.\.(/|$)' -or [IO.Path]::IsPathRooted($relative) -or $extension.($kind+'SHA256') -notmatch '^[a-fA-F0-9]{64}$'){throw 'Extension 路徑或雜湊無效。'}
     }
    }
   }
  }
 }else{
  if($Manifest.PSObject.Properties['SchemaVersion']){throw '不支援的驅動清單版本。'}
  $entries=@($Manifest)
  if($entries.Count -ne 4){throw '舊版 NUC 驅動清單必須包含四個封存檔。'}
 }
 if(@($entries.File|Select-Object -Unique).Count -ne $entries.Count){throw '驅動清單含重複封存檔。'}
 foreach($entry in $entries){if($entry.File -notmatch '^[^\\/:]+\.zip$' -or $entry.File -match '^\.\.' -or $entry.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'NUC 驅動清單格式不合法。'}}
 return $entries
}
function Test-SetupDriverPayload {
 param([Parameter(Mandatory=$true)]$Hardware,[string]$DriverPackagePath,[switch]$AllowLegacyManifest)
 if(-not $Hardware.DriverProfileId -and -not $Hardware.IsNuc8){return [pscustomobject]@{Status='Skipped';Count=0;Reason='目前硬體沒有驅動設定檔'}}
 if(-not $DriverPackagePath){return [pscustomobject]@{Status='Skipped';Count=0;Reason='未選擇獨立驅動包'}}
 $driverRoot=$DriverPackagePath
 if(-not $AllowLegacyManifest){
  $identity=Get-Content -LiteralPath (Join-Path $driverRoot 'package.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
  if($identity.SchemaVersion -eq 2){
   $profile=$Hardware.DriverProfileData
   if(-not $profile -or $identity.ProfileId -cne $Hardware.DriverProfileId -or $identity.Architecture -cne $profile.Architecture -or $identity.ProfileSHA256 -notmatch '^[A-Fa-f0-9]{64}$' -or $identity.ProfileSHA256 -ne $profile.ProfileSHA256 -or @($identity.SupportedBoards).Count -ne @($profile.SupportedBoards).Count -or @($identity.SupportedBoards|Select-Object -Unique).Count -ne @($profile.SupportedBoards).Count -or @($identity.SupportedBoards|Where-Object {$_ -notin $profile.SupportedBoards}).Count -or $Hardware.DriverBoard -notin $profile.SupportedBoards){throw '驅動包設定檔與目前硬體識別不符。'}
   $included=Join-Path $driverRoot ('drivers/'+$profile.ProfileId+'/profile.json')
   if((Get-FileHash -LiteralPath $included -Algorithm SHA256 -ErrorAction Stop).Hash -ne $profile.ProfileSHA256){throw '驅動包內設定檔原始雜湊不符。'}
  }elseif($identity.SchemaVersion -ne 1 -or -not $Hardware.IsNuc8 -or $identity.HardwareProfile -ne 'NUC8' -or $identity.Architecture -ne 'x64' -or @($identity.SupportedBoards).Count -ne 2 -or 'NUC8i7HVB' -notin $identity.SupportedBoards -or 'NUC8i7HNB' -notin $identity.SupportedBoards -or $Hardware.DriverBoard -notin $identity.SupportedBoards){throw '驅動包機型或架構識別不符合目前硬體。'}
 }
 $manifest=Get-Content -LiteralPath (Join-Path $driverRoot 'manifest.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
  $manifest=@(Get-SetupDriverManifestEntries -Manifest $manifest)
 $validationIndex=0
 foreach($entry in $manifest){
  $validationIndex++
  if($entry.File -notmatch '^[^\\/:]+\.zip$' -or $entry.File -match '^\.\.' -or $entry.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'NUC 驅動清單格式不合法。'}
  $path=Join-Path $driverRoot $entry.File
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ('缺少驅動：'+$entry.File)}
  Write-Host ('[驅動包驗證 '+$validationIndex+'/'+$manifest.Count+'] 正在計算 SHA256：'+$entry.File+'；大型檔案可能需要較久，請稍候。') -ForegroundColor Cyan
  $hashStarted=[Diagnostics.Stopwatch]::StartNew()
  try{$actualHash=Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop}catch{throw ('驅動包讀取失敗：'+$entry.File+'；'+$_.Exception.Message)}
  if($actualHash.Hash -ne $entry.SHA256){throw ('驅動 SHA256 不符：'+$entry.File)}
  $hashStarted.Stop()
  Write-Host ('[驅動包驗證 '+$validationIndex+'/'+$manifest.Count+'] SHA256 已通過：'+$entry.File+'；耗時 '+$hashStarted.Elapsed.TotalSeconds.ToString('F1')+' 秒。') -ForegroundColor Green
 }
 [pscustomobject]@{Status='Passed';Count=$manifest.Count;Reason='NUC 驅動雜湊通過'}
}
function New-SetupSkippedCheck {
 param([string]$Name,[string]$Reason)
 [pscustomobject]@{Name=$Name;Status='Skipped';Passed=$null;Detail=$Reason}
}
function Test-SetupChecksPassed {
 param([object[]]$Checks)
 return (@($Checks|Where-Object {$_.Status -ne 'Skipped' -and -not $_.Passed}).Count -eq 0)
}
function New-SetupDriverSelection {
 param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$DriverPackagePath)
 $base=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackageRoot).TrimEnd('\')+'\'
 $selected=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DriverPackagePath).TrimEnd('\')
 $relative=''
 if([IO.Path]::GetPathRoot($base) -ieq [IO.Path]::GetPathRoot($selected)){
  $relative=[Uri]::UnescapeDataString(([Uri]$base).MakeRelativeUri([Uri]($selected+'\')).ToString()).Replace('/','\').TrimEnd('\')
  if(-not $relative){$relative='.'}
 }
 [pscustomobject]@{SchemaVersion=1;RelativePath=$relative;AbsolutePath=$selected;PackageSHA256=(Get-FileHash -LiteralPath (Join-Path $selected 'package.json') -Algorithm SHA256 -ErrorAction Stop).Hash;ManifestSHA256=(Get-FileHash -LiteralPath (Join-Path $selected 'manifest.json') -Algorithm SHA256 -ErrorAction Stop).Hash}
}
function Get-SetupSavedDriverSelection {
 param([string]$ResultPath,[string]$Computer=$env:COMPUTERNAME,[string]$UserSID,[string]$PackageRoot=(Split-Path -Parent $PSScriptRoot))
 if(-not(Test-Path -LiteralPath $ResultPath -PathType Leaf)){return ''}
 if(-not $UserSID){$UserSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
 $saved=Get-Content -LiteralPath $ResultPath -Raw -ErrorAction Stop|ConvertFrom-Json
 if($saved.Computer -ne $Computer -or $saved.UserSID -ne $UserSID){return ''}
 if(-not $saved.HardwareProfile.DriverPackagePath){return ''}
 $selection=$saved.HardwareProfile.DriverSelection
 if(-not $selection){
  # Older records never guess a new disk letter. Explicit reselection upgrades the record.
  $legacy=[string]$saved.HardwareProfile.DriverPackagePath
  if(-not [IO.Path]::IsPathRooted($legacy) -or -not(Test-Path -LiteralPath $legacy -PathType Container)){throw '舊驅動選擇路徑已失效，請以 windows.cmd 重新指定獨立驅動包。'}
  return $legacy
 }
 if($selection.SchemaVersion -ne 1 -or $selection.PackageSHA256 -notmatch '^[a-fA-F0-9]{64}$' -or $selection.ManifestSHA256 -notmatch '^[a-fA-F0-9]{64}$'){throw '驅動續跑紀錄格式不合法，請重新選擇驅動包。'}
 if($selection.RelativePath){
  if([IO.Path]::IsPathRooted($selection.RelativePath) -or $selection.RelativePath.Contains(':')){throw '驅動相對位置不可指定磁碟代號。'}
  $candidate=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $PackageRoot $selection.RelativePath))
 }else{$candidate=[string]$selection.AbsolutePath}
 if(-not [IO.Path]::IsPathRooted($candidate) -or -not(Test-Path -LiteralPath $candidate -PathType Container)){throw '找不到原選擇的獨立驅動包。請保持主包與驅動包相對位置，或以 windows.cmd 重新選擇；不會搜尋其他磁碟。'}
 foreach($item in @(@('package.json','PackageSHA256'),@('manifest.json','ManifestSHA256'))){
  if((Get-FileHash -LiteralPath (Join-Path $candidate $item[0]) -Algorithm SHA256 -ErrorAction Stop).Hash -ne $selection.($item[1])){throw '驅動包身分與原選擇不同，拒絕續跑；請重新選擇並驗證。'}
 }
 return $candidate
}

function Get-SetupSavedHardwareConfirmation {
 param([string]$ResultPath,[string]$Computer=$env:COMPUTERNAME,[string]$UserSID)
 if(-not(Test-Path -LiteralPath $ResultPath -PathType Leaf)){return @{}}
 if(-not $UserSID){$UserSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
 $saved=Get-Content -LiteralPath $ResultPath -Raw -ErrorAction Stop|ConvertFrom-Json
 if($saved.Computer -ne $Computer -or $saved.UserSID -ne $UserSID -or -not $saved.HardwareProfile.ConfirmedBoard){return @{}}
 if($saved.HardwareProfile.ConfirmationComputer -ine $Computer){throw '保存的手動硬體確認不屬於目前電腦。'}
 return @{ConfirmedBoard=[string]$saved.HardwareProfile.ConfirmedBoard;ConfirmationComputer=[string]$saved.HardwareProfile.ConfirmationComputer}
}
function Test-SetupInteractiveHost {
 try{return [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected}catch{return $false}
}
function Select-SetupDriverRequest {
 param([Parameter(Mandatory=$true)][string]$PackageRoot,[string]$DriverPackagePath,[switch]$PathSpecified,
  [string]$ConfirmedBoard,[string]$ConfirmationComputer,[bool]$Interactive=$false)
 $hardware=Get-SetupHardwareProfile -DriverPackagePath $DriverPackagePath -ConfirmedBoard $ConfirmedBoard -ConfirmationComputer $ConfirmationComputer
 Write-Host ('偵測主機板：'+$hardware.BoardProduct+'；狀態：'+$hardware.DetectionStatus)
 if($hardware.DetectionError){Write-Warning $hardware.DetectionError}
 while($hardware.DetectionStatus -eq 'Unknown' -and -not $ConfirmedBoard -and $Interactive){
  $choice=Read-Host '無法辨識型號：R 重新偵測；G 或 Enter 通用略過；1 NUC8i7HVK（板號 HVB）；2 NUC8i7HNK（板號 HNB）'
  if($choice -eq 'r'){$hardware=Get-SetupHardwareProfile;Write-Host ('重新偵測：'+$hardware.BoardProduct+'；'+$hardware.DetectionStatus);continue}
  if($choice -in @('1','2')){
   $selected=if($choice -eq '1'){'NUC8i7HVB'}else{'NUC8i7HNB'}
   $confirm=Read-Host ('請核對實際機型；輸入完整板號 '+$selected+' 確認，其他輸入取消')
   if($confirm -ieq $selected){$ConfirmedBoard=$selected;$ConfirmationComputer=$env:COMPUTERNAME;$hardware=Get-SetupHardwareProfile -ConfirmedBoard $ConfirmedBoard -ConfirmationComputer $ConfirmationComputer;break}
   continue
  }
  if(-not $choice -or $choice -eq 'g'){break}
 }
 if(-not $hardware.DriverProfileId -and -not $hardware.IsNuc8){Write-Host '通用設定：目前沒有對應的驅動設定檔。';return [pscustomobject]@{Hardware=$hardware;DriverPackagePath='';ConfirmedBoard='';ConfirmationComputer=''}}
 if(-not $PathSpecified){
  $DriverPackagePath=''
  if($Interactive){
   $candidate=Join-Path (Split-Path -Parent $PackageRoot) ('windows_driver_packages/'+$hardware.DriverProfileData.PackageDirectory)
   if(Test-Path -LiteralPath $candidate -PathType Container){
    $choice=Read-Host ('找到獨立包 '+$candidate+'；輸入 Y 選用、P 指定其他位置，Enter 略過')
    if($choice -eq 'y'){$DriverPackagePath=$candidate}elseif($choice -eq 'p'){$DriverPackagePath=Read-Host '獨立驅動包完整路徑，Enter 略過'}
   }else{$DriverPackagePath=Read-Host '找不到相鄰獨立包，輸入包完整路徑或 Enter 略過'}
  }
 }
 while($DriverPackagePath){
  try{
   $DriverPackagePath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DriverPackagePath.Trim().Trim('"'))
   $null=Test-SetupDriverPayload -Hardware $hardware -DriverPackagePath $DriverPackagePath
   break
  }catch{
   if(-not $Interactive){throw}
   Write-Warning ('驅動包未通過檢查：'+$_.Exception.Message)
   $DriverPackagePath=Read-Host '重新輸入獨立包完整路徑，或 Enter 略過'
  }
 }
 # A skipped choice must not enable a manual hardware profile without a driver package.
 if(-not $DriverPackagePath){$ConfirmedBoard='';$ConfirmationComputer='';$hardware=Get-SetupHardwareProfile}
 [pscustomobject]@{Hardware=$hardware;DriverPackagePath=$DriverPackagePath;ConfirmedBoard=$ConfirmedBoard;ConfirmationComputer=$ConfirmationComputer}
}

function Get-SetupDriverPreflight {
 param([Parameter(Mandatory=$true)][string]$PackageRoot,[string]$DriverPackagePath,[switch]$PathSpecified,
  [switch]$PackageOnly,[string]$ConfirmedBoard,[string]$ConfirmationComputer,[switch]$NonInteractive,[switch]$VerifyOnly)
 if($PackageOnly -and -not $DriverPackagePath){
  return [pscustomobject]@{Disposition='NoPackage';Result=[pscustomobject]@{Applicable=$false;Status='Skipped';Reason='未指定獨立驅動包，略過離線驗包。'}}
 }
 if(-not $PackageOnly){
  $request=Select-SetupDriverRequest -PackageRoot $PackageRoot -DriverPackagePath $DriverPackagePath -PathSpecified:$PathSpecified -ConfirmedBoard $ConfirmedBoard -ConfirmationComputer $ConfirmationComputer -Interactive:((Test-SetupInteractiveHost) -and -not $NonInteractive -and -not $VerifyOnly)
  $DriverPackagePath=$request.DriverPackagePath;$ConfirmedBoard=$request.ConfirmedBoard;$ConfirmationComputer=$request.ConfirmationComputer
 }
 if($PackageOnly){
  $identity=Get-Content -LiteralPath (Join-Path $DriverPackagePath 'package.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
  $board='NUC8i7HVB'
  if($identity.SchemaVersion -eq 2){
   $profile=Get-SetupDriverProfile -ProfileId $identity.ProfileId
   if(-not $profile){throw '獨立包指定的機型不在可信設定檔清單。'}
   $board=$profile.SupportedBoards[0]
  }
  $hardware=Get-SetupHardwareProfile -BoardProduct $board -DriverPackagePath $DriverPackagePath
 }else{$hardware=Get-SetupHardwareProfile -DriverPackagePath $DriverPackagePath -ConfirmedBoard $ConfirmedBoard -ConfirmationComputer $ConfirmationComputer}
 $decision=Get-SetupModuleDecision -Module 'install_drivers.ps1' -Hardware $hardware
 if(-not $decision.Applicable){return [pscustomobject]@{Disposition='NotApplicable';Decision=$decision}}
 $payload=Test-SetupDriverPayload -Hardware $hardware -DriverPackagePath $DriverPackagePath
 [pscustomobject]@{Disposition='Ready';DriverPackagePath=$DriverPackagePath;ConfirmedBoard=$ConfirmedBoard;ConfirmationComputer=$ConfirmationComputer;Hardware=$hardware;Decision=$decision;Payload=$payload}
}
