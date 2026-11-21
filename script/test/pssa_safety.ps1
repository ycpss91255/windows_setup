#Requires -Version 5.1
$script:PssaOwnedTemps=@{}
function New-PssaOwnedTemp {
 $base=(Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).ProviderPath
 $base=[IO.Path]::GetFullPath($base).TrimEnd('\','/')
 if((Get-Item -LiteralPath $base -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '暫存根目錄不可為重新解析點。'}
 $path=Join-Path $base ('pssa_format_'+[guid]::NewGuid().ToString('N'))
 $item=New-Item -ItemType Directory -Path $path -ErrorAction Stop
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $path -ErrorAction Stop).ProviderPath).TrimEnd('\','/')
 if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $resolved -ine $path){throw '新暫存目錄解析不符。'}
 $token=[guid]::NewGuid().ToString('N')
 $script:PssaOwnedTemps[$path]=$token
 return [pscustomobject]@{Base=$base;Path=$path;Token=$token}
}
function Remove-PssaOwnedTemp {
 param([Parameter(Mandatory=$true)]$Handle)
 $base=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).ProviderPath).TrimEnd('\','/')
 $path=[IO.Path]::GetFullPath([string]$Handle.Path)
 if($base -ine [string]$Handle.Base -or (Get-Item -LiteralPath $base -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '暫存根目錄不符。'}
 if(-not $script:PssaOwnedTemps.ContainsKey($path) -or $script:PssaOwnedTemps[$path] -cne [string]$Handle.Token){throw '暫存目錄所有權不符。'}
 if([IO.Path]::GetDirectoryName($path) -ine $base -or [IO.Path]::GetFileName($path) -cnotmatch '^pssa_format_[a-f0-9]{32}$'){throw '暫存目錄不屬於本次檢查。'}
 $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $path -ErrorAction Stop).ProviderPath).TrimEnd('\','/')
 if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $resolved -ine $path){throw '暫存目錄解析不符。'}
 Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
 [void]$script:PssaOwnedTemps.Remove($path)
}
function Receive-PssaBoundedJob {
 param([Parameter(Mandatory=$true)]$Job,[ValidateRange(1,60)][int]$TimeoutSeconds=60)
 try{
  if(-not (Wait-Job -Job $Job -Timeout $TimeoutSeconds)){throw '格式檢查逾時。'}
  if($Job.State -ne 'Completed'){throw '格式檢查程序失敗。'}
  Receive-Job -Job $Job -ErrorAction Stop
 } finally {
  if($Job.State -in @('Running','NotStarted')){Stop-Job -Job $Job -ErrorAction SilentlyContinue}
  Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
 }
}