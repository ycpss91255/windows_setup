#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'core/hardware.ps1')
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
$fixture=Join-Path $env:TEMP ('driver_profile_resume_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
$registry=Join-Path $fixture 'drivers';$profileDir=Join-Path $registry 'synthetic_board';[void][IO.Directory]::CreateDirectory($profileDir)
@{SchemaVersion=1;ProfileId='synthetic_board';PackageDirectory='synthetic';Architecture='x64';SupportedBoards=@('SYNTHETIC-BOARD')}|ConvertTo-Json|Set-Content (Join-Path $profileDir 'profile.json') -Encoding UTF8
foreach($entry in @('configure_setup.ps1','verify_after_restart.ps1')){
 $case=Join-Path $fixture ([IO.Path]::GetFileNameWithoutExtension($entry));$source=Join-Path $case 'original';$moved=Join-Path $case 'relocated'
 $script:NucPackageRoot=Join-Path $source 'windows_setup';$DriverPackagePath=Join-Path $source 'windows_driver_packages/synthetic'
 [void][IO.Directory]::CreateDirectory($script:NucPackageRoot);[void][IO.Directory]::CreateDirectory($DriverPackagePath)
 foreach($name in @('package.json','manifest.json')){[IO.File]::WriteAllText((Join-Path $DriverPackagePath $name),'{}')}
 $hardware=Get-SetupHardwareProfile -BoardProduct SYNTHETIC-BOARD -ProfilesRoot $registry -DriverPackagePath $DriverPackagePath
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root ('core/'+$entry)),[ref]$tokens,[ref]$errors)
 $selection=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains('New-SetupDriverSelection')},$true))
 Assert ($errors.Count -eq 0 -and $selection.Count -eq 1) ('正式入口有唯一保存選擇路由 '+$entry)
 # Execute the actual selection statement without source replacement; no elevation or system modules.
 . ([scriptblock]::Create($selection[0].Extent.Text))
 Assert ($null -ne $hardware.DriverSelection -and $hardware.DriverSelection.RelativePath -and -not $hardware.IsNuc8) ('第二profile保留雜湊及相對續跑位置 '+$entry)
 $result=Join-Path $case 'result.json';@{Computer=$env:COMPUTERNAME;UserSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;HardwareProfile=$hardware}|ConvertTo-Json -Depth 6|Set-Content $result -Encoding UTF8
 foreach($path in @($source,$moved)){if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)) -cne [IO.Path]::GetFullPath($case)){throw 'fixture move outside case'}}
 Move-Item -LiteralPath $source -Destination $moved
 $letter=@([char[]](90..68)|Where-Object {-not(Get-PSDrive -Name ([string]$_) -ErrorAction SilentlyContinue)})[0];if(-not $letter){throw 'no temporary PSDrive letter'}
 $drive=New-PSDrive -Name ([string]$letter) -PSProvider FileSystem -Root $moved
 try{
  $relocatedRoot=([string]$letter)+':\windows_setup'
  $selected=Get-SetupSavedDriverSelection -ResultPath $result -PackageRoot $relocatedRoot
  Assert ($selected -eq (Join-Path $moved 'windows_driver_packages/synthetic')) ('包移動並由另一個磁碟代號仍依相對位置找到 '+$entry)
  Assert (-not(Get-SetupSavedDriverSelection -ResultPath $result -PackageRoot $relocatedRoot -UserSID 'foreign')) ('不同帳號不取用續跑包 '+$entry)
  [IO.File]::AppendAllText((Join-Path $selected 'manifest.json'),'tampered')
  $rejected=$false;try{Get-SetupSavedDriverSelection -ResultPath $result -PackageRoot $relocatedRoot|Out-Null}catch{$rejected=$_.Exception.Message -like '驅動包身分與原選擇不同*'}
  Assert $rejected ('移動後仍拒絕manifest雜湊改動 '+$entry)
 }finally{Remove-PSDrive -Name ([string]$letter)}
}
