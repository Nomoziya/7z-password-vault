# build.ps1 - build both release artifacts from the deployed package:
#
#   7-Zip-密码管家版\                     the deployed files (tests\deploy.ps1 fills it)
#   dist\7z-password-vault-26.03-win64-portable.zip     unpack and run
#   dist\7z-password-vault-26.03-win64-setup.exe        self-extracting installer
#
# The installer is a 7-Zip SFX: the stub (7z.sfx, which ships with 7-Zip), the config
# from installer\sfx-config.txt and the payload are concatenated into one .exe. It asks
# for a folder, unpacks there, runs installer\install.cmd (shortcuts + the Apps &
# features entry) and leaves the uninstaller behind. No extra toolchain is involved.
#
# Usage: pwsh -NoProfile -File installer\build.ps1

param(
  [string]$Version = "26.03",
  [string]$OutDir = "dist"
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$package = Join-Path $root "7-Zip-密码管家版"
$out = Join-Path $root $OutDir
$sevenZip = Join-Path $package "7z.exe"
$sfx = Join-Path $package "7z.sfx"
$config = Join-Path $PSScriptRoot "sfx-config.txt"

foreach ($f in $package, $sevenZip, $sfx, $config) {
  if (-not (Test-Path -LiteralPath $f)) { throw "missing: $f (run tests\deploy.ps1 first)" }
}
New-Item -ItemType Directory -Force -Path $out | Out-Null

# the installer payload carries the two scripts that do the post-install work
$staging = Join-Path $env:TEMP ("7zpw-sfx-{0}" -f (Get-Date -Format "HHmmss"))
New-Item -ItemType Directory -Force -Path $staging | Out-Null
try {
  Copy-Item -Path (Join-Path $package "*") -Destination $staging -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot "install.cmd") -Destination $staging -Force
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot "install.ps1") -Destination $staging -Force

  $payload = Join-Path $staging "..\payload.7z"
  & $sevenZip a -t7z -mx=9 -bso0 -bsp0 $payload (Join-Path $staging "*") | Out-Null
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $payload)) { throw "7z failed to build the payload" }

  $portable = Join-Path $out "7z-password-vault-$Version-win64-portable.zip"
  Remove-Item -LiteralPath $portable -Force -ErrorAction SilentlyContinue
  Compress-Archive -Path (Join-Path $package "*") -DestinationPath $portable -CompressionLevel Optimal

  $setup = Join-Path $out "7z-password-vault-$Version-win64-setup.exe"
  Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue
  $bytes = [IO.File]::ReadAllBytes($sfx) +
           [Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $config -Raw)) +
           [IO.File]::ReadAllBytes($payload)
  [IO.File]::WriteAllBytes($setup, $bytes)
} finally {
  Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
  Remove-Item -Force (Join-Path $env:TEMP "payload.7z") -ErrorAction SilentlyContinue
}

foreach ($f in $portable, $setup) {
  $i = Get-Item -LiteralPath $f
  "{0}`n  {1:N0} bytes ({2:N2} MB)`n  sha256 {3}" -f $i.Name, $i.Length, ($i.Length / 1MB),
      (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
}

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
