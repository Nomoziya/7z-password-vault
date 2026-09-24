# Public/internal ZIP verification, with no installation or registry writes.
param([Parameter(Mandatory)][string]$Package,[switch]$KeepArtifacts)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'release-policy.ps1')
$zip=(Resolve-Path -LiteralPath $Package).Path
if([IO.Path]::GetExtension($zip) -ne '.zip'){throw 'Only portable ZIP artifacts are accepted.'}
$sidecar=$zip+'.sha256'
if(-not(Test-Path -LiteralPath $sidecar)){throw 'Independent ZIP SHA-256 is required.'}
$line=[IO.File]::ReadAllText($sidecar).Trim()
if($line -notmatch '^([a-fA-F0-9]{64})  (.+)$' -or $Matches[2] -ne [IO.Path]::GetFileName($zip)){throw 'Invalid independent checksum file.'}
if((Get-FileHash -LiteralPath $zip).Hash -ne $Matches[1]){throw 'ZIP checksum mismatch.'}
$work=Join-Path $PSScriptRoot ('b\acceptance-'+[guid]::NewGuid().ToString('N'))
try{
  Expand-Archive -LiteralPath $zip -DestinationPath $work
  Assert-ReleaseTree $work -RequireManifest
  [void](Test-ReleaseManifest $work)
  Write-Host 'PASS: independent archive hash, exact extracted file set, every file hash, and no install/uninstall payload.'
}finally{
  $resolved=[IO.Path]::GetFullPath($work);$testRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'b'))+'\'
  if(-not $resolved.StartsWith($testRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'unsafe acceptance cleanup'}
  if(-not $KeepArtifacts -and (Test-Path -LiteralPath $resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}