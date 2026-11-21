#Requires -Version 5.1
function Get-SetupSystemIconNames {
 $shell=New-Object -ComObject Shell.Application
 $desktop=$shell.NameSpace(0)
 if($null -eq $desktop){throw '無法辨識四個系統圖示名稱。'}
 foreach($id in @('{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}','{20D04FE0-3AEA-1069-A2D8-08002B30309D}','{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}','{645FF040-5081-101B-9F08-00AA002F954E}')){
  $item=$desktop.ParseName(('::'+$id))
  if($null -eq $item -or [string]::IsNullOrWhiteSpace($item.Name)){throw '無法辨識四個系統圖示名稱。'}
  [string]$item.Name
 }
}
function Assert-SetupSystemIconSet {
 param($Icons,[string[]]$Names)
 if(@($Icons).Count -ne 4 -or @($Names).Count -ne 4 -or @($Names|Select-Object -Unique).Count -ne 4){throw '目前桌面不是四個唯一系統圖示。'}
 foreach($name in $Names){if(@($Icons|Where-Object Name -eq $name).Count -ne 1){throw ('找不到唯一系統圖示：'+$name)}}
}
function Invoke-SetupIconsSettings {
 param([Parameter(Mandatory=$true)][string]$ModuleRoot,[ValidateSet('Save','Load','Verify')][string]$Mode='Load',$Reference)
 if(-not ('WindowsSetupIcons.Desktop' -as [type])){Add-Type -Path (Join-Path $ModuleRoot 'native/desktop_icons.cs')}
 $snapshot=[WindowsSetupIcons.Desktop]::Capture()

 if($Mode -eq 'Save'){
  Assert-SetupSystemIconSet -Icons $snapshot.Icons -Names @(Get-SetupSystemIconNames)
  $reference=[ordered]@{Width=$snapshot.Width;Height=$snapshot.Height;Icons=@($snapshot.Icons|Select-Object Name,X,Y);SavedAt=(Get-Date).ToString('o')}

  $result=[ordered]@{Success=$true;Mode=$Mode;Reference=$reference}
 }else{
  Assert-SetupSystemIconSet -Icons $Reference.Icons -Names @(Get-SetupSystemIconNames)
  Assert-SetupSystemIconSet -Icons $snapshot.Icons -Names @($Reference.Icons|ForEach-Object Name)

  if($snapshot.Width -ne $reference.Width -or $snapshot.Height -ne $reference.Height){throw '桌面範圍與範本不同，請確認解析度、縮放及螢幕數量。'}
  $differences=@()
  foreach($expected in $reference.Icons){
   $actual=@($snapshot.Icons|Where-Object Name -eq $expected.Name)
   if($actual.Count -ne 1){$differences+=('找不到唯一圖示：'+$expected.Name);continue}
   if($Mode -eq 'Load'){[WindowsSetupIcons.Desktop]::Position($actual[0].Index,[int]$expected.X,[int]$expected.Y)}
  }
  if($Mode -eq 'Load'){
   $key='HKCU:\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
   $flags=(Get-ItemProperty $key -ErrorAction SilentlyContinue).FFlags
   if($null -ne $flags){Set-ItemProperty $key -Name FFlags -Value ($flags -band (-bnot 1))}
   Start-Sleep -Milliseconds 500
  }
  $after=[WindowsSetupIcons.Desktop]::Capture()
  if(@($after.Icons).Count -ne 4){$differences+='結果不是四個系統圖示'}
  foreach($expected in $reference.Icons){$actual=@($after.Icons|Where-Object Name -eq $expected.Name);if($actual.Count -ne 1){$differences+=('找不到唯一圖示：'+$expected.Name)}elseif([math]::Abs($actual[0].X-$expected.X) -gt 2 -or [math]::Abs($actual[0].Y-$expected.Y) -gt 2){$differences+=('位置不符：'+$expected.Name)}}
  $result=[ordered]@{Success=($differences.Count -eq 0);Mode=$Mode;Differences=$differences;Actual=@($after.Icons|Select-Object Name,X,Y);Error=($differences -join '；')}
 }
 return [pscustomobject]$result
}
