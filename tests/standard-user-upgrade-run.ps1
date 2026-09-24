# Run from an interactive Windows 11 Insider standard-user desktop.
# Creates a unique local test directory; never uses the real vault as a fixture.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'release-policy.ps1')
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=[Security.Principal.WindowsPrincipal]::new($identity)
if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  throw 'Run this acceptance test from the cs standard-user desktop, not an elevated terminal.'
}
$review4=Join-Path $repo 'dist/review4-release-20260923/7z-password-vault-26.03-review4-20260923-win64-internal-test.zip'
$review3=Join-Path $repo 'dist/review3-release-20260923/7z-password-vault-26.03-review3-20260923-win64-internal-test.zip'
$expected=@{
  $review4='37166d2b30f4d08d96239fac0e7bef5b77d88d6efca2e5d8196ae40bd1f62c7d'
  $review3='64082e6753db9e20b95465da3191cc85b2b20f11174c304e94d3264bb3530ee2'
}
foreach($zip in @($review3,$review4)){
  $hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  $sidecar=([IO.File]::ReadAllText($zip+'.sha256')).Trim()
  if($hash -ne $expected[$zip] -or $sidecar -ne ($hash+'  '+[IO.Path]::GetFileName($zip))){throw "Frozen package hash mismatch: $zip"}
}
$stage=Join-Path $env:LOCALAPPDATA ('7zpw-upgrade-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $stage 'tests/b'),(Join-Path $stage 'review3'),(Join-Path $stage 'review4') -Force|Out-Null
foreach($name in 'ui-test.ps1','runtime-input.ps1','release-policy.ps1'){
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $stage 'tests' $name)
}
Expand-Archive -LiteralPath $review3 -DestinationPath (Join-Path $stage 'review3')
Expand-Archive -LiteralPath $review4 -DestinationPath (Join-Path $stage 'review4')
[void](Test-ReleaseManifest (Join-Path $stage 'review3'))
[void](Test-ReleaseManifest (Join-Path $stage 'review4'))
$baseline=Get-Content -LiteralPath (Join-Path $repo 'docs/review3-upgrade-baseline-20260923.json') -Raw|ConvertFrom-Json
foreach($exe in @('7zFM.exe','7zG.exe')){
  $field=if($exe -eq '7zFM.exe'){'baselineFileManagerSha256'}else{'baselineGuiSha256'}
  if((Get-FileHash -LiteralPath (Join-Path $stage 'review3' $exe)).Hash -ne $baseline.$field){throw "Review3 baseline differs: $exe"}
}
foreach($dll in $baseline.dlls){
  $source=Join-Path (Join-Path $repo 'tests/b/review3-upgrade-baseline') $dll.file
  if((Get-FileHash -LiteralPath $source).Hash -ne $dll.sha256){throw "Test-only DLL differs: $($dll.file)"}
  Copy-Item -LiteralPath $source -Destination (Join-Path $stage 'review3' $dll.file)
}
Write-Host "Running isolated review3 to review4 GUI acceptance as $($identity.Name)."
Write-Host 'Please do not use the mouse or keyboard until the summary appears.'
& (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -File (Join-Path $stage 'tests/ui-test.ps1') -SevenZipDir (Join-Path $stage 'review4') -BaselineDir (Join-Path $stage 'review3') -UiLang zh-cn -KeepArtifacts
$code=$LASTEXITCODE
$result=Get-ChildItem -LiteralPath (Join-Path $stage 'tests/b') -Directory -Filter 'ui-run-*'|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
if($result){
  Write-Host "GUI evidence: $($result.FullName)"
  foreach($name in 'result.json','upgrade-rollback-result.json'){
    $path=Join-Path $result.FullName $name
    if(Test-Path -LiteralPath $path){Write-Host "$name`n$([IO.File]::ReadAllText($path))"}
  }
}
Write-Host "Standard-user acceptance exit code: $code"
exit $code
