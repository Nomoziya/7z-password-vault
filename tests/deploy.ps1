# Deploy the freshly built binaries and language files into the distribution folder.
$ErrorActionPreference = "Stop"
$root = "D:\DSH Work\7z-passward"
$dist = Join-Path $root "7-Zip-密码管家版"

$copies = @(
  @{ src = "CPP\7zip\UI\FileManager\b\g\7zFM.exe"; dst = "7zFM.exe" },
  @{ src = "CPP\7zip\UI\GUI\b\g\7zG.exe";           dst = "7zG.exe" },
  @{ src = "Lang\en.txt";                           dst = "Lang\en.txt" },
  @{ src = "Lang\en.ttt";                           dst = "Lang\en.ttt" },
  @{ src = "Lang\zh-cn.txt";                        dst = "Lang\zh-cn.txt" },
  @{ src = "Lang\zh-tw.txt";                        dst = "Lang\zh-tw.txt" },
  @{ src = "README.md";                             dst = "README.md" },
  @{ src = "BUILD.md";                              dst = "BUILD.md" }
)
foreach ($c in $copies) {
  $from = Join-Path $root $c.src
  $to   = Join-Path $dist $c.dst
  if (-not (Test-Path $from)) { throw "missing build output: $from" }
  Copy-Item -LiteralPath $from -Destination $to -Force
  Write-Host ("  {0,-10} -> {1}" -f $c.dst, (Get-Item $to).LastWriteTime)
}
Write-Host "`nSHA-256:"
foreach ($exe in "7zFM.exe","7zG.exe") {
  $p = Join-Path $dist $exe
  "{0}  {1}" -f (Get-FileHash $p -Algorithm SHA256).Hash.ToLower(), $exe
}
