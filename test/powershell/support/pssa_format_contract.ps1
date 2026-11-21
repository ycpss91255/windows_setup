#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$checker=Join-Path $root 'script/test/check_pssa_format.ps1'
$package=$env:WINDOWS_SETUP_PSSA_PACKAGE_PATH
. (Join-Path $root 'script/test/pssa_safety.ps1')
function Assert([bool]$Passed,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Passed}|ConvertTo-Json -Compress));if(-not $Passed){throw $Name}}
$fixtureOwner=New-PssaOwnedTemp
$temp=$fixtureOwner.Path
New-Item -ItemType Directory -Path (Join-Path $temp 'modules/native') -Force|Out-Null
try{
 $outside=Join-Path $temp 'outside';New-Item -ItemType Directory -Path $outside|Out-Null
 $rejected=$false;try{Remove-PssaOwnedTemp -Handle ([pscustomobject]@{Base=$temp;Path=$outside})}catch{$rejected=$true}
 Assert ($rejected -and (Test-Path -LiteralPath $outside)) '拒絕刪除非自有暫存路徑'
 $owned=New-PssaOwnedTemp;$ownedPath=$owned.Path
 $forged=[pscustomobject]@{Base=$owned.Base;Path=$owned.Path;Token='wrong'};$rejected=$false
 try{Remove-PssaOwnedTemp -Handle $forged}catch{$rejected=$true}
 Assert ($rejected -and (Test-Path -LiteralPath $ownedPath)) '錯誤所有權憑證不得刪除'
 Remove-PssaOwnedTemp -Handle $owned
 Assert (-not (Test-Path -LiteralPath $ownedPath)) '僅刪除已解析的自有暫存目錄'
 $job=Start-Job -ScriptBlock {Start-Sleep -Seconds 20};$id=$job.Id;$timedOut=$false
 try{Receive-PssaBoundedJob -Job $job -TimeoutSeconds 1|Out-Null}catch{$timedOut=$_.Exception.Message -match '逾時'}
 Assert ($timedOut -and -not (Get-Job -Id $id -ErrorAction SilentlyContinue)) '逾時停止並移除本次工作'
 $file=Join-Path $temp 'modules/native/managed_source_library.ps1'
 Copy-Item -LiteralPath (Join-Path $root 'modules/native/managed_source_library.ps1') -Destination $file
 function Check($Archive){
  $old=$ErrorActionPreference
  $previous=Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
  $previousValue=if($null -ne $previous){$previous.Value}else{$null}
  try{
   $ErrorActionPreference='Continue'
   & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker -SourceRoot $temp -PackagePath $Archive *> (Join-Path $temp 'private.log')
   return $LASTEXITCODE
  } finally {
   $ErrorActionPreference=$old
   if($null -eq $previous){Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue}else{$global:LASTEXITCODE=$previousValue}
  }
 }
 Assert ((Check (Join-Path $temp 'missing.zip')) -ne 0) '缺少固定套件拒絕且不回退'
 $bad=Join-Path $temp 'bad.zip';[IO.File]::WriteAllText($bad,'corrupt fixture')
 Assert ((Check $bad) -ne 0) '錯誤 SHA512 的套件拒絕'
 Assert ((Check $package) -eq 0) '受控正確套件可檢查乾淨格式'
 $outside=Join-Path $temp 'modules/native/outside.ps1';[IO.File]::WriteAllText($outside,"if(`$true){`$x=1}`n")
 Assert ((Check $package) -eq 0) '首批只檢查明確列出的檔案'
 [IO.File]::Move($file,($file+'.held'))
 try{Assert ((Check $package) -ne 0) '缺少清單來源不可假綠'}finally{[IO.File]::Move(($file+'.held'),$file)}
 [IO.File]::AppendAllText($file,"`nfunction Fixture {`n`$value=1`n}`n",(New-Object Text.UTF8Encoding($false)))
 Assert ((Check $package) -ne 0) '來源格式真實變異被拒絕'
} finally {Remove-PssaOwnedTemp -Handle $fixtureOwner}