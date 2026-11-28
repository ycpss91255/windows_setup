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
 param([string]$BoardProduct,[string]$UICulture,[string]$UICultureSource='呼叫端指定',[string]$UICultureReason='',[string]$DriverPackagePath='',
  [ValidateSet('','NUC8i7HVB','NUC8i7HNB')][string]$ConfirmedBoard='', [string]$ConfirmationComputer='', [string]$ProfilesRoot='')
 if(-not $PSBoundParameters.ContainsKey('UICulture')){
  $boundary=Join-Path $PSScriptRoot 'entry_os_boundary.ps1'
  if(-not (Get-Command Get-SetupEntryUserUILanguage -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $boundary -PathType Leaf)){. $boundary}
  $language=if(Get-Command Get-SetupEntryUserUILanguage -ErrorAction SilentlyContinue){Get-SetupEntryUserUILanguage}else{[pscustomobject]@{Name='';Source='目標使用者登錄';Reason='缺少 entry_os_boundary.ps1，無法判斷目標使用者語言'}}
  $UICulture=[string]$language.Name;$UICultureSource=[string]$language.Source;$UICultureReason=[string]$language.Reason
 }
 if([string]::IsNullOrWhiteSpace($UICulture) -and -not $UICultureReason){$UICultureReason='呼叫端明確指定空白語言，無法判斷目標使用者語言'}
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
 [pscustomobject]@{Name=$(if($profile){$profile.ProfileId}else{'Generic'});DriverProfileId=$(if($profile){$profile.ProfileId}else{''});DriverProfileData=$profile;BoardProduct=$BoardProduct;DriverBoard=$driverBoard;IsNuc8=($driverBoard -in @('NUC8i7HVB','NUC8i7HNB'));IsDetectedNuc8=$detected;DetectionStatus=$status;DetectionError=$detectionError;ConfirmedBoard=$ConfirmedBoard;ConfirmationComputer=$ConfirmationComputer;UICulture=$UICulture;UICultureSource=$UICultureSource;UICultureReason=$UICultureReason;DriverPackagePath=$DriverPackagePath}
}
function Get-SetupModuleDecision {
 param([Parameter(Mandatory=$true)][string]$Module,[Parameter(Mandatory=$true)]$Hardware)
 $hasProfile=([bool]$Hardware.DriverProfileId -or $Hardware.IsNuc8)
 $skip=($Module -eq 'install_drivers.ps1' -and -not $hasProfile) -or ($Module -eq 'apply_amd_privacy_settings.ps1' -and -not $Hardware.IsNuc8)
 if($Module -eq 'apply_amd_privacy_settings.ps1' -and $Hardware.ConfirmedBoard -and -not $Hardware.IsDetectedNuc8){$skip=$true}
 $reason='非 NUC8i7HV/HN：略過 NUC 專屬驅動／AMD 設定'
 if($Module -eq 'install_drivers.ps1' -and $hasProfile -and -not $Hardware.DriverPackagePath){$skip=$true;$reason='未選擇獨立驅動包，略過驅動安裝'}
 $unknown=$false
 if($Module -eq 'desktop_icon_layout.ps1'){
  if([string]::IsNullOrWhiteSpace([string]$Hardware.UICulture)){$skip=$true;$unknown=$true;$reason='無法判斷目標使用者語言（Unknown），未套用圖示座標：'+$Hardware.UICultureReason}
  elseif($Hardware.UICulture -ne 'zh-TW'){$skip=$true;$reason='目前排列範本使用繁體中文圖示名稱，略過其他語系的座標套用；目標使用者語言為 '+$Hardware.UICulture+'（來源：'+$Hardware.UICultureSource+'）'}
 }
 [pscustomobject]@{Module=$Module;Applicable=(-not $skip);Status=$(if($unknown){'Unknown'}elseif($skip){'Skipped'}else{'Applicable'});Reason=$(if($skip){$reason}else{'適用目前硬體設定檔'})}
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
    if($driver.PSObject.Properties['NamingOnly'] -and ($driver.NamingOnly -isnot [bool] -or -not $driver.NamingOnly -or $driver.ParentTarget)){throw '驅動 NamingOnly 只能是 true 且不可有父目標。'}
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
function Test-SetupDriverPackageIdentity {
 # Read-only identity check shared by the Enter prompt and the full verification; it never hashes archives.
 param([Parameter(Mandatory=$true)]$Hardware,[Parameter(Mandatory=$true)][string]$DriverPackagePath,[switch]$AllowLegacyManifest,[switch]$SkipArchives)
 $driverRoot=$DriverPackagePath
 if(-not $AllowLegacyManifest){
  $identity=Get-Content -LiteralPath (Join-Path $driverRoot 'package.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
  if($identity.SchemaVersion -eq 2){
   $profile=$Hardware.DriverProfileData
   if(-not $profile -or $identity.ProfileId -cne $Hardware.DriverProfileId -or $identity.Architecture -cne $profile.Architecture -or $identity.ProfileSHA256 -notmatch '^[A-Fa-f0-9]{64}$' -or $identity.ProfileSHA256 -ne $profile.ProfileSHA256 -or @($identity.SupportedBoards).Count -ne @($profile.SupportedBoards).Count -or @($identity.SupportedBoards|Select-Object -Unique).Count -ne @($profile.SupportedBoards).Count -or @($identity.SupportedBoards|Where-Object {$_ -notin $profile.SupportedBoards}).Count -or $Hardware.DriverBoard -notin $profile.SupportedBoards){throw '驅動包設定檔與目前硬體識別不符。'}
   # 本機保存的驅動清單不含包內設定檔；工具設定檔雜湊已與 package.json 宣告比對。
   $included=Join-Path $driverRoot ('drivers/'+$profile.ProfileId+'/profile.json')
   if(-not $SkipArchives -and (Get-FileHash -LiteralPath $included -Algorithm SHA256 -ErrorAction Stop).Hash -ne $profile.ProfileSHA256){throw '驅動包內設定檔原始雜湊不符。'}
  }elseif($identity.SchemaVersion -ne 1 -or -not $Hardware.IsNuc8 -or $identity.HardwareProfile -ne 'NUC8' -or $identity.Architecture -ne 'x64' -or @($identity.SupportedBoards).Count -ne 2 -or 'NUC8i7HVB' -notin $identity.SupportedBoards -or 'NUC8i7HNB' -notin $identity.SupportedBoards -or $Hardware.DriverBoard -notin $identity.SupportedBoards){throw '驅動包機型或架構識別不符合目前硬體。'}
 }
 $manifest=Get-Content -LiteralPath (Join-Path $driverRoot 'manifest.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
 $manifest=@(Get-SetupDriverManifestEntries -Manifest $manifest)
 foreach($entry in $manifest){
  if($entry.File -notmatch '^[^\/:]+\.zip$' -or $entry.File -match '^\.\.' -or $entry.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'NUC 驅動清單格式不合法。'}
  if(-not $SkipArchives -and -not(Test-Path -LiteralPath (Join-Path $driverRoot $entry.File) -PathType Leaf)){throw ('缺少驅動：'+$entry.File)}
 }
 [pscustomobject]@{Entries=$manifest}
}
function Test-SetupDriverExactMatch {
 # Enter may install only when every identity fact lines up; any doubt returns a plain-language reason.
 param([Parameter(Mandatory=$true)]$Hardware,[Parameter(Mandatory=$true)][string]$DriverPackagePath)
 $no={param($why,$code='BoardMismatch')[pscustomobject]@{Matched=$false;Reason=$why;Code=$code}}
 if($Hardware.ConfirmedBoard){return (& $no '型號是手動確認的，不是系統自動偵測到的。')}
 if($Hardware.DetectionStatus -ne 'Detected'){return (& $no '系統沒有自動偵測到唯一的主機板型號。')}
 $board=[string]$Hardware.DriverBoard
 $profile=$Hardware.DriverProfileData
 if(-not $board -or -not $profile -or $Hardware.BoardProduct.Trim() -cne $board){return (& $no '偵測到的型號沒有對應的驅動設定檔。')}
 if($profile.SupportedBoards -cnotcontains $board){return (& $no ('偵測到的型號 '+$board+' 不在本工具支援清單內。'))}
 try{$identity=Get-Content -LiteralPath (Join-Path $DriverPackagePath 'package.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json}catch{return (& $no '驅動包的 package.json 缺少或讀不到。' 'IdentityFailed')}
 if($identity.SupportedBoards -cnotcontains $board){return (& $no ('偵測到的型號 '+$board+' 不在驅動包支援的型號清單內。'))}
 try{$null=Test-SetupDriverPackageIdentity -Hardware $Hardware -DriverPackagePath $DriverPackagePath}catch{return (& $no ('驅動包身分檢查沒通過：'+$_.Exception.Message) 'IdentityFailed')}
 [pscustomobject]@{Matched=$true;Reason='';Code='Matched'}
}
function Test-SetupDriverPayload {
 param([Parameter(Mandatory=$true)]$Hardware,[string]$DriverPackagePath,[switch]$AllowLegacyManifest,[switch]$InstalledStateOnly)
 if(-not $Hardware.DriverProfileId -and -not $Hardware.IsNuc8){return [pscustomobject]@{Status='Skipped';Count=0;Reason='目前硬體沒有驅動設定檔'}}
 if(-not $DriverPackagePath){return [pscustomobject]@{Status='Skipped';Count=0;Reason='未選擇獨立驅動包'}}
 $driverRoot=$DriverPackagePath
 if($InstalledStateOnly){
  # 驅動包已不在：只核對本機保存的清單身分，驗收改讀本機已安裝驅動，不把找不到封存檔當失敗。
  $null=Test-SetupDriverPackageIdentity -Hardware $Hardware -DriverPackagePath $driverRoot -SkipArchives
  return [pscustomobject]@{Status='InstalledState';Count=0;Reason='驅動包不在場，改以本機已安裝驅動讀回驗收'}
 }
 $manifest=@((Test-SetupDriverPackageIdentity -Hardware $Hardware -DriverPackagePath $driverRoot -AllowLegacyManifest:$AllowLegacyManifest).Entries)
 $validationIndex=0
 foreach($entry in $manifest){
  $validationIndex++
  $path=Join-Path $driverRoot $entry.File
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
function Get-SetupResumeDriverSelection {
 # 重開後自動驗收：原驅動包仍在原位置且身分相同時沿用；不在時改用本機保存的清單，只讀回已安裝狀態。
 param([string]$ResultPath,[Parameter(Mandatory=$true)][string]$StagedDriverRoot,[string]$Computer=$env:COMPUTERNAME,[string]$UserSID)
 $none=[pscustomobject]@{Path='';PayloadAbsent=$false;Selection=$null}
 if(-not(Test-Path -LiteralPath $ResultPath -PathType Leaf)){return $none}
 if(-not $UserSID){$UserSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
 $saved=Get-Content -LiteralPath $ResultPath -Raw -ErrorAction Stop|ConvertFrom-Json
 if($saved.Computer -ne $Computer -or $saved.UserSID -ne $UserSID -or -not $saved.HardwareProfile.DriverPackagePath){return $none}
 $selection=$saved.HardwareProfile.DriverSelection
 if(-not $selection -or $selection.SchemaVersion -ne 1 -or $selection.PackageSHA256 -notmatch '^[a-fA-F0-9]{64}$' -or $selection.ManifestSHA256 -notmatch '^[a-fA-F0-9]{64}$'){throw '驅動續跑紀錄格式不合法，無法自動驗收驅動；請插回工具包執行 windows.cmd -AfterRestart。'}
 $original=[string]$selection.AbsolutePath
 $present=([IO.Path]::IsPathRooted($original) -and (Test-Path -LiteralPath $original -PathType Container))
 $root=if($present){$original}else{$StagedDriverRoot}
 foreach($item in @(@('package.json','PackageSHA256'),@('manifest.json','ManifestSHA256'))){
  $file=Join-Path $root $item[0]
  if(-not(Test-Path -LiteralPath $file -PathType Leaf) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction Stop).Hash -ne $selection.($item[1])){
   if($present){throw '驅動包身分與原選擇不同，拒絕續跑；請重新選擇並驗證。'}
   throw '本機保存的驅動清單與原選擇不同，拒絕驗收；請插回工具包執行 windows.cmd -AfterRestart。'
  }
 }
 [pscustomobject]@{Path=$root;PayloadAbsent=(-not $present);Selection=$selection}
}
function Get-SetupEntryDriverSource {
 # 一般入口沿用工具包旁的原選擇；本機續跑 runtime 改用原絕對位置或本機保存清單。
 param([Parameter(Mandatory=$true)][string]$ResultPath)
 if((Get-Command Test-SetupResumeRuntime -ErrorAction SilentlyContinue) -and (Test-SetupResumeRuntime)){return Get-SetupResumeDriverSelection -ResultPath $ResultPath -StagedDriverRoot (Get-SetupResumePaths).Driver}
 [pscustomobject]@{Path=(Get-SetupSavedDriverSelection -ResultPath $ResultPath);PayloadAbsent=$false;Selection=$null}
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
function New-SetupDriverChoiceFacts {
 @{Choice='NotPrompted';Package='NotChecked';Detected='?';Supported='?';Manual=$false;InputMissing=$false}
}
function Get-SetupDriverChoiceBoard {
 # Model text only: letters, digits and a few signs, so a path, quote or line break can never reach the record.
 param($Hardware)
 if($Hardware.DetectionStatus -eq 'Ambiguous'){return '*'}
 $board=([string]$Hardware.BoardProduct).Trim()
 if($Hardware.DetectionStatus -eq 'Detected' -and $board -cmatch '\A[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,47}\z'){return $board}
 return '?'
}
function Get-SetupDriverChoicePackageBoards {
 param([string]$DriverPackagePath)
 try{
  if(-not(Test-Path -LiteralPath $DriverPackagePath -PathType Container)){return '-'}
  $boards=@((Get-Content -LiteralPath (Join-Path $DriverPackagePath 'package.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json).SupportedBoards)
 }catch{return '?'}
 if($boards.Count -lt 1 -or $boards.Count -gt 8 -or @($boards|Where-Object {$_ -isnot [string] -or $_ -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,47}\z'}).Count){return '?'}
 return ($boards -join ',')
}
function Get-SetupDriverChoiceFailure {
 param($Hardware,[string]$DriverPackagePath)
 $supported=Get-SetupDriverChoicePackageBoards -DriverPackagePath $DriverPackagePath
 if($supported -ceq '-'){return 'NotFound'}
 if($supported -cne '?' -and ($supported -split ',') -cnotcontains [string]$Hardware.DriverBoard){return 'BoardMismatch'}
 try{$null=Test-SetupDriverPackageIdentity -Hardware $Hardware -DriverPackagePath $DriverPackagePath}catch{return 'IdentityFailed'}
 return 'PayloadFailed'
}
function ConvertTo-SetupDriverChoiceRecord {
 param([hashtable]$Facts)
 'v1;choice='+$Facts.Choice+';package='+$Facts.Package+';detected='+$Facts.Detected+';supported='+$Facts.Supported+';manual='+$(if($Facts.Manual){'1'}else{'0'})
}
function ConvertFrom-SetupDriverChoiceRecord {
 # The record crosses the elevation command line and a user-writable result file: accept only the exact shape.
 param($Record)
 if($Record -isnot [string]){return $null}
 $board='[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,47}'
 if($Record -cnotmatch ('\Av1;choice=(?<choice>Selected|SkippedEnter|SkippedN|SkippedGeneric|InputFailed|NotPrompted);package=(?<package>Verified|Matched|NotFound|BoardMismatch|IdentityFailed|PayloadFailed|NotApplicable|NotChecked);detected=(?<detected>\?|\*|'+$board+');supported=(?<supported>\?|-|'+$board+'(?:,'+$board+'){0,7});manual=(?<manual>[01])\z')){return $null}
 if(($Matches.choice -ceq 'Selected') -ne ($Matches.package -ceq 'Verified')){return $null}
 [pscustomobject]@{Record=$Record;Choice=$Matches.choice;Package=$Matches.package;Detected=$Matches.detected;Supported=$Matches.supported;Manual=($Matches.manual -ceq '1')}
}
function Resolve-SetupDriverChoice {
 # Describes the choice only; installation always follows the real package path, never this record.
 param($Record,$Hardware)
 $parsed=ConvertFrom-SetupDriverChoiceRecord -Record $Record
 if($parsed -and $Hardware){
  $selected=$parsed.Choice -ceq 'Selected'
  $current=Get-SetupDriverChoiceBoard -Hardware $Hardware
  if($selected -ne [bool]$Hardware.DriverPackagePath -or ($selected -and $parsed.Manual -ne [bool]$Hardware.ConfirmedBoard) -or ($current -cne '?' -and $parsed.Detected -cne '?' -and $current -cne $parsed.Detected)){$parsed=$null}
 }
 if(-not $parsed){return [pscustomobject]@{Record='未知';Text='[驅動選擇] 結果：未知（沒有可信的選包結果）；驅動包：未知；偵測型號：未知；包支援型號：未知；手動確認型號：未知'}}
 $choices=@{Selected='選用';SkippedEnter='Enter 略過';SkippedN='輸入 N 略過';SkippedGeneric='選通用設定';InputFailed='讀取輸入失敗';NotPrompted='未詢問'}
 $packages=@{Verified='檢查通過';Matched='型號與身分相符';NotFound='找不到包';BoardMismatch='型號未對上';IdentityFailed='身分檢查失敗';PayloadFailed='內容檢查失敗';NotApplicable='沒有對應的驅動設定檔';NotChecked='未檢查'}
 $detected=if($parsed.Detected -ceq '?'){'未知'}elseif($parsed.Detected -ceq '*'){'多塊主機板'}else{$parsed.Detected}
 $supported=if($parsed.Supported -ceq '?'){'未知'}elseif($parsed.Supported -ceq '-'){'無'}else{$parsed.Supported.Replace(',','、')}
 [pscustomobject]@{Record=$parsed.Record;Text=('[驅動選擇] 結果：'+$choices[$parsed.Choice]+'；驅動包：'+$packages[$parsed.Package]+'；偵測型號：'+$detected+'；包支援型號：'+$supported+'；手動確認型號：'+$(if($parsed.Manual){'是'}else{'否'}))}
}
function Get-SetupSavedDriverChoice {
 param([string]$ResultPath,$Hardware)
 $record=$null
 try{
  $saved=Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
  if($saved.Computer -ceq $env:COMPUTERNAME -and $saved.UserSID -ceq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){$record=$saved.DriverChoice}
 }catch{$record=$null}
 Resolve-SetupDriverChoice -Record $record -Hardware $Hardware
}
function Read-SetupDriverAnswer {
 # A failed read keeps stopping the run; the exception only carries the classification, never the message or input.
 param([string]$Prompt,[hashtable]$Facts,[switch]$Required)
 try{$answer=Read-Host $Prompt}catch{$Facts.Choice='InputFailed';$_.Exception.Data['SetupDriverChoice']=ConvertTo-SetupDriverChoiceRecord -Facts $Facts;throw}
 $Facts.InputMissing=($null -eq $answer)
 if($Required -and $Facts.InputMissing){
  # End of input is not an Enter: this prompt may install on Enter, so stop as before but say why.
  $Facts.Choice='InputFailed';$failure=New-Object InvalidOperationException '沒有讀到輸入，已停止選包，沒有選用驅動包。'
  $failure.Data['SetupDriverChoice']=ConvertTo-SetupDriverChoiceRecord -Facts $Facts
  throw $failure
 }
 return $answer
}
function Get-SetupDriverSkipChoice {
 param([hashtable]$Facts)
 if($Facts.InputMissing){'InputFailed'}else{'SkippedEnter'}
}
function Write-SetupAbortedDriverChoice {
 # The run stopped before elevation and before any transcript, so leave the classification in its own Setup log.
 param([string]$PackageRoot,$ErrorRecord)
 try{
  $record=$null
  for($failure=$ErrorRecord.Exception;$failure -and -not $record;$failure=$failure.InnerException){$record=$failure.Data['SetupDriverChoice']}
  $reports=Join-Path $PackageRoot 'reports'
  if(-not(Test-Path -LiteralPath $reports)){$null=New-Item -ItemType Directory -Path $reports -ErrorAction Stop}
  $lines=@((Resolve-SetupDriverChoice -Record $record).Text,'選包階段中止，整輪設定沒有開始。')
  Add-Content -LiteralPath (Join-Path $reports ('Setup-'+(Get-Date -Format yyyyMMdd-HHmmss)+'.log')) -Value $lines -Encoding UTF8 -ErrorAction Stop
 }catch{Write-Warning '選包階段中止，但無法保存驅動選擇紀錄。'}
}
function Select-SetupDriverRequest {
 param([Parameter(Mandatory=$true)][string]$PackageRoot,[string]$DriverPackagePath,[switch]$PathSpecified,
  [string]$ConfirmedBoard,[string]$ConfirmationComputer,[bool]$Interactive=$false)
 $facts=New-SetupDriverChoiceFacts
 $hardware=Get-SetupHardwareProfile -DriverPackagePath $DriverPackagePath -ConfirmedBoard $ConfirmedBoard -ConfirmationComputer $ConfirmationComputer
 Write-Host ('偵測主機板：'+$hardware.BoardProduct+'；狀態：'+$hardware.DetectionStatus)
 if($hardware.DetectionError){Write-Warning $hardware.DetectionError}
 while($hardware.DetectionStatus -eq 'Unknown' -and -not $ConfirmedBoard -and $Interactive){
  $choice=Read-SetupDriverAnswer -Facts $facts -Prompt '無法辨識型號：R 重新偵測；G 或 Enter 通用略過；1 NUC8i7HVK（板號 HVB）；2 NUC8i7HNK（板號 HNB）'
  if($choice -eq 'r'){$hardware=Get-SetupHardwareProfile;Write-Host ('重新偵測：'+$hardware.BoardProduct+'；'+$hardware.DetectionStatus);continue}
  if($choice -in @('1','2')){
   $selected=if($choice -eq '1'){'NUC8i7HVB'}else{'NUC8i7HNB'}
   $confirm=Read-SetupDriverAnswer -Facts $facts -Prompt ('請核對實際機型；輸入完整板號 '+$selected+' 確認，其他輸入取消')
   if($confirm -ieq $selected){$ConfirmedBoard=$selected;$ConfirmationComputer=$env:COMPUTERNAME;$hardware=Get-SetupHardwareProfile -ConfirmedBoard $ConfirmedBoard -ConfirmationComputer $ConfirmationComputer;break}
   continue
  }
  if(-not $choice -or $choice -eq 'g'){$facts.Choice=if($choice){'SkippedGeneric'}else{Get-SetupDriverSkipChoice -Facts $facts};break}
 }
 $facts.Detected=Get-SetupDriverChoiceBoard -Hardware $hardware;$facts.Manual=[bool]$ConfirmedBoard
 if(-not $hardware.DriverProfileId -and -not $hardware.IsNuc8){Write-Host '通用設定：目前沒有對應的驅動設定檔。';$facts.Package='NotApplicable';return [pscustomobject]@{Hardware=$hardware;DriverPackagePath='';ConfirmedBoard='';ConfirmationComputer='';SelectionRecord=(ConvertTo-SetupDriverChoiceRecord -Facts $facts)}}
 $notifySkip=$false;$adjacentOffered=$false
 if(-not $PathSpecified){
  $DriverPackagePath=''
  if($Interactive){
   $candidate=Join-Path (Split-Path -Parent $PackageRoot) ('windows_driver_packages/'+$hardware.DriverProfileData.PackageDirectory)
   if(Test-Path -LiteralPath $candidate -PathType Container){
    $adjacentOffered=$true
    $match=Test-SetupDriverExactMatch -Hardware $hardware -DriverPackagePath $candidate
    $facts.Package=$match.Code;$facts.Supported=Get-SetupDriverChoicePackageBoards -DriverPackagePath $candidate
    while($true){
     if($match.Matched){$choice=Read-SetupDriverAnswer -Required -Facts $facts -Prompt ('找到獨立包 '+$candidate+'；偵測到的型號 '+$hardware.DriverBoard+' 與驅動包支援的型號完全相符。Enter 或 Y 安裝，N 略過，P 指定其他位置')}
     else{$choice=Read-SetupDriverAnswer -Required -Facts $facts -Prompt ('找到獨立包 '+$candidate+'；但無法確認完全對上：'+$match.Reason+' 為安全起見 Enter 略過；Y 明確選用（仍會嚴格檢查），P 指定其他位置')}
     $choice=([string]$choice).Trim()
     if($choice -eq 'p'){$DriverPackagePath=Read-SetupDriverAnswer -Facts $facts -Prompt '獨立驅動包完整路徑，Enter 略過';$notifySkip=-not $DriverPackagePath;$facts.Choice=Get-SetupDriverSkipChoice -Facts $facts;break}
     if($choice -eq 'y' -or ($match.Matched -and $choice -eq '')){$DriverPackagePath=$candidate;break}
     if($choice -eq 'n' -or (-not $match.Matched -and $choice -eq '')){$facts.Choice=if($choice){'SkippedN'}else{Get-SetupDriverSkipChoice -Facts $facts};$notifySkip=$true;break}
     Write-Warning '無法辨識的輸入，請輸入 Enter、Y、N 或 P。'
    }
   }else{$facts.Package='NotFound';$facts.Supported='-';$DriverPackagePath=Read-SetupDriverAnswer -Facts $facts -Prompt '找不到相鄰獨立包，輸入包完整路徑或 Enter 略過';$facts.Choice=Get-SetupDriverSkipChoice -Facts $facts}
  }
 }
 while($DriverPackagePath){
  try{
   $DriverPackagePath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DriverPackagePath.Trim().Trim('"'))
   $null=Test-SetupDriverPayload -Hardware $hardware -DriverPackagePath $DriverPackagePath
   break
  }catch{
   $facts.Package=Get-SetupDriverChoiceFailure -Hardware $hardware -DriverPackagePath $DriverPackagePath;$facts.Supported=Get-SetupDriverChoicePackageBoards -DriverPackagePath $DriverPackagePath
   if(-not $Interactive){$_.Exception.Data['SetupDriverChoice']=ConvertTo-SetupDriverChoiceRecord -Facts $facts;throw}
   Write-Warning ('驅動包未通過檢查：'+$_.Exception.Message)
   $DriverPackagePath=Read-SetupDriverAnswer -Facts $facts -Prompt '重新輸入獨立包完整路徑，或 Enter 略過';$facts.Choice=Get-SetupDriverSkipChoice -Facts $facts
   if(-not $DriverPackagePath -and $adjacentOffered){$notifySkip=$true}
  }
 }
 if(-not $DriverPackagePath -and $notifySkip){Write-Host '本次不安裝驅動。之後要補裝：重新執行 windows.cmd 並選用驅動包；-AfterRestart 續跑不會重新詢問。' -ForegroundColor Yellow}
 if($DriverPackagePath){$facts.Choice='Selected';$facts.Package='Verified';$facts.Supported=Get-SetupDriverChoicePackageBoards -DriverPackagePath $DriverPackagePath}
 # A skipped choice must not enable a manual hardware profile without a driver package.
 if(-not $DriverPackagePath){$ConfirmedBoard='';$ConfirmationComputer='';$hardware=Get-SetupHardwareProfile}
 [pscustomobject]@{Hardware=$hardware;DriverPackagePath=$DriverPackagePath;ConfirmedBoard=$ConfirmedBoard;ConfirmationComputer=$ConfirmationComputer;SelectionRecord=(ConvertTo-SetupDriverChoiceRecord -Facts $facts)}
}
