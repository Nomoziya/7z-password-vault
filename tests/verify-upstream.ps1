param(
  [string]$Candidate='dist/review4-candidate-20260923',
  [string]$Package='dist/review4-release-20260923/7z-password-vault-26.03-review4-20260923-win64-internal-test.zip',
  [string]$AssetDir='tests/b/upstream-26.03-official',
  [switch]$KeepArtifacts
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'release-policy.ps1')
function Full([string]$p) { if([IO.Path]::IsPathRooted($p)){[IO.Path]::GetFullPath($p)}else{[IO.Path]::GetFullPath((Join-Path $root $p))} }
function Hash([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
$candidate=Full $Candidate;$zip=Full $Package;$assets=Full $AssetDir
$lock=Get-Content -LiteralPath (Join-Path $root 'installer/release-inputs.json') -Raw|ConvertFrom-Json
$official=@{
  '7z2603-src.7z'='41e2a7c0e9f838351c625e01f0f581a2188bb3dda10c8e0b4a852da26546ffe2'
  '7z2603-extra.7z'='191894e6acb3647ffb69ce630479ff318523b2e2b9890aa7f05c1127c2e59b8f'
  '7z2603-x64.exe'='0859c524b8a63551848f0c246abddcb1d0b7b656b0fbfe879f8d85e61a9e6edd'
}
$paths=@{'7z2603-src.7z'=(Join-Path $root '7z2603-src.7z');'7z2603-extra.7z'=(Join-Path $assets '7z2603-extra.7z');'7z2603-x64.exe'=(Join-Path $assets '7z2603-x64.exe')}
foreach($name in $official.Keys){
  if((Hash $paths[$name]) -ne $official[$name]){throw "Official 26.03 asset digest mismatch: $name"}
  $rec=@($lock.officialAssets|Where-Object file -eq $name)
  if($rec.Count -ne 1 -or $rec[0].sha256 -ne $official[$name]){throw "Input lock differs from official digest: $name"}
}
if($lock.sourceArchive.sha256 -ne $official['7z2603-src.7z']){throw 'Source archive lock mismatch'}
$sidecar=([IO.File]::ReadAllText($zip+'.sha256')).Trim()
if($sidecar -ne ((Hash $zip)+'  '+[IO.Path]::GetFileName($zip))){throw 'Frozen ZIP sidecar mismatch'}
$run=Join-Path (Join-Path $root 'tests/b') ('upstream-verify-'+[guid]::NewGuid().ToString('N'))
$out=Join-Path $run 'official-x64';$source=Join-Path $run 'official-source';$package=Join-Path $run 'frozen-package'
New-Item -ItemType Directory -Path $out,$source,$package -Force|Out-Null
try{
  $seven=Join-Path $candidate '7z.exe'
  & $seven x $paths['7z2603-x64.exe'] ('-o'+$out) -y | Out-Null
  if($LASTEXITCODE -ne 0){throw 'Official x64 extraction failed'}
  & $seven x $paths['7z2603-src.7z'] ('-o'+$source) -y | Out-Null
  if($LASTEXITCODE -ne 0){throw 'Official source extraction failed'}
  Expand-Archive -LiteralPath $zip -DestinationPath $package
  [void](Test-ReleaseManifest $package)
  $runtime=@(foreach($entry in $lock.runtime){
    $name=[string]$entry.file;$a=Hash (Join-Path $out $name)
    if($a -ne $entry.sha256 -or $a -ne (Hash (Join-Path $candidate $name)) -or $a -ne (Hash (Join-Path $package $name))){throw "Runtime differs from official installer: $name"}
    [ordered]@{file=$name;sha256=$a;source='7z2603-x64.exe'}
  })
  if($runtime.Count -ne 8){throw 'Expected eight runtime files'}
  $base=$source.TrimEnd('\');$identical=0;$modified=[Collections.Generic.List[string]]::new();$missing=[Collections.Generic.List[string]]::new()
  foreach($file in Get-ChildItem -LiteralPath $source -File -Recurse){
    $rel=$file.FullName.Substring($base.Length+1);$local=Join-Path $root $rel
    if(-not(Test-Path -LiteralPath $local -PathType Leaf)){$missing.Add($rel)}
    elseif((Hash $file.FullName) -eq (Hash $local)){$identical++}
    else{$modified.Add($rel)}
  }
  if($missing.Count){throw "Official source files missing from fork: $($missing.Count)"}
  $record=[ordered]@{classification='PASS';checkedUtc=[DateTime]::UtcNow.ToString('o');officialDigestPage='https://github.com/ip7z/7zip/releases/expanded_assets/26.03';officialAssets=@(foreach($name in $official.Keys|Sort-Object){[ordered]@{file=$name;sha256=$official[$name]}});candidate=$candidate;archive=[IO.Path]::GetFileName($zip);archiveSha256=Hash $zip;fileManagerSha256=Hash (Join-Path $package '7zFM.exe');guiSha256=Hash (Join-Path $package '7zG.exe');runtime=$runtime;sourceFilesIdentical=$identical;sourceFilesModified=$modified.Count;sourceFilesMissing=0;modifiedSourcePaths=$modified.ToArray();inputLockSha256=Hash (Join-Path $root 'installer/release-inputs.json');interpretation='Official asset digests and package bytes agree. The 22 changed source files are fork changes; this check does not prove a reproducible GUI build or publisher identity.'}
  $record|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $assets 'result.json') -Encoding UTF8
  Write-Host "PASS: 3 official assets; 8 runtime files; source $identical identical, $($modified.Count) modified, 0 missing; frozen ZIP matched."
  Write-Host "Evidence: $(Join-Path $assets 'result.json')"
}finally{
  $resolved=[IO.Path]::GetFullPath($run);$testRoot=[IO.Path]::GetFullPath((Join-Path $root 'tests/b')).TrimEnd('\')+'\'
  if(-not $resolved.StartsWith($testRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'unsafe provenance fixture cleanup'}
  if(-not $KeepArtifacts -and (Test-Path -LiteralPath $resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
