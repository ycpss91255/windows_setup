#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'modules/debloat/debloat_library.ps1')
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
$script:installed=@();$script:provisioned=@();$script:removed=@();$script:fail='';$script:removeBundleChildren=$false
function Get-AppxPackage {param([switch]$AllUsers,$PackageTypeFilter) if(-not $AllUsers){throw 'all users required'};if($script:fail -eq 'query_installed' -and 'Framework' -notin $PackageTypeFilter){throw 'fixture query failed'};if($script:fail -eq 'readback_installed' -and 'Framework' -in $PackageTypeFilter){$script:readbackCalls++;if($script:readbackCalls -gt 1){throw 'fixture readback failed'}};if(-not $PackageTypeFilter -or 'Bundle' -notin $PackageTypeFilter){return @($script:installed|Where-Object {-not $_.IsBundle})};$script:installed}
function Get-AppxProvisionedPackage {param([switch]$Online) if(-not $Online){throw 'online required'};if($script:fail -eq 'query_provisioned'){throw 'fixture query failed'};$script:provisioned}
function Remove-AppxPackage {param($Package,[switch]$AllUsers) if(-not $AllUsers){throw 'all users required'};$script:removed+=('installed:'+ $Package);if($script:fail -eq 'remove_installed'){throw 'fixture remove failed'};if($script:removeBundleChildren){$script:installed=@()}}
function Remove-AppxProvisionedPackage {param($PackageName,[switch]$Online) if(-not $Online){throw 'online required'};$script:removed+=('provisioned:'+ $PackageName);if($script:fail -eq 'remove_provisioned'){throw 'fixture remove failed'}}
function Invoke-SetupDebloatNative {throw 'real process forbidden'}
function Invoke-SetupDebloatOneDrive {throw 'real OneDrive forbidden'}
function Get-Item {throw 'real registry forbidden'}
function New-Package([string]$Name,[string]$Version,[bool]$Bundle){[pscustomobject]@{Name=$Name;PackageFullName=($Name+'_'+$Version+'_x64__fixture');PackageFamilyName=($Name+'_fixture');IsBundle=$Bundle}}
$target='Microsoft.Copilot';$bundle=New-Package $target '1.0.0.0' $true;$bundle.PackageFullName=$target+'_1.0.0.0_neutral_~_fixture';$main=New-Package $target '1.0.0.0' $false
$script:installed=@($bundle,$main,(New-Package 'Microsoft.WindowsStore' '1.0.0.0' $false))
$script:provisioned=@([pscustomobject]@{DisplayName=$target;PackageName=($target+'_1.0.0.0_neutral_~_fixture')},[pscustomobject]@{DisplayName='Microsoft.WindowsStore';PackageName='Microsoft.WindowsStore_1.0.0.0_neutral_~_fixture'})
$script:removeBundleChildren=$true
$result=Invoke-SetupDebloatMissingApps -AppIds @($target)
$script:removeBundleChildren=$false
Assert ($result.Success -and $script:removed.Count -eq 2 -and ('installed:'+$bundle.PackageFullName) -in $script:removed -and ('provisioned:'+$script:provisioned[0].PackageName) -in $script:removed) 'bundle parent 與 provisioned 精確移除且不碰 Store 或 child'
$script:installed=@();$script:provisioned=@([pscustomobject]@{DisplayName='Microsoft.GamingServices';PackageName='Microsoft.GamingServices_1.0.0.0_neutral_~_fixture'});$script:removed=@()
$result=Invoke-SetupDebloatMissingApps -AppIds @('Microsoft.GamingServices')
Assert ($result.Success -and $script:removed.Count -eq 1 -and $script:removed[0] -like 'provisioned:*') '僅 provisioned 仍處理'
foreach($mode in @('query_installed','query_provisioned','remove_installed','remove_provisioned')){
 $script:installed=@($bundle);$script:provisioned=@([pscustomobject]@{DisplayName=$target;PackageName=($target+'_1.0.0.0_neutral_~_fixture')});$script:removed=@();$script:fail=$mode
 $result=Invoke-SetupDebloatMissingApps -AppIds @($target)
 Assert (-not $result.Success -and $result.Errors.Count -gt 0) ('查詢或移除失敗不假成功 '+$mode)
}
$script:fail='';$script:removed=@();$threw=$false;try{Invoke-SetupDebloatMissingApps -AppIds @('Microsoft.WindowsStore')|Out-Null}catch{$threw=$true};Assert ($threw -and $script:removed.Count -eq 0) '拒絕未授權目標'
$script:installed=@([pscustomobject]@{Name=$target;PackageFullName='Microsoft.WindowsStore_1.0.0.0_x64__fixture';PackageFamilyName=($target+'_fixture');IsBundle=$false});$script:provisioned=@();$script:removed=@()
$result=Invoke-SetupDebloatMissingApps -AppIds @($target)
Assert (-not $result.Success -and $script:removed.Count -eq 0) '錯配完整套件身分不移除'
$script:installed=@((New-Package $target '2.0.0.0' $false),$bundle);$script:provisioned=@();$script:removed=@()
$result=Invoke-SetupDebloatMissingApps -AppIds @($target)
Assert (-not $result.Success -and $script:removed.Count -eq 1 -and $script:removed[0] -ceq ('installed:'+$bundle.PackageFullName)) '重查仍有 bundle 時不移除 main'
$bad=New-Package $target '1.0.0.0' $false;$bad.PackageFamilyName=$target+'_other';$script:installed=@($bad);$script:removed=@()
$result=Invoke-SetupDebloatMissingApps -AppIds @($target)
Assert (-not $result.Success -and $script:removed.Count -eq 0) '發行者與 family 不一致拒絕移除'
$ownedTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$fixture=[IO.Path]::GetFullPath((Join-Path $ownedTemp ('debloat_missing_'+[guid]::NewGuid().ToString('N'))))
if(-not $fixture.StartsWith($ownedTemp+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'fixture 超出 TEMP'}
[void][IO.Directory]::CreateDirectory($fixture)
try {
 $module=Join-Path $fixture 'module';[void][IO.Directory]::CreateDirectory($module)
 [IO.File]::WriteAllText((Join-Path $module 'debloat_apps.txt'),$target)
 [IO.File]::WriteAllText((Join-Path $module 'debloat_profile.json'),'{"Features":["Fixture"]}')
 $report=Join-Path $fixture 'report/result.json'
 function Get-SetupDebloatFeaturePlan {param($ModuleRoot) @()}
 function Test-SetupDebloatFeatures {param($ModuleRoot) [pscustomobject]@{Success=$true;Features=@();Scope='fixture'}}
 function Invoke-SetupDebloatOneDrive {param($ModuleRoot)}
 $script:nativeCode=0;$script:nativeCalls=0
 function Invoke-SetupDebloatNative {param($Arguments) $script:nativeCalls++;return $script:nativeCode}
 $script:installed=@();$script:provisioned=@();$script:removed=@();$script:fail='';$script:removeBundleChildren=$false
 $r=Invoke-SetupDebloat -ModuleRoot $module -ReportPath $report
 $saved=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
 Assert ($r.Success -and $saved.AdditionalApps.Success -and $saved.AdditionalApps.Targets.Count -eq 1) '實際編排結果保留三項支援狀態'
 $script:nativeCode=7;$failed=$false;try{Invoke-SetupDebloat -ModuleRoot $module -ReportPath $report|Out-Null}catch{$failed=$true}
 $saved=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
 Assert ($failed -and -not $saved.Success -and $saved.ExitCode -eq 7) '上游非零仍失敗'
 $script:nativeCode=0;$script:fail='query_installed';$failed=$false;try{Invoke-SetupDebloat -ModuleRoot $module -ReportPath $report|Out-Null}catch{$failed=$true}
 $saved=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
 Assert ($failed -and -not $saved.Success -and -not $saved.AdditionalApps.Success) 'helper 查詢失敗寫入結果且不得成功'
 $script:fail='readback_installed';$script:readbackCalls=0;$script:installed=@([pscustomobject]@{Name=$target;PackageFullName=($target+'_1.0.0.0_x64__fixture');PackageFamilyName=($target+'_fixture');IsBundle=$false;PackageUserInformation=@([pscustomobject]@{InstallState='Installed'})});$failed=$false
 try{Invoke-SetupDebloat -ModuleRoot $module -ReportPath $report|Out-Null}catch{$failed=$true}
 $saved=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
 Assert ($failed -and -not $saved.Success -and $null -eq $saved.AfterAppCount -and @($saved.RemovedApps).Count -eq 0 -and $saved.ReadbackErrors.Count -gt 0) '讀回不可用不虛構已移除或零剩餘數量'
 $script:installed=@()
 $script:fail='query_provisioned';$failed=$false;try{Invoke-SetupDebloat -ModuleRoot $module -ReportPath $report|Out-Null}catch{$failed=$true}
 $saved=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
 Assert ($failed -and -not $saved.Success -and $saved.ReadbackErrors.Count -gt 0 -and $null -eq $saved.ProvisionedRemaining) '預佈建讀回失敗仍寫入失敗結果且不假稱空清單'
 $script:fail='';$script:installed=@([pscustomobject]@{Name=$target;PackageFullName=($target+'_1.0.0.0_x64__fixture');PackageFamilyName=($target+'_fixture');IsBundle=$false;PackageUserInformation=@([pscustomobject]@{InstallState='Installed'})});$failed=$false
 try{Invoke-SetupDebloat -ModuleRoot $module -ReportPath $report|Out-Null}catch{$failed=$true}
 $saved=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
 Assert ($failed -and -not $saved.Success -and $target -in $saved.SelectedRemaining) '移除後仍存在仍失敗'
 $bundleOnly=[pscustomobject]@{Name=$target;PackageFullName=($target+'_5.0.0.0_neutral_~_fixture');PackageFamilyName=($target+'_fixture');IsBundle=$true;PackageUserInformation=@([pscustomobject]@{InstallState='Installed'})}
 $script:installed=@($bundleOnly);$script:removed=@();$calls=$script:nativeCalls;$failed=$false
 try{Invoke-SetupDebloat -ModuleRoot $module -ReportPath $report -VerifyOnly|Out-Null}catch{$failed=$true}
 $saved=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
 Assert ($failed -and -not $saved.Success -and $target -in $saved.SelectedRemaining -and $script:nativeCalls -eq $calls -and $script:removed.Count -eq 0) 'VerifyOnly 必須發現只剩 bundle 並拒絕成功'
 $script:installed=@($bundleOnly);$script:removed=@();$script:removeBundleChildren=$false;$failed=$false
 try{Invoke-SetupDebloat -ModuleRoot $module -ReportPath $report|Out-Null}catch{$failed=$true}
 $saved=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
 Assert ($failed -and -not $saved.Success -and $target -in $saved.SelectedRemaining -and $target -notin $saved.RemovedApps) '套用後只剩 bundle 仍失敗且不冒稱已移除'
 $calls=$script:nativeCalls;$script:removed=@();$script:installed=@();$v=Invoke-SetupDebloat -ModuleRoot $module -ReportPath $report -VerifyOnly
 Assert ($v.Success -and $script:nativeCalls -eq $calls -and $script:removed.Count -eq 0 -and $null -eq $v.AdditionalApps) 'VerifyOnly 不呼叫清理或移除'
} finally {
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $fixture).ProviderPath)
 if(-not $resolved.Equals($fixture,[StringComparison]::OrdinalIgnoreCase) -or -not $resolved.StartsWith($ownedTemp+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw '拒絕清理非自有 TEMP fixture'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}foreach($id in @('Microsoft.Copilot','Microsoft.GamingServices','Microsoft.Edge.GameAssist')){
 $script:installed=@((New-Package $id '1.0.0.0' $false));$script:provisioned=@();$script:removed=@();$script:fail=''
 $result=Invoke-SetupDebloatMissingApps -AppIds @($id)
 Assert ($result.Success -and $script:removed.Count -eq 1 -and $script:removed[0] -ceq ('installed:'+$script:installed[0].PackageFullName)) ('三項目標皆以 provider 完整名稱移除 '+$id)
}$first=New-Package 'Microsoft.Copilot' '1.0.0.0' $false
$second=New-Package 'Microsoft.Copilot' '2.0.0.0' $false
$first|Add-Member NoteProperty PackageUserInformation @([pscustomobject]@{UserSecurityId='fixture1';InstallState='Installed'},[pscustomobject]@{UserSecurityId='fixture2';InstallState='Installed'})
$script:installed=@($first,$first,$second);$script:provisioned=@();$script:removed=@();$script:fail='remove_installed'
$result=Invoke-SetupDebloatMissingApps -AppIds @('Microsoft.Copilot')
Assert (-not $result.Success -and $result.Errors.Count -eq 2 -and $script:removed.Count -eq 2) '多使用者與重複實體依完整名稱去重，不同版本失敗均保留'
$bad=[pscustomobject]@{DisplayName='Microsoft.Copilot';PackageName='Microsoft.WindowsStore_1.0.0.0_neutral_~_fixture'}
$script:installed=@();$script:provisioned=@($bad);$script:removed=@();$script:fail=''
$result=Invoke-SetupDebloatMissingApps -AppIds @('Microsoft.Copilot')
Assert (-not $result.Success -and $script:removed.Count -eq 0) '預佈建完整名稱錯配不得移除'