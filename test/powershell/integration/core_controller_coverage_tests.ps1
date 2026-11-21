#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Condition,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Condition}|ConvertTo-Json -Compress));if(-not $Condition){throw $Name}}
$d=Join-Path ([IO.Path]::GetTempPath()) ('core_controller_source_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($d)
$manifest=@{SourceRoot=$root;Sources=@('core/configuration_library.ps1','core/after_restart_library.ps1','core/configure_nuc.ps1','core/configure_setup.ps1','core/verify_after_restart.ps1');Tests=@('test/powershell/integration/configuration_helpers_tests.ps1','test/powershell/integration/after_restart_helpers_tests.ps1','test/powershell/integration/start_pins_controller_tests.ps1');Wrapper='test/powershell/coverage/safe_suite.ps1'}
$path=Join-Path $d 'manifest.json';$manifest|ConvertTo-Json -Depth 4|Set-Content $path -Encoding UTF8
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'script/test/powershell_coverage.ps1') -ManifestPath $path -OutputDirectory (Join-Path $d 'output') *> (Join-Path $d 'private.log')
Assert ($LASTEXITCODE -eq 0) ('主控制器真原始 counter 收集完成 '+$d)
[xml]$xml=Get-Content (Join-Path $d 'output/coverage.xml') -Raw
$classes=@($xml.coverage.packages.package.classes.class)
Assert ($classes.Count -eq 5) '兩個具名主體與三個入口完整保留分母'
foreach($name in @('core/configuration_library.ps1','core/after_restart_library.ps1')){
 $class=@($classes|Where-Object filename -eq $name);$lines=@($class.lines.line);$hit=@($lines|Where-Object hits -eq '1').Count
 Assert ($class.Count -eq 1 -and $lines.Count -gt 0 -and $hit*100 -ge $lines.Count*90) ($name+' 真完整行至少90%：'+$hit+'/'+$lines.Count)
}
# Elevation entry code remains in the denominator and is not mapped from fixture copies.