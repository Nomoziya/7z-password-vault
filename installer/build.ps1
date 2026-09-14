# build.ps1 - build the release artifact from the deployed package:
#
#   7-Zip-密码管家版\                     the deployed files (tests\deploy.ps1 fills it)
#   dist\7z-password-vault-26.03-win64-portable.zip     unpack and run - the published download
#   dist\7z-password-vault-26.03-win64-setup.exe        self-extracting package (with -WithSetup)
#
# The portable zip is the only published download. The self-extracting package is built on
# request only: measured on VirusTotal, the wrapper itself costs detections - Elastic and
# CrowdStrike flag the SFX shape even when the payload is clean on its own (probes A1/A2/A3 in
# docs/vt-attribution.md) - and the program's first start now does everything the wrapper was
# supposed to do (shortcuts and the "Apps & features" entry, current user only, after asking).
#
# The SFX is a concatenation of the stub (7z.sfx, shipped with 7-Zip), the config from
# installer\sfx-config.txt and the payload. It does NOT run installer\install.cmd after
# unpacking and it cannot: the official 7z.sfx stub does not read an SFX configuration at all
# (measured: RunProgram and InstallPath are ignored, and the stub contains no
# @Install@/RunProgram strings - those belong to 7zSD.sfx from the LZMA SDK).
#
# Usage: pwsh -NoProfile -File installer\build.ps1
#        pwsh -NoProfile -File installer\build.ps1 -WithSetup

param(
  [string]$Version = "26.03",
  [string]$OutDir = "dist",
  [switch]$WithSetup
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$package = Join-Path $root "7-Zip-密码管家版"
$out = if ([IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $root $OutDir }
$sevenZip = Join-Path $package "7z.exe"
$sfx = Join-Path $package "7z.sfx"
$config = Join-Path $PSScriptRoot "sfx-config.txt"

$needed = @($package, $sevenZip)
if ($WithSetup) { $needed += @($sfx, $config) }
foreach ($f in $needed) {
  if (-not (Test-Path -LiteralPath $f)) { throw "missing: $f (run tests\deploy.ps1 first)" }
}
New-Item -ItemType Directory -Force -Path $out | Out-Null

$portable = Join-Path $out "7z-password-vault-$Version-win64-portable.zip"
$setup = Join-Path $out "7z-password-vault-$Version-win64-setup.exe"

Remove-Item -LiteralPath $portable -Force -ErrorAction SilentlyContinue
# Compress-Archive over the deployed folder: the hash list inside it was written by
# tests\deploy.ps1 after every file was copied, so it covers the whole package - including
# install.cmd / install.ps1, which the portable download now carries as the manual entry
# point for the shortcuts.
Compress-Archive -Path (Join-Path $package "*") -DestinationPath $portable -CompressionLevel Optimal

if ($WithSetup) {
  $staging = Join-Path $env:TEMP ("7zpw-sfx-{0}" -f (Get-Date -Format "HHmmss"))
  New-Item -ItemType Directory -Force -Path $staging | Out-Null
  try {
    Copy-Item -Path (Join-Path $package "*") -Destination $staging -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "install.cmd") -Destination $staging -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "install.ps1") -Destination $staging -Force

    # The hash list must describe the payload as it is packed: it is what the uninstaller uses
    # to tell the package's own files from someone else's. The package folder already has one
    # from tests\deploy.ps1; it is written again here so that a staging copy stays consistent
    # even if files were added above.
    $manifest = Join-Path $staging "SHA256SUMS.txt"
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# 7-Zip Password Vault 26.03 - SHA-256 of every file in this package")
    Get-ChildItem -LiteralPath $staging -Recurse -File |
      Where-Object { $_.Name -ne "SHA256SUMS.txt" } |
      Sort-Object FullName |
      ForEach-Object {
        $rel = $_.FullName.Substring($staging.Length + 1)
        $lines.Add(("{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower(), $rel))
      }
    [IO.File]::WriteAllLines($manifest, $lines, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host ("  payload hash list rebuilt ({0} files)" -f ($lines.Count - 1))

    $payload = Join-Path $staging "..\payload.7z"
    & $sevenZip a -t7z -mx=9 -bso0 -bsp0 $payload (Join-Path $staging "*") | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $payload)) { throw "7z failed to build the payload" }

    Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue
    $bytes = [IO.File]::ReadAllBytes($sfx) +
             [Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $config -Raw)) +
             [IO.File]::ReadAllBytes($payload)
    [IO.File]::WriteAllBytes($setup, $bytes)
  } finally {
    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $env:TEMP "payload.7z") -ErrorAction SilentlyContinue
  }
}

foreach ($f in @($portable) + @(if ($WithSetup) { $setup })) {
  $i = Get-Item -LiteralPath $f
  "{0}`n  {1:N0} bytes ({2:N2} MB)`n  sha256 {3}" -f $i.Name, $i.Length, ($i.Length / 1MB),
      (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
}

if ($WithSetup) {
  # verify the installer really holds the package (an SFX is a 7z archive with a stub)
  $check = Join-Path $env:TEMP ("7zpw-sfx-check-{0}" -f (Get-Date -Format "HHmmss"))
  try {
    & $sevenZip l -bso0 -bsp0 $setup | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "the installer could not be read back as a 7z archive" }
    & $sevenZip x -bso0 -bsp0 -o"$check" $setup | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "the installer payload could not be extracted" }
    $exe = Join-Path $check "7zFM.exe"
    $same = (Test-Path -LiteralPath $exe) -and
            ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath (Join-Path $package "7zFM.exe") -Algorithm SHA256).Hash)
    Write-Host ("installer payload check: 7zFM.exe present and identical = {0}" -f $same)
    if (-not $same) { throw "the installer payload does not match the package" }
  } finally {
    Remove-Item -Recurse -Force $check -ErrorAction SilentlyContinue
  }
} else {
  # the published download is the zip, so check that it really opens and holds the package
  $check = Join-Path $env:TEMP ("7zpw-zip-check-{0}" -f (Get-Date -Format "HHmmss"))
  try {
    & $sevenZip x -bso0 -bsp0 -o"$check" $portable | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "the portable zip could not be extracted" }
    $exe = Join-Path $check "7zFM.exe"
    $same = (Test-Path -LiteralPath $exe) -and
            ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath (Join-Path $package "7zFM.exe") -Algorithm SHA256).Hash)
    Write-Host ("portable zip check: 7zFM.exe present and identical = {0}" -f $same)
    if (-not $same) { throw "the portable zip does not match the package" }
  } finally {
    Remove-Item -Recurse -Force $check -ErrorAction SilentlyContinue
  }
}
