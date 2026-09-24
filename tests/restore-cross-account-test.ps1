param([Parameter(Mandatory)][string]$SeedManifest,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$manifest=Get-Content -LiteralPath $SeedManifest -Raw | ConvertFrom-Json
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.User.Value -eq $manifest.accountSid) { throw 'Cross-account rejection must run as a different Windows account from the seed creator.' }
$exe=$manifest.nativeTestExe
if ((Get-FileHash -LiteralPath $exe).Hash -ne $manifest.nativeTestExeSha256) { throw 'Native test EXE differs from seed manifest.' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$fixture=Join-Path $env:LOCALAPPDATA ('7zpw-cross-account-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$path=Join-Path $fixture 'vault.dat'
$record=[ordered]@{classification='TEST_FAILURE';account=$identity.Name;accountSid=$identity.User.Value;seedAccount=$manifest.account;seedAccountSid=$manifest.accountSid;nativeTestExeSha256=$manifest.nativeTestExeSha256;scriptSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;seedManifestSha256=(Get-FileHash -LiteralPath $SeedManifest).Hash;startedUtc=[DateTime]::UtcNow.ToString('o');exitCode=1}
try {
  foreach($file in $manifest.files) {
    if($file.name -notin @('vault.dat','vault.dat.bak')) { throw 'Unexpected seed file name.' }
    $source=Join-Path (Split-Path $SeedManifest -Parent) $file.name
    if((Get-FileHash -LiteralPath $source).Hash -ne $file.sha256) { throw 'Seed ciphertext hash mismatch.' }
    Copy-Item -LiteralPath $source -Destination (Join-Path $fixture $file.name)
  }
  # Demonstrate this account's own real DPAPI works before testing foreign data.
  try {
    $plain=[Text.Encoding]::UTF8.GetBytes('cross-account-self-probe')
    $blob=[Security.Cryptography.ProtectedData]::Protect($plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    $opened=[Security.Cryptography.ProtectedData]::Unprotect($blob,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    if([Convert]::ToBase64String($opened) -ne [Convert]::ToBase64String($plain)) { throw 'DPAPI roundtrip mismatch.' }
    $record.ownDpapi='PASS'
  } catch {
    $record.classification='ENVIRONMENT_BLOCKED';$record.exitCode=78
    throw "Own-account DPAPI is unavailable: $($_.Exception.Message)"
  }
  $log=Join-Path $OutputDirectory 'cross-account.log'
  & $exe cross-account-reject $path 2>&1 | Tee-Object -FilePath $log
  $record.exitCode=$LASTEXITCODE
  $record.logSha256=(Get-FileHash -LiteralPath $log).Hash
  if($record.exitCode) { throw "Foreign DPAPI rejection test failed: $($record.exitCode)" }
  foreach($file in $manifest.files) { if((Get-FileHash -LiteralPath (Join-Path $fixture $file.name)).Hash -ne $file.sha256) { throw 'Rejection modified ciphertext.' } }
  $record.classification='PASS';$record.exitCode=0
} catch {
  $record.error=$_.Exception.Message
  if($record.classification -ne 'ENVIRONMENT_BLOCKED') { $record.exitCode=1 }
} finally {
  $record.finishedUtc=[DateTime]::UtcNow.ToString('o')
  $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'cross-account-result.json') -Encoding utf8
  $record | ConvertTo-Json -Depth 4 | Write-Host
  # This unique directory belongs only to this invocation. Never traverse links.
  $full=[IO.Path]::GetFullPath($fixture)
  $root=[IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')+'\'
  if(!$full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or
     (Get-Item -LiteralPath $full).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe cross-account fixture cleanup path.' }
  foreach($entry in Get-ChildItem -LiteralPath $full -Force) {
    if($entry.PSIsContainer -or $entry.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw 'Unexpected fixture entry; retained for inspection.' }
    Remove-Item -LiteralPath $entry.FullName -Force
  }
  Remove-Item -LiteralPath $full
}
exit $record.exitCode
