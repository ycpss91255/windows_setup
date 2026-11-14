. (Join-Path $PSScriptRoot '../report/repo_coverage.ps1')
#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'go_coverage.ps1')
function Protect-ReportText([string]$Text){
 foreach($value in @($env:USERPROFILE,$env:TEMP,$env:TMP,$env:GITHUB_WORKSPACE)|Where-Object {$_}){$Text=$Text.Replace($value,'[local]')}
 $Text=[regex]::Replace($Text,'(?i)[A-Z]:[\\/][^\r\n|]*','[local path]')
 return $Text.Replace("`r",' ').Replace("`n",' ')
}
function Assert-TestReportSnapshot {
 param([Parameter(Mandatory=$true)]$Report,[switch]$Release)
 foreach($key in @('SchemaVersion','Version','Commit','RequestedLayer','MeasuredAt','SourceState','RefType','RefName','Environment','Checks','Success','Coverage','Changes','Totals','RunUrl')){if($key -notin $Report.PSObject.Properties.Name){throw ('報表缺少必要欄位：'+$key)}}
 if($Report.SchemaVersion -notin @(1,2) -or $Report.RequestedLayer -notin @('All','Unit','Integration') -or $Report.SourceState -notin @('Clean','Dirty','Unknown') -or $Report.RefType -notin @('Branch','Release') -or $Report.Coverage -notin @('NotMeasured','Measured')){throw '不支援的報表結構或範圍。'}
 if($Report.SchemaVersion -eq 1){if($Report.ComparisonStatus -ne 'Unknown' -or $Report.FlakyStatus -ne 'Unknown'){throw '歷史報表結構不符。'}}
 elseif($Report.PSObject.Properties['ComparisonStatus'] -or $Report.PSObject.Properties['FlakyStatus']){throw '新報表不可包含已移除的比較占位。'}
 $allowedLayers=if($Report.SchemaVersion -eq 1){@('Static','Unit','Integration','System','System E2E')}else{@('Static','Unit','Integration')}
 $stamp=[DateTimeOffset]::MinValue
 if(-not [DateTimeOffset]::TryParse([string]$Report.MeasuredAt,[ref]$stamp)){throw '報表量測時間不合法。'}
 if(-not @($Report.Checks).Count -or $Report.Success -isnot [bool]){throw '報表沒有有效測試結果。'}
 if($Report.RequestedLayer -eq 'All'){foreach($layer in @('Unit','Integration')){if(-not @($Report.Checks|Where-Object {$_.Layer -eq $layer -and $_.Executed}).Count){throw ('完整範圍缺少已執行層級：'+$layer)}}}
 if(@($Report.Checks.Name|Select-Object -Unique).Count -ne @($Report.Checks).Count){throw '報表測試識別重複。'}
 if($Report.RequestedLayer -ne 'All' -and -not @($Report.Checks|Where-Object {$_.Layer -eq $Report.RequestedLayer -and $_.Executed}).Count){throw '所選層級未執行，不能宣稱通過。'}
 foreach($check in $Report.Checks){
  if($check.Executed -and $check.Passed -isnot [bool]){throw '通過欄位必須是布林值，不能由 null 或字串轉換。'}
  if($check.Executed -and ($check.ExitCode -isnot [int] -and $check.ExitCode -isnot [long])){throw '已執行項目缺少整數退出碼。'}
  if(($check.Status -eq 'Passed' -and $check.ExitCode -ne 0) -or ($check.Status -eq 'Failed' -and $check.ExitCode -eq 0) -or ($check.Status -eq 'NotRun' -and $null -ne $check.ExitCode)){throw '退出碼與狀態矛盾。'}
  if($check.Name -isnot [string] -or $check.Layer -notin $allowedLayers -or $check.Status -notin @('Passed','Failed','NotRun') -or $check.Executed -isnot [bool]){throw '報表測試狀態格式錯誤。'}
  if(($check.Status -eq 'Passed' -and (-not $check.Executed -or $check.Passed -cne $true)) -or ($check.Status -eq 'Failed' -and (-not $check.Executed -or $check.Passed -cne $false)) -or ($check.Status -eq 'NotRun' -and ($check.Executed -or $null -ne $check.Passed))){throw '報表執行與通過狀態矛盾。'}
  if($check.Layer -like 'System*' -and $check.Status -ne 'NotRun'){throw '此報表格式不接受未實作的 System 成功聲明。'}
  if($check.Status -eq 'NotRun' -and @($check.Assertions).Count){throw '未執行項目不得攜帶已執行斷言。'}
  foreach($assertion in @($check.Assertions)){if($assertion.Name -isnot [string] -or $assertion.Passed -isnot [bool]){throw '斷言資料不合法。'}}
  if($check.Status -eq 'Passed' -and $check.Layer -in @('Unit','Integration') -and (-not @($check.Assertions).Count -or @($check.Assertions|Where-Object {-not $_.Passed}).Count)){throw '通過的測試缺少完整成功斷言。'}
 }
 if($Report.PSObject.Properties['RepoCoverage']){Assert-RepoCoverage $Report.RepoCoverage $Report;$expected=if($Report.RepoCoverage.Result.Complete){'Measured'}else{'NotMeasured'};if($Report.Coverage -cne $expected){throw '覆蓋率量測狀態不一致。'}}elseif($Report.Coverage -cne 'NotMeasured'){throw '缺少整體覆蓋率證據。'}
 if($Report.PSObject.Properties['GoCoverage']){Assert-GoCoverage -Coverage $Report.GoCoverage -Report $Report}
 $allAssertions=@($Report.Checks|ForEach-Object {$_.Assertions})
 $expected=@{SuitesExecuted=@($Report.Checks|Where-Object Executed).Count;AssertionsExecuted=$allAssertions.Count;AssertionsPassed=@($allAssertions|Where-Object Passed).Count;AssertionsFailed=@($allAssertions|Where-Object {-not $_.Passed}).Count;UnexecutedSuites=@($Report.Checks|Where-Object {-not $_.Executed}).Count}
 foreach($key in $expected.Keys){if($key -notin $Report.Totals.PSObject.Properties.Name -or $Report.Totals.$key -ne $expected[$key]){throw ('報表統計不一致：'+$key)}}
 $success=@($Report.Checks|Where-Object {$_.Executed -and -not $_.Passed}).Count -eq 0
 if($Report.Success -cne $success){throw '報表總結果與細項不一致。'}
 if($Release -or $Report.RefType -eq 'Release'){
  if($Report.Version -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?$' -or $Report.RefName -cne $Report.Version -or $Report.Commit -notmatch '^[a-fA-F0-9]{40}$' -or $Report.SourceState -ne 'Clean' -or $Report.RequestedLayer -ne 'All' -or $Report.Environment -eq 'Unknown' -or -not $Report.Success -or $Report.RunUrl -notmatch '^https://github.com/[^/]+/[^/]+/actions/runs/[0-9]+$'){throw '版本快照缺少乾淨來源、完整成功測試或提交執行身分。'}
 }
}
function Write-TestReports {
 param([Parameter(Mandatory=$true)][object[]]$Checks,[Parameter(Mandatory=$true)][string]$OutputDirectory,[string]$Layer='All',[string]$Commit=$env:GITHUB_SHA,[string]$RunUrl,[ValidateSet('Clean','Dirty','Unknown')][string]$SourceState='Unknown',[string]$Version='Unknown',[string]$Environment='Unknown',[ValidateSet('Branch','Release')][string]$RefType='Branch',[string]$RefName='Unknown',[string]$MeasuredAt=([DateTime]::UtcNow.ToString('o')),[string[]]$Changes=@(),$GoCoverage,$RepoCoverage,[ValidateSet(1,2)][int]$SchemaVersion=2,[switch]$OmitGoProfileLink,[switch]$LegacyPresentation)
 $encoding=[Text.UTF8Encoding]::new($false)
 New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
 $safe=@(foreach($check in $Checks){
  $assertions=@(foreach($item in @($check.Assertions)){if($null -ne $item){[pscustomobject]@{Name=(Protect-ReportText $item.Name);Passed=$item.Passed}}})
  [pscustomobject]@{Name=(Protect-ReportText $check.Name);Layer=$check.Layer;Status=$check.Status;Executed=$check.Executed;Passed=$check.Passed;ExitCode=$check.ExitCode;DurationSeconds=[double]$check.DurationSeconds;Assertions=$assertions}
 })
 $ok=@($safe|Where-Object {$_.Executed -and -not $_.Passed}).Count -eq 0
 $report=[ordered]@{SchemaVersion=$SchemaVersion;Version=(Protect-ReportText $Version);Environment=(Protect-ReportText $Environment);RefType=$RefType;RefName=(Protect-ReportText $RefName);MeasuredAt=$MeasuredAt;Changes=@($Changes|Select-Object -First 20|ForEach-Object {Protect-ReportText $_});Success=$ok;Scope='Static, unit and isolated integration tests';RequestedLayer=$Layer;SourceState=$SourceState;Commit=$(if($Commit -match '^[a-fA-F0-9]{40}$'){$Commit}else{'local-unversioned'});RunUrl=$(if($RunUrl -match '^https://github.com/[^/]+/[^/]+/actions/runs/[0-9]+$'){$RunUrl}else{''});GeneratedAt=$MeasuredAt;Coverage='NotMeasured';Checks=$safe}
 if($SchemaVersion -eq 1){$report.ComparisonStatus='Unknown';$report.FlakyStatus='Unknown'}
 if($null -ne $GoCoverage){$report.GoCoverage=$GoCoverage}
 if($null -ne $RepoCoverage){$report.RepoCoverage=$RepoCoverage;if($RepoCoverage.Result.Complete){$report.Coverage='Measured'}}
 $allAssertions=@($safe|ForEach-Object {$_.Assertions})
 $report.Totals=[pscustomobject]@{SuitesExecuted=@($safe|Where-Object Executed).Count;AssertionsExecuted=$allAssertions.Count;AssertionsPassed=@($allAssertions|Where-Object Passed).Count;AssertionsFailed=@($allAssertions|Where-Object {-not $_.Passed}).Count;UnexecutedSuites=@($safe|Where-Object {-not $_.Executed}).Count}
 Assert-TestReportSnapshot -Report ([pscustomobject]$report)
 [IO.File]::WriteAllText((Join-Path $OutputDirectory 'summary.json'),($report|ConvertTo-Json -Depth 10),$encoding)
 $display=@($safe|Where-Object {$_.Layer -in @('Static','Unit','Integration')})
 $conclusion=if(-not $ok){'本次測試未通過'}elseif($Layer -ne 'All'){'所選測試層級通過'}else{'單元與隔離整合測試通過'}
 $versionText=if($report.Version -eq 'Unknown'){'未指定版本'}else{$report.Version}
 $environmentText=if($report.Environment -eq 'Unknown'){'未提供環境'}else{$report.Environment}
 $sourceText=if($SourceState -eq 'Unknown'){'未提供來源狀態'}else{$SourceState}
 $refText=if($report.RefName -eq 'Unknown'){'本機執行'}else{$report.RefName}
 $md=@('# Windows 測試結果','',('**'+$conclusion+'**'),'',('版本：'+$versionText+' · '+$RefType+' / '+$refText),('提交：'+$report.Commit),('量測時間（UTC）：'+$MeasuredAt),('環境：'+$environmentText+' · '+$sourceText),'',('斷言：'+$report.Totals.AssertionsPassed+'/'+$report.Totals.AssertionsExecuted+'；失敗 '+$report.Totals.AssertionsFailed),'','| 層級 | 測試套件 | 狀態 | 通過／執行斷言 | 秒 |','| --- | --- | --- | --- | --- |')
 foreach($check in $display){$passed=@($check.Assertions|Where-Object Passed).Count;$md+='| '+$check.Layer+' | '+$check.Name.Replace('|','/')+' | '+$check.Status+' | '+$passed+'/'+$check.Assertions.Count+' | '+$check.DurationSeconds+' |'}
 $coverageHeading=if((Get-RepoCoverageScopeLabel $RepoCoverage) -eq 'PowerShell/C# runtime'){'PowerShell/C# runtime 覆蓋率'}else{'整體覆蓋率'}
 $mdHeading=if($coverageHeading -eq '整體覆蓋率'){'整體程式碼覆蓋率'}else{$coverageHeading}
 $md+=@('',($mdHeading+'：'+(Get-RepoCoverageSummary $RepoCoverage)))
 $md+=@(Get-RepoCoverageLanguages $RepoCoverage)
 if($null -ne $GoCoverage){$md+=@('',('Go 程式敘述覆蓋率（分項）：'+(Get-GoCoveragePercentText $GoCoverage)+'；'+$GoCoverage.Covered+'/'+$GoCoverage.TotalStatements+' statements；全部自有 Go 工具含 CLI，不含 PowerShell 或第三方程式，不等於整體覆蓋率。'))}
 if($report.RunUrl){$md+=@('',('[GitHub Actions 執行紀錄]('+$report.RunUrl+')'))}
 [IO.File]::WriteAllText((Join-Path $OutputDirectory 'summary.md'),($md -join "`n"),$encoding)
 $body='<h1>Windows 設定工具｜測試結果</h1><h2>'+[Net.WebUtility]::HtmlEncode($conclusion)+'</h2>'
 $scopeText=if($RefType -eq 'Release'){'版本 '+$versionText}else{'分支 '+$refText}
 $body+='<p>'+[Net.WebUtility]::HtmlEncode($scopeText)+' · 提交 <code>'+[Net.WebUtility]::HtmlEncode($report.Commit)+'</code><br>量測時間（UTC）：'+[Net.WebUtility]::HtmlEncode($MeasuredAt)+'</p>'
 $body+='<p>斷言通過 '+$report.Totals.AssertionsPassed+' / '+$report.Totals.AssertionsExecuted+' · 失敗 '+$report.Totals.AssertionsFailed+'</p><p><a href="https://github.com/ycpss91255/windows_setup/blob/main/readme.md">USB 安裝與使用步驟</a>'
 if($report.RunUrl){$body+=' · <a href="'+$report.RunUrl+'">GitHub Actions 執行紀錄</a>'};$body+='</p>'
 if($RefType -eq 'Release'){$body+='<p><a href="https://github.com/ycpss91255/windows_setup/releases/tag/'+$versionText+'">Release 下載與版本說明</a></p>'}
 elseif($report.Commit -match '^[a-fA-F0-9]{40}$'){$body+='<p><a href="https://github.com/ycpss91255/windows_setup/archive/'+$report.Commit+'.zip">下載本次提交原始碼</a>（依 README 準備必要資產）</p>'}
 $body+='<p><a href="summary.json">JSON 證據</a> · <a href="junit.xml">JUnit 結果</a> · <a href="summary.md">文字摘要</a></p><h2>'+[Net.WebUtility]::HtmlEncode($coverageHeading)+'</h2><p>'+[Net.WebUtility]::HtmlEncode((Get-RepoCoverageSummary $RepoCoverage))+'</p>'
 if($null -ne $RepoCoverage){$body+='<details><summary>語言分項</summary><ul>';foreach($line in @(Get-RepoCoverageLanguages $RepoCoverage)){$body+='<li>'+[Net.WebUtility]::HtmlEncode($line)+'</li>'};$body+='</ul><a href="repo_coverage.json">整體量測證據</a> · <a href="coverage_inventory.json">來源清單</a> · <a href="coverage.xml">逐行結果</a></details>'}
 if($null -ne $GoCoverage){
  $profileLink=if($OmitGoProfileLink){''}else{' · <a href="go_coverage.out">原始 Go 覆蓋率</a>'}
  $body+='<details><summary>分項量測明細</summary><p>Go 程式敘述覆蓋率：'+(Get-GoCoveragePercentText $GoCoverage)+' · '+$GoCoverage.Covered+'/'+$GoCoverage.TotalStatements+' statements；範圍為全部自有 Go 工具（含 CLI），不含 PowerShell 或第三方程式，不等於整體覆蓋率。</p><p><a href="go_coverage.json">Go 量測資料</a>'+$profileLink+'</p></details>'
  Write-GoCoverageView -Coverage $GoCoverage -RefType $RefType -OutputDirectory $OutputDirectory
 }
 $body+='<h2>測試明細</h2>'
 $orderedDisplay=if($LegacyPresentation){$display}else{@($display|Sort-Object @{Expression={if($_.Status -eq "Failed"){0}elseif($_.Status -eq "NotRun"){1}else{2}}})}
 foreach($check in $orderedDisplay){$body+='<details><summary>'+[Net.WebUtility]::HtmlEncode($check.Layer+' · '+$check.Name+' · '+$check.Status)+'</summary><p>'+[Net.WebUtility]::HtmlEncode([string]$check.DurationSeconds)+' 秒</p><ul>';foreach($assertion in $check.Assertions){$body+='<li>'+$(if($assertion.Passed){'PASS'}else{'FAIL'})+' · '+[Net.WebUtility]::HtmlEncode($assertion.Name)+'</li>'};$body+='</ul></details>'}
 $body+='<details><summary>環境與來源</summary><p>'+[Net.WebUtility]::HtmlEncode($environmentText+' / '+$sourceText)+'</p></details>'
 if($LegacyPresentation){
 $html='<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Windows 測試結果</title><style>body{font:16px/1.6 system-ui;max-width:960px;margin:32px auto;padding:0 20px;color:#17202a;background:#f7f9fb}details{background:white;padding:16px;margin:16px 0;border:1px solid #dde3ea;border-radius:8px}li{margin:5px 0}code{overflow-wrap:anywhere}</style><body>'+$body+'</body></html>'
 }else{
  $templatePath=Join-Path $PSScriptRoot 'report_bundle_tool/overview.html'
  $template=[IO.File]::ReadAllText($templatePath,[Text.Encoding]::UTF8).TrimStart([char]0xfeff)
  $html=$template.Replace('{{TITLE}}','Windows 測試結果').Replace('{{BODY}}',$body)
 }
 [IO.File]::WriteAllText((Join-Path $OutputDirectory 'index.html'),$html,$encoding)
 $xml=New-Object Xml.XmlDocument;$tests=$xml.CreateElement('testsuites');[void]$xml.AppendChild($tests)
 foreach($check in $safe){
  $suite=$xml.CreateElement('testsuite');$suite.SetAttribute('name',$check.Name);$suite.SetAttribute('time',[string]$check.DurationSeconds);[void]$tests.AppendChild($suite)
  $items=@($check.Assertions);if(-not $items.Count){$items=@([pscustomobject]@{Name=$check.Name;Passed=$check.Passed})}
  if($check.Executed -and -not $check.Passed -and @($items|Where-Object {-not $_.Passed}).Count -eq 0){$items+=@([pscustomobject]@{Name='套件執行／報表儀器失敗';Passed=$false})}
  foreach($item in $items){$case=$xml.CreateElement('testcase');$case.SetAttribute('name',$item.Name);$case.SetAttribute('classname',$check.Layer);[void]$suite.AppendChild($case);if(-not $check.Executed){[void]$case.AppendChild($xml.CreateElement('skipped'))}elseif(-not $item.Passed){[void]$case.AppendChild($xml.CreateElement('failure'))}}
  $suite.SetAttribute('tests',[string]$items.Count);$suite.SetAttribute('failures',[string]@($suite.SelectNodes('testcase/failure')).Count);$suite.SetAttribute('skipped',[string]@($suite.SelectNodes('testcase/skipped')).Count)
 }
 $xml.Save((Join-Path $OutputDirectory 'junit.xml'))
 $badges=if($SchemaVersion -eq 1){@('unit','integration','system','coverage')}else{@('unit','integration','coverage')}
 foreach($badge in $badges){
  $label=$badge+' '+$RefType.ToLowerInvariant();$color='#9f9f9f';$status='not measured'
  if($badge -in @('unit','integration')){$rows=@($safe|Where-Object {$_.Layer -eq $badge -and $_.Executed});$status=if(-not $rows.Count){'not run'}elseif(@($rows|Where-Object {-not $_.Passed}).Count){'failed'}else{'passed'};$color=if($status -eq 'passed'){'#4c1'}elseif($status -eq 'failed'){'#e05d44'}else{'#9f9f9f'}}
  if($badge -eq 'system'){$status='not run'}
  if($badge -eq 'coverage'){$label=if($SchemaVersion -eq 1){'ps coverage'}elseif($null -ne $RepoCoverage -and $RepoCoverage.SchemaVersion -eq 2){'runtime PowerShell/C#'}else{'coverage'};if($null -ne $RepoCoverage -and $RepoCoverage.Result.Complete){$status=Get-RepoCoveragePercentText $RepoCoverage;$color='#007ec6'}}
  $scopeLabel=if($badge -eq 'coverage'){$label+' '+$RefType.ToLowerInvariant()}else{$label}
  $title=[Security.SecurityElement]::Escape($scopeLabel+': '+$status)
  $labelWidth=$label.Length*7+12;$valueWidth=$status.Length*7+12;$width=$labelWidth+$valueWidth
  $labelX=[Math]::Floor($labelWidth/2);$valueX=$labelWidth+[Math]::Floor($valueWidth/2)
  $svg='<svg xmlns="http://www.w3.org/2000/svg" width="'+$width+'" height="20" role="img" aria-label="'+$title+'"><title>'+$title+'</title><rect width="'+$labelWidth+'" height="20" fill="#555"/><rect x="'+$labelWidth+'" width="'+$valueWidth+'" height="20" fill="'+$color+'"/><g fill="#fff" font-family="DejaVu Sans,Verdana,Geneva,sans-serif" font-size="11" text-anchor="middle"><text x="'+$labelX+'" y="14">'+$label+'</text><text x="'+$valueX+'" y="14">'+$status+'</text></g></svg>'
  if($badge -eq 'coverage'){$svg=New-CoverageBadgeSvg -Label $label -Value $status -Color $color -Scope $RefType.ToLowerInvariant()}
  [IO.File]::WriteAllText((Join-Path $OutputDirectory ($badge+'.svg')),$svg,$encoding)
 }
 return [pscustomobject]$report
}
