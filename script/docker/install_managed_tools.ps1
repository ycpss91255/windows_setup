#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'download_library.ps1')
function Get-ContainerManagedToolArtifacts {
 # Microsoft release metadata: PowerShell/PowerShell v7.6.9, dotnet release-metadata/10.0/releases.json.
 @(
  [pscustomobject]@{Name='PowerShell-7.6.9-win-x64.zip';Version='7.6.9';Uri='https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/PowerShell-7.6.9-win-x64.zip';Algorithm='SHA256';Hash='ce7484804c0f0ad4dda10c958e71acdaf7eebfb22505c1b480f89e0e9f1da94d';Kind='Zip';Destination='C:/pwsh'},
  [pscustomobject]@{Name='dotnet-sdk-10.0.300-win-x64.zip';Version='10.0.300';Uri='https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.300/dotnet-sdk-10.0.300-win-x64.zip';Algorithm='SHA512';Hash='32446eddffc5a485f58f9d79cdab3a1a9adab4adc2ef0e4c787cfbb2465020d50beaadc54d40f0850e2e0089edd09864d12d6c19c526319819d57a4c00d38518';Kind='Zip';Destination='C:/dotnet'},
  [pscustomobject]@{Name='dotnet-coverage.17.14.1.nupkg';Version='17.14.1';Uri='https://api.nuget.org/v3-flatcontainer/dotnet-coverage/17.14.1/dotnet-coverage.17.14.1.nupkg';Algorithm='SHA512';Hash='860cda1be73b2ed2aea7a1d98b1bd7b67de5e0f6bc54adb76ccf6f2c7bde0f722ad979732eeeefa8c670b558d076ca1ff37c31e4ecd8d2da43877f9845d3958c';Kind='File';Destination='C:/tools/cache/dotnet-coverage.17.14.1.nupkg'}
 )
}
function Get-ContainerWorkflowLintArtifact {
 # Official release: https://github.com/rhysd/actionlint/releases/tag/v1.7.12
 [pscustomobject]@{Name='actionlint_1.7.12_windows_amd64.zip';Version='1.7.12';Uri='https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_windows_amd64.zip';Algorithm='SHA256';Hash='6e7241b51e6817ea6a047693d8e6fed13b31819c9a0dd6c5a726e1592d22f6e9';Kind='Zip';Destination='C:/actionlint'}
}
function Get-ContainerPesterArtifact {
 # Official Gallery Pester 6.0.0 metadata SHA512, same pin as the coverage collector.
 [pscustomobject]@{Name='pester.6.0.0.zip';Version='6.0.0';Uri='https://www.powershellgallery.com/api/v2/package/Pester/6.0.0';Algorithm='SHA512';Hash='AHIAm7QW11As3sjMayo1rPU4JVIEfBL+ZILAyTyDnMPxMwLFQ3VeAA0prFTx+Y4DgZCUnH2N4+Xb0HDQua2EKA==';HashFormat='Base64';Kind='File';Destination='C:/tools/cache/pester.6.0.0.zip'}
}
function Get-ContainerPSScriptAnalyzerArtifact {
 # Official Gallery PSScriptAnalyzer 1.24.0 metadata SHA512.
 [pscustomobject]@{Name='psscriptanalyzer.1.24.0.zip';Version='1.24.0';Uri='https://www.powershellgallery.com/api/v2/package/PSScriptAnalyzer/1.24.0';Algorithm='SHA512';Hash='B8yVwiGkpN9LU8q7cBZHgBtBIAKgW+FbpVA/ZtSHD65K1FWFTT7nSVfehKL2OuoyufPf8VNcaRfHUTB3Rb3RZQ==';HashFormat='Base64';Kind='File';Destination='C:/tools/cache/psscriptanalyzer.1.24.0.zip'}
}
function Install-ContainerToolArtifact {
 param([Parameter(Mandatory=$true)]$Artifact,[Parameter(Mandatory=$true)][string]$Destination,[Parameter(Mandatory=$true)][string]$ArchiveDirectory)
 [void][IO.Directory]::CreateDirectory($ArchiveDirectory)
 $archive=Join-Path $ArchiveDirectory $Artifact.Name
 Invoke-ContainerOfficialDownload -Uri $Artifact.Uri -OutFile $archive
 try{
 $expected=$Artifact.Hash
 if($Artifact.HashFormat -eq 'Base64'){$expected=([BitConverter]::ToString([Convert]::FromBase64String($expected))).Replace('-','')}
 if((Get-FileHash -LiteralPath $archive -Algorithm $Artifact.Algorithm).Hash -ine $expected){throw ('Container tool digest mismatch: '+$Artifact.Name)}
 if($Artifact.Kind -eq 'Zip'){
  $watch=[Diagnostics.Stopwatch]::StartNew();Write-Host 'Verified tool extraction started.'
  try{Expand-ContainerToolArchive -LiteralPath $archive -DestinationPath $Destination}
  finally{Write-Host ('Verified tool extraction elapsed_ms='+$watch.ElapsedMilliseconds+'.')}
 }
 elseif($Artifact.Kind -eq 'File'){[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination));Copy-Item -LiteralPath $archive -Destination $Destination}
 else{throw ('Unsupported container artifact kind: '+$Artifact.Kind)}
 }finally{if(Test-Path -LiteralPath $archive){Remove-Item -LiteralPath $archive -Force}}
}
if($MyInvocation.InvocationName -ne '.'){
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 $archives=Join-Path $env:TEMP ('container_managed_'+[guid]::NewGuid().ToString('N'))
 foreach($artifact in @(@(Get-ContainerManagedToolArtifacts)+@(Get-ContainerWorkflowLintArtifact)+@(Get-ContainerPesterArtifact)+@(Get-ContainerPSScriptAnalyzerArtifact))){Install-ContainerToolArtifact -Artifact $artifact -Destination $artifact.Destination -ArchiveDirectory $archives}
}
