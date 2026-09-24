param([string]$Version='26.03-review', [string]$OutDir='dist', [string]$PackageDir='', [switch]$WithSetup, [switch]$InternalTest, [string]$EvidencePath='')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'tests\release-policy.ps1')
if($WithSetup){throw '-WithSetup is disabled: portable ZIP only.'}
if($Version -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$'){throw 'invalid version'}
if(-not $PackageDir){throw 'Specify a newly assembled candidate with -PackageDir.'}
$package=(Resolve-Path -LiteralPath $PackageDir).Path
Assert-ReleaseTree $package -RequireManifest
[void](Test-ReleaseManifest $package)
$out=if([IO.Path]::IsPathRooted($OutDir)){[IO.Path]::GetFullPath($OutDir)}else{[IO.Path]::GetFullPath((Join-Path $root $OutDir))}
New-Item -ItemType Directory -Force -Path $out | Out-Null
$stage=Join-Path $out ('staging-'+[guid]::NewGuid().ToString('N'))
$check=Join-Path $out ('verify-'+[guid]::NewGuid().ToString('N'))
$suffix=if($InternalTest){'internal-test'}else{'portable'}
$zip=Join-Path $out "7z-password-vault-$Version-win64-$suffix.zip"
if(Test-Path -LiteralPath $zip){throw 'Output already exists. Freeze candidates; use a new version or output directory.'}
try{
  New-Item -ItemType Directory -Path (Join-Path $stage 'Lang') | Out-Null
  foreach($rel in $script:ReleaseAllowedFiles){Copy-Item -LiteralPath (Join-Path $package $rel) -Destination (Join-Path $stage $rel)}
  [void](Test-ReleaseManifest $stage)
  if(-not $InternalTest){
    if(-not $EvidencePath){throw 'Public release requires provenance, Windows 11 Insider standard-user GUI, and upgrade/rollback evidence.'}
    if(& git -C $root status --porcelain){throw 'Public release requires a clean, committed source tree.'}
    $evidence=Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
    Assert-PublicReleaseEvidence $evidence $stage (Join-Path $root 'installer\release-inputs.json')
  }
  Compress-Archive -LiteralPath @(Get-ChildItem -LiteralPath $stage -Force | ForEach-Object FullName) -DestinationPath $zip -CompressionLevel Optimal
  Expand-Archive -LiteralPath $zip -DestinationPath $check
  [void](Test-ReleaseManifest $check)
  if((Get-FileHash -LiteralPath (Join-Path $stage 'SHA256SUMS.txt')).Hash -ne (Get-FileHash -LiteralPath (Join-Path $check 'SHA256SUMS.txt')).Hash){throw 'ZIP manifest differs from frozen staging manifest'}
  $sha=(Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant()
  [IO.File]::WriteAllText(($zip+'.sha256'),("$sha  "+[IO.Path]::GetFileName($zip)+"`n"))
  $sourcePaths=@(& git -C $root ls-files --cached --others --exclude-standard | Sort-Object -Unique)
  $sourceLines=@(foreach($rel in $sourcePaths){
    if($rel.EndsWith('.log')){continue}
    $source=Join-Path $root $rel
    if(Test-Path -LiteralPath $source -PathType Leaf){'{0}  {1}' -f (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant(),$rel}
  })
  [IO.File]::WriteAllLines(($zip+'.source.sha256'),$sourceLines)
  $signatures=[ordered]@{}
  foreach($exe in '7zFM.exe','7zG.exe'){$signatures[$exe]=[string](Get-AuthenticodeSignature -LiteralPath (Join-Path $stage $exe)).Status}
  $record=[ordered]@{createdAt=[DateTime]::UtcNow.ToString('o');internalTest=[bool]$InternalTest;archive=[IO.Path]::GetFileName($zip);sha256=$sha;signatureStatus=$signatures;securityScanStatus=if($InternalTest){'not-reviewed'}else{$evidence.securityScanStatus};releaseEvidenceSha256=if($InternalTest){$null}else{(Get-FileHash -LiteralPath $EvidencePath).Hash};sourceCommit=(& git -C $root rev-parse HEAD);sourceDirty=[bool](& git -C $root status --porcelain);sourceManifestSha256=(Get-FileHash -LiteralPath ($zip+'.source.sha256')).Hash;compiler=(& g++ --version | Select-Object -First 1);compilerSha256=(Get-FileHash (Get-Command g++).Source).Hash;manifestSha256=(Get-FileHash -LiteralPath (Join-Path $stage 'SHA256SUMS.txt')).Hash;inputLockSha256=(Get-FileHash -LiteralPath (Join-Path $root 'installer\release-inputs.json')).Hash}
  [IO.File]::WriteAllText(($zip+'.build.json'),($record|ConvertTo-Json -Depth 4))
  $components=@(foreach($rel in $script:ReleaseRequiredFiles){[ordered]@{type='file';name=$rel;hashes=@(@{alg='SHA-256';content=(Get-FileHash -LiteralPath (Join-Path $stage $rel)).Hash.ToLowerInvariant()})}})
  $sbom=[ordered]@{bomFormat='CycloneDX';specVersion='1.5';version=1;components=$components}
  [IO.File]::WriteAllText(($zip+'.sbom.json'),($sbom|ConvertTo-Json -Depth 6))
  Write-Host "Verified $suffix ZIP: $zip"
  Write-Output $zip
}finally{
  foreach($dir in @($stage,$check)){
    $resolved=[IO.Path]::GetFullPath($dir)
    if(-not $resolved.StartsWith($out.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'unsafe staging cleanup path'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
  }
}
