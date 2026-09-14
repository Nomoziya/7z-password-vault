# Deploy the freshly built binaries and language files into the distribution folder.
$ErrorActionPreference = "Stop"
$root = "D:\DSH Work\7z-passward"
$dist = Join-Path $root "7-Zip-密码管家版"

# A vault file in the build output is a test leftover - and if it ever held real entries
# it would be published with the package. Stop here instead of shipping it.
$strayVaults = @(Get-ChildItem -LiteralPath $dist -Filter "*.dat" -File -ErrorAction SilentlyContinue)
if ($strayVaults.Count -gt 0) {
  foreach ($v in $strayVaults) { Write-Host ("  stray vault in the output folder: {0} ({1} bytes)" -f $v.FullName, $v.Length) -ForegroundColor Yellow }
  throw "delete the .dat file(s) in '$dist' first - a vault must not be shipped"
}

$copies = @(
  @{ src = "CPP\7zip\UI\FileManager\b\g\7zFM.exe"; dst = "7zFM.exe" },
  @{ src = "CPP\7zip\UI\GUI\b\g\7zG.exe";           dst = "7zG.exe" },
  @{ src = "Lang\en.txt";                           dst = "Lang\en.txt" },
  @{ src = "Lang\en.ttt";                           dst = "Lang\en.ttt" },
  @{ src = "Lang\zh-cn.txt";                        dst = "Lang\zh-cn.txt" },
  @{ src = "Lang\zh-tw.txt";                        dst = "Lang\zh-tw.txt" },
  @{ src = "README.md";                             dst = "README.md" },
  @{ src = "BUILD.md";                              dst = "BUILD.md" },
  @{ src = "tools\uninstall.ps1";                   dst = "uninstall.ps1" },
  @{ src = "tools\uninstall.cmd";                   dst = "uninstall.cmd" }
)
foreach ($c in $copies) {
  $from = Join-Path $root $c.src
  $to   = Join-Path $dist $c.dst
  if (-not (Test-Path $from)) { throw "missing build output: $from" }
  Copy-Item -LiteralPath $from -Destination $to -Force
  Write-Host ("  {0,-10} -> {1}" -f $c.dst, (Get-Item $to).LastWriteTime)
}
# A hash list ships with the package: it is what can be checked after a download and
# what the uninstaller can use to tell our files from someone else's.
$manifest = Join-Path $dist "SHA256SUMS.txt"
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# 7-Zip Password Vault 26.03 - SHA-256 of every file in this package")
Get-ChildItem -LiteralPath $dist -Recurse -File |
  Where-Object { $_.Name -ne "SHA256SUMS.txt" } |
  Sort-Object FullName |
  ForEach-Object {
    $rel = $_.FullName.Substring($dist.Length + 1)
    $lines.Add(("{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower(), $rel))
  }
# BOM: Windows PowerShell 5.1 reads a UTF-8 file without a BOM as ANSI, and the
# package paths contain non-ASCII names (the folder itself is 7-Zip-密码管家版).
[IO.File]::WriteAllLines($manifest, $lines, (New-Object System.Text.UTF8Encoding($true)))
Write-Host ("  SHA256SUMS.txt written ({0} files)" -f ($lines.Count - 1))

Write-Host "`nSHA-256:"
foreach ($exe in "7zFM.exe","7zG.exe") {
  $p = Join-Path $dist $exe
  "{0}  {1}" -f (Get-FileHash $p -Algorithm SHA256).Hash.ToLower(), $exe
}
