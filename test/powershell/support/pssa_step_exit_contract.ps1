#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $root 'script/test/pssa_safety.ps1')
function Assert([bool]$Passed,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Passed}|ConvertTo-Json -Compress));if(-not $Passed){throw $Name}}
$owner=New-PssaOwnedTemp
$temp=$owner.Path
try {
 $source=Join-Path $temp 'source'
 New-Item -ItemType Directory -Path (Join-Path $source 'modules/native') -Force|Out-Null
 $file=Join-Path $source 'modules/native/managed_source_library.ps1'
 Copy-Item -LiteralPath (Join-Path $root 'modules/native/managed_source_library.ps1') -Destination $file
 $wrapper=Join-Path $temp 'wrapper.ps1'
 $content=@'
$ErrorActionPreference='Stop'
Set-Location $env:PSSA_TEST_ROOT
if ($env:PSSA_PRIOR_EXIT) { $global:LASTEXITCODE=[int]$env:PSSA_PRIOR_EXIT }
.\test\powershell\support\pssa_format_contract.ps1
.\script\test\check_pssa_format.ps1 -SourceRoot $env:PSSA_TEST_SOURCE -PackagePath $env:WINDOWS_SETUP_PSSA_PACKAGE_PATH
if (Test-Path -LiteralPath variable:\LASTEXITCODE) { exit $LASTEXITCODE }
'@
 [IO.File]::WriteAllText($wrapper,$content,(New-Object Text.UTF8Encoding($true)))
 $oldRoot=$env:PSSA_TEST_ROOT;$oldSource=$env:PSSA_TEST_SOURCE;$oldPrior=$env:PSSA_PRIOR_EXIT
 try {
  $env:PSSA_TEST_ROOT=$root;$env:PSSA_TEST_SOURCE=$source;$env:PSSA_PRIOR_EXIT=$null
  function Run-Step {
   $p=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$wrapper+'"')) -RedirectStandardOutput (Join-Path $temp 'step.out') -RedirectStandardError (Join-Path $temp 'step.err') -WindowStyle Hidden -PassThru
   $null=$p.Handle
   if(-not $p.WaitForExit(90000)){$p.Kill();$p.WaitForExit();throw '步驟測試逾時。'}
   return $p.ExitCode
  }
  Assert ((Run-Step) -eq 0) '預期負例後成功步驟保有成功退出碼'
  $env:PSSA_PRIOR_EXIT='37'
  Assert ((Run-Step) -eq 37) '原有非零退出狀態不得被掩蓋'
  $env:PSSA_PRIOR_EXIT=$null
  [IO.File]::AppendAllText($file,"`nfunction Fixture {`n`$x=1`n}`n",(New-Object Text.UTF8Encoding($false)))
  Assert ((Run-Step) -ne 0) '真正來源格式錯誤仍使步驟失敗'
 } finally {$env:PSSA_TEST_ROOT=$oldRoot;$env:PSSA_TEST_SOURCE=$oldSource;$env:PSSA_PRIOR_EXIT=$oldPrior}
} finally {Remove-PssaOwnedTemp -Handle $owner}
