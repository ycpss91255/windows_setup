#Requires -Version 5.1
function Get-SetupDebloatBuild {[Environment]::OSVersion.Version.Build}
function Read-SetupDebloatRegistry {
 param([string]$Path,[string]$Name)
 try{$key=Get-Item -LiteralPath $Path -ErrorAction Stop;[pscustomobject]@{Value=$key.GetValue($Name);Kind=[string]$key.GetValueKind($Name);Error=''}}
 catch{[pscustomobject]@{Value=$null;Kind='';Error=$_.Exception.Message}}
}
function Get-SetupDebloatFeaturePlan {
 param([Parameter(Mandatory=$true)][string]$ModuleRoot,[int]$Build=(Get-SetupDebloatBuild))
 $profile=Get-Content -LiteralPath (Join-Path $ModuleRoot 'debloat_profile.json') -Raw -Encoding UTF8|ConvertFrom-Json
 $catalog=(Get-Content -LiteralPath (Join-Path $ModuleRoot 'win11debloat/Config/Features.json') -Raw -Encoding UTF8|ConvertFrom-Json).Features
 if(-not @($profile.Features).Count -or @($profile.Features|Select-Object -Unique).Count -ne @($profile.Features).Count){throw '清理功能清單為空或重複。'}
 foreach($id in $profile.Features){
  $catalogMatches=@($catalog|Where-Object FeatureId -ceq $id)
  if($catalogMatches.Count -ne 1 -or $catalogMatches[0].RegistryKey -cnotmatch '^[A-Za-z0-9_]+\.reg$'){throw '清理功能缺少唯一可驗證的登錄契約。'}
  $feature=$catalogMatches[0];$checks=@();$path=''
  foreach($line in Get-Content -LiteralPath (Join-Path $ModuleRoot ('win11debloat/Regfiles/'+$feature.RegistryKey)) -Encoding Unicode){
   $text=$line.Trim()
   if(-not $text -or $text.StartsWith(';') -or $text -ceq 'Windows Registry Editor Version 5.00'){continue}
   if($text -cmatch '^\[(HKEY_CURRENT_USER|HKEY_LOCAL_MACHINE)\\([^\]]+)\]$'){$hive=if($matches[1] -ceq 'HKEY_CURRENT_USER'){'HKCU:'}else{'HKLM:'};$path=$hive+'\'+$matches[2];continue}
   if($path -and $text -cmatch '^"([^"\\]+)"=dword:([A-Fa-f0-9]{8})$'){$checks+=[pscustomobject]@{Path=$path;Name=$matches[1];Expected=[Convert]::ToUInt32($matches[2],16)};continue}
   throw '清理功能包含尚未支援的讀回契約，拒絕假成功。'
  }
  if(-not $checks.Count){throw '清理功能沒有登錄讀回項目。'}
  $supported=($null -eq $feature.MinVersion -or $Build -ge $feature.MinVersion) -and ($null -eq $feature.MaxVersion -or $Build -le $feature.MaxVersion)
  [pscustomobject]@{FeatureId=$id;Supported=$supported;Build=$Build;MinimumBuild=$feature.MinVersion;MaximumBuild=$feature.MaxVersion;Checks=$checks}
 }
}
function Test-SetupDebloatFeatures {
 param([Parameter(Mandatory=$true)][string]$ModuleRoot,[int]$Build=(Get-SetupDebloatBuild))
 $features=@(foreach($feature in Get-SetupDebloatFeaturePlan -ModuleRoot $ModuleRoot -Build $Build){
  $checks=@()
  if($feature.Supported){foreach($policy in $feature.Checks){
   $actual=Read-SetupDebloatRegistry -Path $policy.Path -Name $policy.Name
   $numeric=$actual.Value -is [int] -or $actual.Value -is [uint32]
   $checks+=[pscustomobject]@{Path=$policy.Path;Name=$policy.Name;Expected=$policy.Expected;Actual=$actual.Value;Kind=$actual.Kind;Passed=($numeric -and $actual.Kind -ceq 'DWord' -and $actual.Value -eq $policy.Expected);ReadError=$actual.Error}
  }}
  $status=if(-not $feature.Supported){'Skipped'}elseif(@($checks|Where-Object {-not $_.Passed}).Count){'Failed'}else{'Passed'}
  [pscustomobject]@{FeatureId=$feature.FeatureId;Status=$status;Build=$feature.Build;MinimumBuild=$feature.MinimumBuild;MaximumBuild=$feature.MaximumBuild;Reason=$(if(-not $feature.Supported){'目前 Windows build 不在上游功能適用範圍，未宣稱套用。'}else{''});Checks=$checks}
 })
 [pscustomobject]@{Success=(@($features|Where-Object Status -eq Failed).Count -eq 0);Features=$features;Scope='僅核對所選功能的登錄型別及值；不代表應用程式已移除、所有資料傳輸停止或未適用功能已套用。'}
}
function Invoke-SetupDebloatNative {
 param([string[]]$Arguments)
 & powershell.exe @Arguments|Out-Host
 return $LASTEXITCODE
}
function Invoke-SetupDebloatOneDrive {param([string]$ModuleRoot) & (Join-Path $ModuleRoot 'remove_one_drive.ps1')}
function Test-SetupDebloatPackageIdentity {
 param($Package,[string]$Id)
 if($Package.PackageFullName -isnot [string] -or $Package.PackageFullName -cnotmatch ('^'+[regex]::Escape($Id)+'_[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+_[A-Za-z0-9]+_[A-Za-z0-9.~-]*_[A-Za-z0-9]+$') -or $Package.PackageFamilyName -isnot [string] -or $Package.IsBundle -isnot [bool]){return $false}
 $parts=$Package.PackageFullName.Split('_')
 return ($parts.Count -eq 5 -and $Package.PackageFamilyName -ceq ($Id+'_'+$parts[4]))
}
function Invoke-SetupDebloatMissingApps {
 param([Parameter(Mandatory=$true)][string[]]$AppIds)
 $allowed=@('Microsoft.Copilot','Microsoft.GamingServices','Microsoft.Edge.GameAssist')
 if(-not $AppIds.Count -or @($AppIds|Where-Object {$_ -cnotin $allowed}).Count -or @($AppIds|Select-Object -Unique).Count -ne $AppIds.Count){throw '不允許的清理目標。'}
 $errors=New-Object System.Collections.Generic.List[string]
 try{$installed=@(Get-AppxPackage -AllUsers -PackageTypeFilter Main,Bundle -ErrorAction Stop)}catch{$errors.Add('讀取已安裝套件失敗：'+$_.Exception.Message);$installed=@()}
 try{$provisioned=@(Get-AppxProvisionedPackage -Online -ErrorAction Stop)}catch{$errors.Add('讀取預佈建套件失敗：'+$_.Exception.Message);$provisioned=@()}
 if($errors.Count){return [pscustomobject]@{Success=$false;Targets=$AppIds;Errors=@($errors.ToArray())}}
 foreach($id in $AppIds){
  $selectedPackages=@($installed|Where-Object {$_.Name -ceq $id});$provisionedMatches=@($provisioned|Where-Object {$_.DisplayName -ceq $id});$invalid=$false
  foreach($pkg in $selectedPackages){if(-not (Test-SetupDebloatPackageIdentity -Package $pkg -Id $id)){$invalid=$true}}
  foreach($pkg in $provisionedMatches){if($pkg.PackageName -isnot [string] -or $pkg.PackageName -cnotmatch ('^'+[regex]::Escape($id)+'_[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+_[A-Za-z0-9]+_[A-Za-z0-9.~-]*_[A-Za-z0-9]+$')){$invalid=$true}}
  if($invalid){$errors.Add($id+' 套件身分不完整或不符');continue}
  $bundles=@($selectedPackages|Where-Object IsBundle);$bundleFailed=$false;$done=@{}
  foreach($pkg in $bundles){
   if($done.ContainsKey($pkg.PackageFullName)){continue};$done[$pkg.PackageFullName]=$true
   try{Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop|Out-Null}catch{$bundleFailed=$true;$errors.Add($id+' bundle 移除失敗：'+$_.Exception.Message)}
  }
  if($bundles.Count -and -not $bundleFailed){
   try{$selectedPackages=@(Get-AppxPackage -AllUsers -PackageTypeFilter Main,Bundle -ErrorAction Stop|Where-Object {$_.Name -ceq $id})}catch{$bundleFailed=$true;$errors.Add($id+' bundle 後重新查詢失敗：'+$_.Exception.Message)}
   if(-not $bundleFailed){
    foreach($pkg in $selectedPackages){if(-not (Test-SetupDebloatPackageIdentity -Package $pkg -Id $id)){$bundleFailed=$true;$errors.Add($id+' 重新查詢的套件身分不符');break}}
    if(@($selectedPackages|Where-Object IsBundle).Count){$bundleFailed=$true;$errors.Add($id+' bundle 移除後仍存在')}
   }
  }
  if(-not $bundleFailed){
   $done=@{}
   foreach($pkg in @($selectedPackages|Where-Object {-not $_.IsBundle})){
    if($done.ContainsKey($pkg.PackageFullName)){continue};$done[$pkg.PackageFullName]=$true
    try{Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop|Out-Null}catch{$errors.Add($id+' 已安裝套件移除失敗：'+$_.Exception.Message)}
   }
  }
  $done=@{}
  foreach($pkg in $provisionedMatches){
   if($done.ContainsKey($pkg.PackageName)){continue};$done[$pkg.PackageName]=$true
   try{Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop|Out-Null}catch{$errors.Add($id+' 預佈建套件移除失敗：'+$_.Exception.Message)}
  }
 }
 [pscustomobject]@{Success=($errors.Count -eq 0);Targets=$AppIds;Errors=@($errors.ToArray())}
}
function Invoke-SetupDebloat {
 param([Parameter(Mandatory=$true)][string]$ModuleRoot,[switch]$VerifyOnly,[string]$VerificationRunId,[string]$ReportPath=(Join-Path $env:ProgramData 'NUC8-Setup/Debloat-Result.json'))
 $ErrorActionPreference='Stop'
 $apps=@(Get-Content -LiteralPath (Join-Path $ModuleRoot 'debloat_apps.txt')|Where-Object {$_ -and -not $_.StartsWith('#')})
 $profile=Get-Content -LiteralPath (Join-Path $ModuleRoot 'debloat_profile.json') -Raw -Encoding UTF8|ConvertFrom-Json
 $before=@();$code=$null;$log='';$missingResult=$null
 if(-not $VerifyOnly){
  # Validate every selected feature before any cleanup, including unsupported grammar.
  $null=@(Get-SetupDebloatFeaturePlan -ModuleRoot $ModuleRoot)
  Invoke-SetupDebloatOneDrive -ModuleRoot $ModuleRoot
  $before=@(Get-AppxPackage -AllUsers -PackageTypeFilter Main,Bundle,Framework|Where-Object {@($_.PackageUserInformation|Where-Object InstallState -eq 'Installed').Count -gt 0}|Select-Object -ExpandProperty Name -Unique)
  $log=Join-Path $ModuleRoot ('Debloat-'+(Get-Date -Format yyyyMMdd-HHmmss)+'.log')
  $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $ModuleRoot 'win11debloat/Win11Debloat.ps1'),'-CLI','-Silent','-SkipExplorerRestart','-Language','zh-TW','-LogPath',$log,'-AppRemovalTarget','AllUsers','-RemoveApps','-Apps',($apps -join ','))
  foreach($feature in $profile.Features){$arguments+=('-'+$feature)}
  Write-Host ('正在執行 Win11Debloat，已選取 '+$apps.Count+' 個 App 項目及 '+$profile.Features.Count+' 項清理設定。') -ForegroundColor Cyan
  $code=Invoke-SetupDebloatNative -Arguments $arguments
  $extra=@('Microsoft.Copilot','Microsoft.GamingServices','Microsoft.Edge.GameAssist'|Where-Object {$_ -cin $apps})
  if($extra.Count){$missingResult=Invoke-SetupDebloatMissingApps -AppIds $extra}
 }
 $readbackErrors=New-Object System.Collections.Generic.List[string];$installedReadbackOK=$true;$provisionedReadbackOK=$true
 try{$after=@(Get-AppxPackage -AllUsers -PackageTypeFilter Main,Bundle,Framework -ErrorAction Stop|Where-Object {@($_.PackageUserInformation|Where-Object InstallState -eq 'Installed').Count -gt 0}|Select-Object -ExpandProperty Name -Unique)}catch{$installedReadbackOK=$false;$after=@();$readbackErrors.Add('讀取已安裝套件失敗：'+$_.Exception.Message)}
 $remaining=@($after|Where-Object {$_ -in $apps})
 try{$provisioned=@(Get-AppxProvisionedPackage -Online -ErrorAction Stop|Where-Object DisplayName -in $apps|Select-Object -ExpandProperty DisplayName)}catch{$provisionedReadbackOK=$false;$provisioned=@();$readbackErrors.Add('讀取預佈建套件失敗：'+$_.Exception.Message)}
 $features=Test-SetupDebloatFeatures -ModuleRoot $ModuleRoot
 $success=($VerifyOnly -or ($code -is [int] -and $code -eq 0)) -and -not $remaining.Count -and -not $provisioned.Count -and $features.Success -and $readbackErrors.Count -eq 0 -and ($null -eq $missingResult -or $missingResult.Success)
 $result=[ordered]@{Success=[bool]$success;VerificationRunId=$VerificationRunId;UserSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Computer=$env:COMPUTERNAME;CheckedAt=(Get-Date).ToString('o');VerifyOnly=[bool]$VerifyOnly;ProvisionedRemaining=$(if($provisionedReadbackOK){,$provisioned}else{$null});BeforeAppCount=$before.Count;AfterAppCount=$(if($installedReadbackOK){$after.Count}else{$null});RemovedApps=@(if($installedReadbackOK){$before|Where-Object {$_ -notin $after}});SelectedRemaining=$(if($installedReadbackOK){,$remaining}else{$null});ExitCode=$code;Log=$log;AdditionalApps=$missingResult;ReadbackErrors=@($readbackErrors.ToArray());FeatureChecks=$features.Features;FeatureScope=$features.Scope}
 [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ReportPath))
 $result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ReportPath -Encoding UTF8
 if($installedReadbackOK){
  Write-Host ('本次實際移除：'+($result.RemovedApps -join ', '))
  Write-Host ('清單中仍存在：'+($remaining -join ', '))
 }else{Write-Host '無法讀回已安裝套件，移除結果不可取得。'}
 foreach($feature in $features.Features){Write-Host ('功能讀回 '+$feature.FeatureId+'：'+$feature.Status)}
 if(-not $success){throw '清理或所選功能登錄讀回未成功，請查看 Debloat-Result.json。'}
 [pscustomobject]$result
}
