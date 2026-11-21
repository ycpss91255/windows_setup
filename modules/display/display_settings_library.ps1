#Requires -Version 5.1
# Definitions only; native calls and current-user preferences run only in the named leaf.
function Invoke-SetupDisplaySettings {
 param([Parameter(Mandatory=$true)][string]$ModuleRoot,[switch]$VerifyOnly)
 $ErrorActionPreference='Stop'
 if(-not ('WindowsSetupDisplay.Display' -as [type])){Add-Type -Path (Join-Path $ModuleRoot 'native/display.cs')}
 $desktop='HKCU:\Control Panel\Desktop'
 if($VerifyOnly){
  $actual=[WindowsSetupDisplay.Display]::ReadSnapshot()
  $scales=@($actual|Select-Object -Skip 2)
  if(-not $scales.Count){throw 'No active display source.'}
  $uniform=@($scales|Where-Object {$_ -ne $scales[0]}).Count -eq 0
  $legacyDpi=$null;$legacyScale=$null
  if($uniform){$legacyScale=$scales[0];$legacyDpi=$legacyScale*96/100}
  $custom=(Get-ItemProperty $desktop -ErrorAction SilentlyContinue).Win8DpiScaling -eq 1
  $result=[ordered]@{Success=($actual[0] -eq 1920 -and $actual[1] -eq 1080 -and @($scales|Where-Object {$_ -ne 100}).Count -eq 0 -and -not $custom);Width=$actual[0];Height=$actual[1];CurrentMonitorDPI=$legacyDpi;CurrentScalePercent=$legacyScale;NativeScalePercent=$scales;CustomScalingEnabled=$custom;VerifiedAt=(Get-Date).ToString('o');Error='解析度或實際 DPI 尚未符合 1920×1080 / 100%，可能需要重新登入。'}
  if($result.Success){$result.Error=$null}
  return [pscustomobject]$result
 }
 $values=[WindowsSetupDisplay.Display]::Apply()
 if($values[4] -eq 1){throw '顯示驅動要求手動重新開機，尚不能確認解析度已套用；本工具不會自行重新啟動。'}
 if($values[4] -ne 0){throw ('顯示模式套用未成功，原生結果碼：'+$values[4])}
 if($values[2] -ne 1920 -or $values[3] -ne 1080){throw '實際解析度讀回未符合 1920×1080，不能視為已套用。'}
 # Retain standard per-monitor scaling rather than global custom LogPixels scaling.
 New-ItemProperty $desktop -Name Win8DpiScaling -Value 0 -PropertyType DWord -Force|Out-Null
 Remove-ItemProperty $desktop -Name LogPixels -ErrorAction SilentlyContinue
 $nativeScales=@([WindowsSetupDisplay.Display]::NativeScales($true))
 if(-not $nativeScales.Count -or @($nativeScales|Where-Object {$_ -ne 100}).Count){throw '標準縮放尚未成功設定為 100%。'}
 if((Get-ItemProperty $desktop -ErrorAction Stop).Win8DpiScaling -ne 0){throw '自訂縮放尚未停用，不能視為已套用標準 100% 縮放。'}
 return [pscustomobject][ordered]@{Success=$true;PreviousWidth=$values[0];PreviousHeight=$values[1];Width=$values[2];Height=$values[3];DisplayChangeResult=$values[4];LegacySystemDPI=$values[5];RequestedScalePercent=100;NativeScalePercent=$nativeScales;CustomScalingEnabled=$false;LegacyAppsMayRequireNextSignIn=$true;AppliedAt=(Get-Date).ToString('o')}
}
