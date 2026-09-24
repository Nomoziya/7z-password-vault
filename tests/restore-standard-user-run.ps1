# Run from the separate standard-user desktop. Keeps evidence in a unique local
# directory and copies only result JSON files to a unique Public Documents folder.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'release-policy.ps1')
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
    @($identity.Groups | ForEach-Object Value) -contains 'S-1-5-32-544') {
  throw 'Use a separate standard-user account such as cs, not an administrator account with UAC filtered.'
}
$packages = @(
  @{ relative='dist/restore-release-20260924/7z-password-vault-1.6.0-restore-dev4-win64-internal-test.zip'; hash='4b95dcb15d27a0db61f7cd3372855133f46ff43da8457180777e18ff39b0506b'; folder='candidate' },
  @{ relative='dist/v1.5.0-20260924/7z-password-vault-1.5.0-win64-portable.zip'; hash='81f9c9b16e91c07ccb353c3390c03396e4566f20f5acde0a5338941f6f8739b8'; folder='baseline' }
)
foreach ($package in $packages) {
  $zip = Join-Path $repo $package.relative
  if ((Get-FileHash -LiteralPath $zip).Hash -ne $package.hash) { throw "Frozen package hash differs: $zip" }
  if ([IO.File]::ReadAllText($zip+'.sha256').Trim() -ne ($package.hash+'  '+[IO.Path]::GetFileName($zip))) {
    throw "Sidecar differs: $zip"
  }
}
$stage = Join-Path $env:LOCALAPPDATA ('7zpw-restore-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $stage 'tests/b') -Force | Out-Null
foreach ($name in 'ui-test.ps1','core-test.ps1','runtime-input.ps1','release-policy.ps1') {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $stage 'tests' $name)
}
foreach ($package in $packages) {
  Expand-Archive -LiteralPath (Join-Path $repo $package.relative) -DestinationPath (Join-Path $stage $package.folder)
  [void](Test-ReleaseManifest (Join-Path $stage $package.folder))
}
$hostExe = (Get-Command pwsh -ErrorAction Stop).Source
$coreLog = Join-Path $stage 'core.log'
& $hostExe -NoProfile -File (Join-Path $stage 'tests/core-test.ps1') -SevenZipDir (Join-Path $stage 'candidate') 2>&1 | Tee-Object -FilePath $coreLog
$coreExit = $LASTEXITCODE
if ($coreExit -ne 0) { throw "Core test failed: exit=$coreExit; log=$coreLog" }
Write-Host "Running restore and v1.5.0 upgrade/rollback acceptance as $($identity.Name)."
Write-Host 'Please leave the mouse and keyboard alone until the summary appears.'
$guiLog = Join-Path $stage 'gui.log'
& $hostExe -NoProfile -File (Join-Path $stage 'tests/ui-test.ps1') -SevenZipDir (Join-Path $stage 'candidate') -BaselineDir (Join-Path $stage 'baseline') -UiLang zh-cn -KeepArtifacts 2>&1 | Tee-Object -FilePath $guiLog
$guiExit = $LASTEXITCODE
$runs = @(Get-ChildItem -LiteralPath (Join-Path $stage 'tests/b') -Directory -Filter 'ui-run-*')
if ($runs.Count -ne 1) { throw "Expected exactly one GUI evidence directory under $stage; found $($runs.Count)" }
$public = Join-Path ([Environment]::GetFolderPath('CommonDocuments')) ('7zpw-restore-evidence-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $public | Out-Null
$crossManifest=Join-Path $repo 'tests/b/cross-account-seed-c383a72dc940408095fa53d2e46a5fad/seed.json'
& $hostExe -NoProfile -File (Join-Path $PSScriptRoot 'restore-cross-account-test.ps1') -SeedManifest $crossManifest -OutputDirectory $public
$crossExit=$LASTEXITCODE
foreach ($name in 'result.json','upgrade-rollback-result.json') {
  $path = Join-Path $runs[0].FullName $name
  if (Test-Path -LiteralPath $path) {
    Copy-Item -LiteralPath $path -Destination (Join-Path $public $name)
    Write-Host $name
    Get-Content -LiteralPath $path -Raw
  }
}
[ordered]@{
  account=$identity.Name; windowsBuild=[Environment]::OSVersion.Version.ToString()
  standardAccount=$true; coreExitCode=$coreExit; guiExitCode=$guiExit; crossAccountExitCode=$crossExit
  coreLogSha256=(Get-FileHash -LiteralPath $coreLog).Hash
  guiLogSha256=(Get-FileHash -LiteralPath $guiLog).Hash
  packages=$packages; stage=$stage; finishedUtc=[DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $public 'acceptance.json') -Encoding utf8
Write-Host "Shared evidence: $public"
$finalExit=if($guiExit){$guiExit}else{$crossExit}
Write-Host "Standard-user acceptance exit code: $finalExit"
exit $finalExit
