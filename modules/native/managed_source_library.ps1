#Requires -Version 5.1
# Definitions only; the caller chooses the package and worker directories.
function Copy-SetupManagedSource {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9_]+\.cs$')][string]$FileName
    )
    $source = [IO.Path]::GetFullPath((Join-Path (Join-Path $SourceRoot 'native') $FileName))
    $target = [IO.Path]::GetFullPath((Join-Path (Join-Path $DestinationRoot 'native') $FileName))
    if (-not(Test-Path -LiteralPath $source -PathType Leaf)) {
        throw ('缺少 managed 執行依賴：' + $FileName)
    }
    $expected = (Get-FileHash -LiteralPath $source -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($source -ieq $target) {
        return $target
    }
    New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash -cne $expected) {
        throw ('managed 執行依賴複製驗證失敗：' + $FileName)
    }
    return $target
}