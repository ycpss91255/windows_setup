#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'hardware.ps1')
$script:NucPackageRoot=Split-Path -Parent $PSScriptRoot
$script:NucPathMap=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'paths.json'))|ConvertFrom-Json
# 重開後自動驗收使用本機保存的 runtime；報告寫在本機，清除 runtime 時保留。
function Get-SetupResumePaths {
 param([string]$CommonDataRoot=$env:ProgramData)
 $base=Join-Path ([IO.Path]::GetFullPath($CommonDataRoot)) 'NUC8-Setup'
 $root=Join-Path $base 'resume'
 [pscustomobject]@{Base=$base;Root=$root;Runtime=(Join-Path $root 'runtime');Driver=(Join-Path $root 'driver');Manifest=(Join-Path $root 'manifest.json');Attempts=(Join-Path $root 'attempts.json');Reports=(Join-Path $base 'reports')}
}
function Test-SetupResumeRuntime {
 param([string]$PackageRoot=$script:NucPackageRoot)
 return [string]::Equals([IO.Path]::GetFullPath($PackageRoot).TrimEnd('\'),(Get-SetupResumePaths).Runtime.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)
}
function Get-SetupReportRoot {
 if(Test-SetupResumeRuntime){return (Get-SetupResumePaths).Reports}
 return Join-Path $script:NucPackageRoot 'reports'
}
function Resolve-SetupPath {
 param([Parameter(Mandatory=$true)][string]$Name)
 $normalized=$Name.Replace('\','/')
 foreach($property in $script:NucPathMap.PSObject.Properties){
  $key=$property.Name.Replace('\','/')
  if($normalized -eq $key){return Join-Path $script:NucPackageRoot $property.Value}
  if($key -in @('CustomHostsSync','Win11Debloat') -and $normalized.StartsWith($key+'/',[StringComparison]::OrdinalIgnoreCase)){
   return Join-Path (Join-Path $script:NucPackageRoot $property.Value) $normalized.Substring($key.Length+1)
  }
 }
 if($normalized -match '[/\\]' -or $normalized -match '\.(ps1|cmd|exe)$'){throw ('未登錄的套件路徑：'+$Name)}
 return Join-Path (Get-SetupReportRoot) $Name
}
function Initialize-SetupReports {
 $path=Get-SetupReportRoot
 if(-not(Test-Path -LiteralPath $path)){New-Item -ItemType Directory -Path $path|Out-Null}
}

# 舊版本續跑記錄中的模組識別仍可解析；輸出統一使用新檔名。
function Resolve-SetupModuleName {
 param([Parameter(Mandatory=$true)][string]$Name)
 foreach($property in $script:NucPathMap.PSObject.Properties){
  if($property.Name -eq $Name -and $property.Value -match '\.ps1$'){return [IO.Path]::GetFileName($property.Value)}
 }
 return $Name
}
function Resolve-NucPath {
 param([Parameter(Mandatory=$true)][string]$Name)
 Resolve-SetupPath -Name $Name
}
function Initialize-NucReports {
 Initialize-SetupReports
}
function Resolve-NucModuleName {
 param([Parameter(Mandatory=$true)][string]$Name)
 Resolve-SetupModuleName -Name $Name
}
