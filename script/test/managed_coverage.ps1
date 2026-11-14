#Requires -Version 5.1
param([string]$SourceRoot,[string]$OutputDirectory,[switch]$Runtime)
# Runner-local maintenance producer. Never applies display, desktop, hotkey or provisioning settings.
function Get-ManagedCoverageToolPin {
 return [pscustomobject]@{Id='Microsoft.dotnet-coverage';Version='17.14.1';PackageSHA512='hgzaG+c7LtKup6HZixvXtn3l4Pa8VK23bM9vLHveD3Iq2XlzLu7vqMZwtVjQdsof83wx5OzY0tpDh3+YRdOVjA==';SDK='10.0.300';CompilerSHA256='5d03664b92a3c91bafb63466d1796d1aa863a5cbab3d6b79a30ba1b13d192cd2'}
}
function Get-ManagedSourceInventory {
 param([Parameter(Mandatory=$true)][string]$SourceRoot,[switch]$Runtime)
 $root=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
 foreach($tree in @('core','modules','script')){
  $directory=Join-Path $root $tree
  if(-not(Test-Path -LiteralPath $directory -PathType Container)){continue}
  foreach($file in @(Get-ChildItem -LiteralPath $directory -Recurse -File -Filter '*.cs'|Sort-Object FullName)){
   $relative=$file.FullName.Substring($root.Length+1).Replace('\','/')
   if($relative.StartsWith('modules/debloat/win11debloat/',[StringComparison]::OrdinalIgnoreCase)){continue}
   if($Runtime -and $relative -cnotmatch '^modules/[^/]+/native/[^/]+\.cs$'){continue}
   if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Managed source cannot be a reparse point.'}
   [pscustomobject]@{Path=$relative;SHA256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}
  }
 }
}
function Assert-ManagedOutputLocation {
 param([string]$SourceRoot,[string]$OutputDirectory)
 $root=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\');$output=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
 if($output -ieq $root -or $output.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Managed evidence must be outside the reviewed source tree.'}
 if(Test-Path -LiteralPath $output){throw 'Managed evidence output must not already exist.'}
 return $output
}
function Invoke-ManagedNative {
 param([Parameter(Mandatory=$true)][string]$FilePath,[Parameter(Mandatory=$true)][string[]]$Arguments,[Parameter(Mandatory=$true)][string]$LogPath)
 $preference=$ErrorActionPreference;$exitCode=-1
 try{$ErrorActionPreference='Continue';& $FilePath @Arguments *> $LogPath;$exitCode=$LASTEXITCODE}finally{$ErrorActionPreference=$preference}
 if($exitCode -ne 0){throw ('Managed native command failed with exit '+$exitCode+'; inspect runner-local log '+$LogPath)}
}
function Get-ManagedCompilerPath {
 param([string]$DotnetPath)
 $pin=Get-ManagedCoverageToolPin
 $lines=@(& $DotnetPath --list-sdks)
 if($LASTEXITCODE -ne 0){throw 'Cannot query installed .NET SDKs.'}
 $candidates=@(foreach($line in $lines){if($line -match '^([0-9.]+)\s+\[(.+)\]$' -and $Matches[1] -eq $pin.SDK){Join-Path (Join-Path $Matches[2] $Matches[1]) 'Roslyn/bincore/csc.dll'}})
 if($candidates.Count -ne 1 -or -not(Test-Path -LiteralPath $candidates[0] -PathType Leaf)){throw ('Maintenance SDK '+$pin.SDK+' is required; no global installation is performed.')}
 if((Get-FileHash -LiteralPath $candidates[0] -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.CompilerSHA256){throw 'Pinned Microsoft compiler digest differs.'}
 return $candidates[0]
}
function Initialize-ManagedCoverageTool {
 param([string]$OutputDirectory,[string]$DotnetPath)
 $pin=Get-ManagedCoverageToolPin
 $feed=Join-Path $OutputDirectory 'tool-feed';New-Item -ItemType Directory -Path $feed|Out-Null
 $package=Join-Path $feed ('dotnet-coverage.'+$pin.Version+'.nupkg')
 if(-not [string]::IsNullOrWhiteSpace($env:WINDOWS_SETUP_MANAGED_PACKAGE_PATH)){
  if(-not(Test-Path -LiteralPath $env:WINDOWS_SETUP_MANAGED_PACKAGE_PATH -PathType Leaf)){throw 'Supplied runner-local managed package is missing; no network fallback is allowed.'}
  Copy-Item -LiteralPath $env:WINDOWS_SETUP_MANAGED_PACKAGE_PATH -Destination $package -ErrorAction Stop
 }else{
  Invoke-WebRequest -UseBasicParsing -Uri ('https://api.nuget.org/v3-flatcontainer/dotnet-coverage/'+$pin.Version+'/dotnet-coverage.'+$pin.Version+'.nupkg') -OutFile $package -ErrorAction Stop
 }
 $sha=[Security.Cryptography.SHA512]::Create();try{$hash=[Convert]::ToBase64String($sha.ComputeHash([IO.File]::ReadAllBytes($package)))}finally{$sha.Dispose()}
 if($hash -cne $pin.PackageSHA512){throw 'Official NuGet package SHA512 differs; tool will not execute.'}
 $config=Join-Path $OutputDirectory 'nuget.config'
 $escaped=[Security.SecurityElement]::Escape($feed)
 [IO.File]::WriteAllText($config,('<configuration><packageSources><clear/><add key="pinned-local" value="'+$escaped+'"/></packageSources></configuration>'),[Text.UTF8Encoding]::new($false))
 $directory=Join-Path $OutputDirectory 'tools'
 Invoke-ManagedNative -FilePath $DotnetPath -Arguments @('tool','install','dotnet-coverage','--version',$pin.Version,'--tool-path',$directory,'--configfile',$config) -LogPath (Join-Path $OutputDirectory 'tool_install.log')
 $tool=Join-Path $directory 'dotnet-coverage.exe'
 if(-not(Test-Path -LiteralPath $tool -PathType Leaf)){throw 'Pinned local coverage tool was not installed.'}
 return $tool
}
function Get-ManagedArtifactReference {
 param([string]$OutputDirectory,[string]$Path)
 $root=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')+'\';$full=[IO.Path]::GetFullPath($Path)
 if(-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Managed artifact escapes its output directory.'}
 return [pscustomobject]@{Path=$full.Substring($root.Length).Replace('\','/');SHA256=(Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}
}
function Invoke-ManagedCoverage {
 param([Parameter(Mandatory=$true)][string]$SourceRoot,[Parameter(Mandatory=$true)][string]$OutputDirectory,[switch]$Runtime)
 $ErrorActionPreference='Stop';$root=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
 $sources=@(Get-ManagedSourceInventory -SourceRoot $root -Runtime:$Runtime)
 if($sources.Count -eq 0){throw 'Managed production source inventory is empty.'}
 $output=Assert-ManagedOutputLocation -SourceRoot $root -OutputDirectory $OutputDirectory
 $dotnet=(Get-Command dotnet -ErrorAction Stop).Source;$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
 $compiler=Get-ManagedCompilerPath -DotnetPath $dotnet
 $refs=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319'
 $referenceFiles=@('mscorlib.dll','System.dll','System.Core.dll','System.Xml.dll')
 foreach($name in $referenceFiles){if(-not(Test-Path -LiteralPath (Join-Path $refs $name))){throw ('Missing Windows .NET Framework reference: '+$name)}}
 $harness=Join-Path $root 'test/managed/native_tests.cs';if(-not(Test-Path -LiteralPath $harness)){throw 'Managed safe test harness is missing.'}
 New-Item -ItemType Directory -Path $output|Out-Null
 $saved=@{};$changes=@{DOTNET_CLI_HOME=(Join-Path $output 'dotnet-home');NUGET_PACKAGES=(Join-Path $output 'nuget-packages');DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';DOTNET_GENERATE_ASPNET_CERTIFICATE='false';DOTNET_CLI_TELEMETRY_OPTOUT='1';DOTNET_NOLOGO='1'}
 foreach($name in $changes.Keys){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process');[Environment]::SetEnvironmentVariable($name,$changes[$name],'Process')}
 try{
  $tool=Initialize-ManagedCoverageTool -OutputDirectory $output -DotnetPath $dotnet
  $bin=Join-Path $output 'bin';$shards=Join-Path $output 'shards';New-Item -ItemType Directory -Path $bin,$shards|Out-Null
  $assembly=Join-Path $bin 'windows_setup_managed.dll';$pdb=Join-Path $bin 'windows_setup_managed.pdb';$exe=Join-Path $bin 'windows_setup_managed_tests.exe'
  $base=@($compiler,'/nologo','/noconfig','/nostdlib+','/langversion:5','/debug:portable','/optimize-')+@($referenceFiles|ForEach-Object {'/reference:'+(Join-Path $refs $_)})
  $compile=$base+@('/target:library',('/out:'+$assembly),('/pdb:'+$pdb))+@($sources|ForEach-Object {Join-Path $root $_.Path})
  Invoke-ManagedNative -FilePath $dotnet -Arguments $compile -LogPath (Join-Path $output 'compile_production.log')
  $testSources=@($harness)
  if($Runtime){$testSources+=Join-Path $root 'script/test/native/oobe_wim_reader.cs'}
  Invoke-ManagedNative -FilePath $dotnet -Arguments ($base+@('/target:exe',('/out:'+$exe),('/reference:'+$assembly))+$testSources) -LogPath (Join-Path $output 'compile_tests.log')
  $catalog=Join-Path $output 'catalog.json'
  Invoke-ManagedNative -FilePath $pwsh -Arguments @('-NoProfile','-File',(Join-Path $root 'script/test/managed_catalog.ps1'),'-SourceRoot',$root,'-AssemblyPath',$assembly,'-PDBPath',$pdb,'-OutputPath',$catalog) -LogPath (Join-Path $output 'catalog.log')
  $settings=Join-Path $output 'coverage.config'
  [IO.File]::WriteAllText($settings,'<Configuration><CodeCoverage><ModulePaths mergeDefaults="False"><Include><ModulePath>.*windows_setup_managed\.dll$</ModulePath></Include></ModulePaths><Attributes mergeDefaults="False"><Exclude/></Attributes><Functions mergeDefaults="False"><Exclude/></Functions></CodeCoverage></Configuration>',[Text.UTF8Encoding]::new($false))
  $records=New-Object 'Collections.Generic.List[object]'
  foreach($scenario in @('all')){
   $binary=Join-Path $shards ($scenario+'.coverage');$xml=Join-Path $shards ($scenario+'.xml')
   Invoke-ManagedNative -FilePath $tool -Arguments @('collect','-s',$settings,'-f','coverage','-o',$binary,'--',$exe,$scenario) -LogPath (Join-Path $shards ($scenario+'.log'))
   Invoke-ManagedNative -FilePath $tool -Arguments @('merge',$binary,'-f','xml','-o',$xml) -LogPath (Join-Path $shards ($scenario+'_export.log'))
   $b=Get-ManagedArtifactReference $output $binary;$x=Get-ManagedArtifactReference $output $xml
   $records.Add([pscustomobject]@{BinaryPath=$b.Path;SHA256=$b.SHA256;XmlPath=$x.Path;XmlSHA256=$x.SHA256})
  }
  $merged=Join-Path $output 'merged.coverage';$mergedXml=Join-Path $output 'merged.xml'
  Invoke-ManagedNative -FilePath $tool -Arguments (@('merge')+@($records|ForEach-Object {Join-Path $output $_.BinaryPath})+@('-f','coverage','-o',$merged)) -LogPath (Join-Path $output 'merge_binary.log')
  Invoke-ManagedNative -FilePath $tool -Arguments @('merge',$merged,'-f','xml','-o',$mergedXml) -LogPath (Join-Path $output 'merge_export.log')
  $after=@(Get-ManagedSourceInventory -SourceRoot $root -Runtime:$Runtime)
  if(($after|ConvertTo-Json -Compress) -cne ($sources|ConvertTo-Json -Compress)){throw 'Managed source inventory changed while collecting evidence.'}
  $a=Get-ManagedArtifactReference $output $assembly;$p=Get-ManagedArtifactReference $output $pdb;$c=Get-ManagedArtifactReference $output $catalog;$m=Get-ManagedArtifactReference $output $merged;$x=Get-ManagedArtifactReference $output $mergedXml;$pin=Get-ManagedCoverageToolPin
  $proof=[pscustomobject][ordered]@{SchemaVersion=1;Metric='complete-executable-lines-v1';SourceRoot=$root;Tool=[pscustomobject]@{Id=$pin.Id;Version=$pin.Version;PackageSHA512=$pin.PackageSHA512};Sources=$sources;AssemblyPath=$a.Path;AssemblySHA256=$a.SHA256;PDBPath=$p.Path;PDBSHA256=$p.SHA256;CatalogPath=$c.Path;CatalogSHA256=$c.SHA256;Shards=[object[]]$records.ToArray();MergedBinaryPath=$m.Path;MergedBinarySHA256=$m.SHA256;MergedXmlPath=$x.Path;MergedXmlSHA256=$x.SHA256;MergeNative=$true}
  [IO.File]::WriteAllText((Join-Path $output 'evidence.json'),($proof|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  Write-Host ('Managed native evidence collected for '+$sources.Count+' real source files; no host settings applied.')
  return $proof
 }finally{foreach($name in $changes.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}}
}
if($MyInvocation.InvocationName -ne '.'){
 if(-not $SourceRoot){$SourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
 if(-not $OutputDirectory){throw 'An external, new OutputDirectory is required.'}
 Invoke-ManagedCoverage -SourceRoot $SourceRoot -OutputDirectory $OutputDirectory -Runtime:$Runtime|Out-Null
}
