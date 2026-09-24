# Integrity checks only. Adjacent unsigned records cannot prove publisher identity.
. (Join-Path $PSScriptRoot 'release-policy.ps1')
function Resolve-TestRuntime {
  param([string]$Directory='', [string]$DistDir=(Join-Path (Split-Path $PSScriptRoot -Parent) 'dist'),
    [string]$ExtractionRoot=(Join-Path $PSScriptRoot 'b'))
  if($Directory){
    $resolved=(Resolve-Path -LiteralPath $Directory -ErrorAction Stop).Path
    [void](Test-ReleaseManifest $resolved)
    return $resolved
  }
  if(-not(Test-Path -LiteralPath $DistDir -PathType Container)){throw "No internal-test ZIP directory: '$DistDir'. Supply a verified package directory or create an internal-test ZIP first."}
  $zip=Get-ChildItem -LiteralPath $DistDir -Filter '*internal-test.zip' -File -Recurse -ErrorAction Stop |
    Sort-Object LastWriteTimeUtc,FullName -Descending | Select-Object -First 1
  if(-not $zip){throw "No internal-test ZIP found under '$DistDir'. Supply a verified package directory or create an internal-test ZIP first."}
  $sidecar=$zip.FullName+'.sha256'
  if(-not(Test-Path -LiteralPath $sidecar -PathType Leaf)){throw "ZIP SHA256 sidecar missing: $sidecar"}
  $line=(Get-Content -LiteralPath $sidecar -Raw).Trim()
  if($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$'){throw "Invalid ZIP SHA256 sidecar: $sidecar"}
  if($Matches[2] -ne $zip.Name -or (Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash -ne $Matches[1]){throw "Internal-test ZIP hash mismatch: $($zip.FullName)"}
  $zipHash=(Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash
  $buildPath=$zip.FullName+'.build.json';$sourcePath=$zip.FullName+'.source.sha256'
  if(-not(Test-Path -LiteralPath $buildPath -PathType Leaf) -or -not(Test-Path -LiteralPath $sourcePath -PathType Leaf)){throw 'Runtime build/source record missing'}
  $build=Get-Content -LiteralPath $buildPath -Raw | ConvertFrom-Json
  if($build.archive -ne $zip.Name -or $build.sha256 -ne $zipHash -or $build.internalTest -ne $true -or
      $build.sourceCommit -notmatch '^[a-f0-9]{40,64}$' -or -not $build.compiler -or $build.compilerSha256 -notmatch '^[a-fA-F0-9]{64}$') {throw 'Runtime build record mismatch or invalid provenance fields'}
  if((Get-FileHash -LiteralPath $sourcePath).Hash -ne $build.sourceManifestSha256){throw 'Runtime source manifest hash mismatch'}
  $repo=Split-Path $PSScriptRoot -Parent
  if((Get-FileHash -LiteralPath (Join-Path $repo 'installer/release-inputs.json')).Hash -ne $build.inputLockSha256){throw 'Runtime input lock differs from current workspace'}
  $sourceNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $changed=0
  foreach($row in Get-Content -LiteralPath $sourcePath){
    if($row -notmatch '^([a-fA-F0-9]{64})  (.+)$'){throw 'Invalid source manifest row'}
    $hash=$Matches[1];$rel=$Matches[2]
    if([IO.Path]::IsPathRooted($rel) -or $rel -match '(^|[\\/])\.\.([\\/]|$)|:' -or -not $sourceNames.Add($rel)){throw 'Unsafe or duplicate source manifest path'}
    $local=Join-Path $repo $rel
    if(-not(Test-Path -LiteralPath $local -PathType Leaf) -or (Get-FileHash -LiteralPath $local).Hash -ne $hash){$changed++}
  }
  if($sourceNames.Count -eq 0){throw 'Empty source manifest'}
  Write-Host "Runtime selection uses newest file modification time; integrity only, NOT signature or publisher authentication. Source differences from current workspace: $changed."
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive=[IO.Compression.ZipFile]::OpenRead($zip.FullName)
  try {
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [long]$total=0
    foreach($entry in $archive.Entries){
      $name=$entry.FullName.Replace('/','\')
      if($name -eq 'Lang\' -and $entry.Length -eq 0){continue}
      if($script:ReleaseAllowedFiles -notcontains $name -or -not $seen.Add($name)){throw "Unsafe or duplicate ZIP entry: $name"}
      $total+=$entry.Length
      if($entry.Length -gt 100MB -or $total -gt 256MB){throw 'Runtime ZIP exceeds size limit'}
    }
    foreach($name in $script:ReleaseAllowedFiles){if(-not $seen.Contains($name)){throw "Runtime ZIP missing required file: $name"}}
    $target=Join-Path $ExtractionRoot ('runtime-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null
    # Extract only entries already checked against the exact release allowlist.
    foreach($entry in $archive.Entries){
      $name=$entry.FullName.Replace('/','\'); if($name -eq 'Lang\'){continue}
      $dest=Join-Path $target $name
      New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
      [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dest,$false)
    }
  } finally {$archive.Dispose()}
  [void](Test-ReleaseManifest $target)
  if((Get-FileHash -LiteralPath (Join-Path $target 'SHA256SUMS.txt')).Hash -ne $build.manifestSha256){throw 'Runtime build/package manifest mismatch'}
  Write-Host "Runtime seed: $($zip.FullName)"
  return $target
}
