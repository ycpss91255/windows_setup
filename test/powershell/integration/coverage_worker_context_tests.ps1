#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Assert([bool]$Value,[string]$Name){Write-Host ('@@ASSERT@@'+(@{Name=$Name;Passed=$Value}|ConvertTo-Json -Compress));if(-not $Value){throw $Name}}
$fixture=Join-Path $env:TEMP ('worker_context_'+[guid]::NewGuid().ToString('N'))
foreach($dir in @('core','test/powershell/unit','test/powershell/coverage')){[void][IO.Directory]::CreateDirectory((Join-Path $fixture $dir))}
$utf8=[Text.UTF8Encoding]::new($true)
$suite='test/powershell/unit/context_tests.ps1';$wrapper='test/powershell/coverage/safe_suite.ps1'
[IO.File]::WriteAllText((Join-Path $fixture 'core/example.ps1'),"function NativeContextValue {return 7}`n",$utf8)
[IO.File]::WriteAllText((Join-Path $fixture $suite),". (Join-Path ([IO.Path]::GetFullPath((Join-Path `$PSScriptRoot '../../..'))) 'core/example.ps1');if((NativeContextValue) -ne 7){throw 'wrong actual test'}`n",$utf8)
Copy-Item -LiteralPath (Join-Path $root $wrapper) -Destination (Join-Path $fixture $wrapper)
$context=[ordered]@{Commit=('a'*40);RunUrl='https://github.com/example/repo/actions/runs/123';RunAttempt=2;ShardIndex=1;ShardCount=2;GlobalIndices=@(3)}
$manifest=[ordered]@{SourceRoot=$fixture;Sources=@('core/example.ps1');Tests=@($suite);TestEngines=@{};Wrapper=$wrapper;ShardContext=$context}
$input=Join-Path $fixture 'manifest.json';[IO.File]::WriteAllText($input,($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$output=Join-Path $fixture 'proof'
& (Join-Path $root 'script/test/powershell_coverage.ps1') -ManifestPath $input -OutputDirectory $output *> (Join-Path $fixture 'private.log')
Assert ($LASTEXITCODE -eq 0) '原生Pester worker確實執行該suite成功'
$worker=Get-Content -LiteralPath (Join-Path $output 'worker_0.json') -Raw -Encoding UTF8|ConvertFrom-Json
$timingPath=Join-Path $output 'worker_0.timing.json'
Assert (Test-Path -LiteralPath $timingPath -PathType Leaf) '成功 worker 必須產生獨立計時收據'
$timing=Get-Content -LiteralPath $timingPath -Raw -Encoding UTF8|ConvertFrom-Json
Assert ($timing.Context.Commit -ceq $context.Commit -and $timing.Context.RunUrl -ceq $context.RunUrl -and $timing.Context.RunAttempt -eq 2 -and $timing.Context.GlobalIndex -eq 3 -and $timing.Context.TestFile -ceq $suite -and $timing.Context.TestSHA256 -ceq $worker.Context.TestSHA256) '計時收據必須綁定實際 suite 與來源執行身分'
Assert (@($timing.Phases).Count -eq 3 -and @($timing.Phases|Where-Object {$_.Name -cin @('worker_setup','pester_instrumentation_and_test','serialization') -and $_.Milliseconds -ge 0}).Count -eq 3) '收據必須包含可觀測的三個非負階段，不虛構 Pester 內部分界'
Assert ($null -ne $worker.Context) '原始worker必須親自記錄測試與runcontext，不可由pack貼標'
Assert ($worker.Context.TestFile -ceq $suite -and $worker.Context.TestSHA256 -ceq (Get-FileHash (Join-Path $fixture $suite)).Hash.ToLowerInvariant()) '實際執行suite與當場SHA綁在原始worker內'
Assert ($worker.Context.WrapperFile -ceq $wrapper -and $worker.Context.WrapperSHA256 -ceq (Get-FileHash (Join-Path $fixture $wrapper)).Hash.ToLowerInvariant()) '實際Pester wrapper來源與當場SHA不能替換'
Assert ($worker.Context.Commit -ceq $context.Commit -and $worker.Context.RunUrl -ceq $context.RunUrl -and $worker.Context.RunAttempt -eq 2 -and $worker.Context.GlobalIndex -eq 3 -and $worker.Context.ShardIndex -eq 1 -and $worker.Context.ShardCount -eq 2 -and $worker.Context.ProcessId -eq $worker.ProcessId) '原始程序身分與commit/run/attempt/分片globalindex完整保存'
$suiteText=[IO.File]::ReadAllText((Join-Path $fixture $suite));$wrapperText=[IO.File]::ReadAllText((Join-Path $fixture $wrapper))
foreach($case in @('missing_indices','string_attempt','bad_commit','bad_url','bad_count','wrong_assignment','extra_field','suite_changed','wrapper_changed')){
 $bad=$manifest|ConvertTo-Json -Depth 8|ConvertFrom-Json
 switch($case){
  missing_indices{$bad.ShardContext.GlobalIndices=@()}
  string_attempt{$bad.ShardContext.RunAttempt='2'}
  bad_commit{$bad.ShardContext.Commit='unknown'}
  bad_url{$bad.ShardContext.RunUrl='https://example.invalid/private'}
  bad_count{$bad.ShardContext.ShardCount=5}
  wrong_assignment{$bad.ShardContext.GlobalIndices=@(2)}
  extra_field{$bad.ShardContext|Add-Member Unexpected 'hidden'}
  suite_changed{[IO.File]::AppendAllText((Join-Path $fixture $suite),"[IO.File]::AppendAllText(`$PSCommandPath,'# changed')",$utf8)}
  wrapper_changed{[IO.File]::AppendAllText((Join-Path $fixture $suite),"[IO.File]::AppendAllText((Join-Path ([IO.Path]::GetFullPath((Join-Path `$PSScriptRoot '../../..'))) '$wrapper'),'# changed')",$utf8)}
 }
 $badInput=Join-Path $fixture ($case+'.json');[IO.File]::WriteAllText($badInput,($bad|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
 $badOutput=Join-Path $fixture $case
 $exitCode=0
 try{& (Join-Path $root 'script/test/powershell_coverage.ps1') -ManifestPath $badInput -OutputDirectory $badOutput *> (Join-Path $fixture ($case+'.private.log'))}catch{$exitCode=1}
 Assert ($exitCode -ne 0 -and -not(Test-Path (Join-Path $badOutput 'evidence.json')) -and -not(Test-Path (Join-Path $badOutput 'worker_0.json'))) ('錯誤執行context或執行中來源變更不能產成功證據：'+$case)
 [IO.File]::WriteAllText((Join-Path $fixture $suite),$suiteText,$utf8);[IO.File]::WriteAllText((Join-Path $fixture $wrapper),$wrapperText,$utf8)
}
$global:LASTEXITCODE=0
