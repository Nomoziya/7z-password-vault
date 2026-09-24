# core-test.ps1 - verifies 7-Zip's own engine still works in this build.
#
# The vault work touches the password handling of 7zFM/7zG, so the archive
# engine itself has to be proven intact: create, list, test and extract, with
# and without encryption, for both archive formats this build supports.
#
# Everything here runs through 7z.exe (the command line module), so it does not
# need any UI automation and takes only a few seconds.
#
# Usage:
#   pwsh -File tests\core-test.ps1
#   pwsh -File tests\core-test.ps1 -SevenZipDir "D:\path\to\7-Zip"

param(
  [string]$SevenZipDir = '',
  [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'runtime-input.ps1')
$ownedRuntime=$null
$work=$null
try {
if(-not $SevenZipDir){
  $ownedRuntime=Join-Path $PSScriptRoot ('b\core-runtime-'+[guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $ownedRuntime -ErrorAction Stop | Out-Null
  $SevenZipDir=Resolve-TestRuntime -ExtractionRoot $ownedRuntime
}else{$SevenZipDir=Resolve-TestRuntime -Directory $SevenZipDir}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$szExe = Join-Path $SevenZipDir "7z.exe"
if (!(Test-Path $szExe)) {
  Write-Host "ERROR: 7z.exe not found in '$SevenZipDir'" -ForegroundColor Red
  exit 2
}

$work = Join-Path $env:TEMP ("7z_core_test-" + [guid]::NewGuid().ToString("N"))
$script:pass = 0
$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$extra = "") {
  if ($ok) { $script:pass++; Write-Host ("  [PASS] " + $name) -ForegroundColor Green }
  else     { $script:fail++; Write-Host ("  [FAIL] " + $name + " " + $extra) -ForegroundColor Red }
}

# Runs 7z and returns @{ Code; Out }
function Run-7z([string[]]$argv) {
  $out = & $szExe @argv 2>&1 | Out-String
  return @{ Code = $LASTEXITCODE; Out = $out }
}

function New-TestTree([string]$root) {
  if (-not ([IO.Path]::GetFullPath($root)).StartsWith([IO.Path]::GetFullPath($work) + "\", [StringComparison]::OrdinalIgnoreCase)) { throw "unsafe test tree path" }
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  Set-Content (Join-Path $root "small.txt") -Value "hello 7-zip" -Encoding UTF8
  Set-Content (Join-Path $root "空 格 名.txt") -Value "unicode name" -Encoding UTF8
  New-Item -ItemType Directory -Force -Path (Join-Path $root "sub\deep") | Out-Null
  Set-Content (Join-Path $root "sub\deep\nested.txt") -Value "nested content" -Encoding UTF8
  # a binary file, so compression and CRCs are exercised on non-text data
  $bytes = New-Object byte[] (1024 * 1024)
  (New-Object Random 12345).NextBytes($bytes)
  [IO.File]::WriteAllBytes((Join-Path $root "random.bin"), $bytes)
  # an empty file
  [IO.File]::WriteAllBytes((Join-Path $root "empty.bin"), (New-Object byte[] 0))
}

# Compares two directories by relative path + SHA-256
function Compare-Trees([string]$a, [string]$b) {
  $fa = Get-ChildItem -Recurse -File $a | ForEach-Object { $_.FullName.Substring($a.Length) }
  $fb = Get-ChildItem -Recurse -File $b | ForEach-Object { $_.FullName.Substring($b.Length) }
  if (($fa | Sort-Object) -join "|" -ne (($fb | Sort-Object) -join "|")) { return $false }
  foreach ($rel in $fa) {
    $ha = (Get-FileHash (Join-Path $a $rel) -Algorithm SHA256).Hash
    $hb = (Get-FileHash (Join-Path $b $rel) -Algorithm SHA256).Hash
    if ($ha -ne $hb) { return $false }
  }
  return $true
}

Write-Host "== setup ==" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $work | Out-Null
$src = Join-Path $work "src"
New-TestTree $src
Check "test tree created" ((Get-ChildItem -Recurse -File $src).Count -eq 5)

# ---------------------------------------------------------------- 1. plain round trip
Write-Host "`n== 1. create / list / test / extract (no password) ==" -ForegroundColor Cyan
foreach ($t in @("7z", "zip", "tar")) {
  $arc = Join-Path $work "plain.$t"
  Remove-Item $arc -Force -ErrorAction SilentlyContinue
  $r = Run-7z @("a", "-t$t", $arc, "$src\*")
  Check "$t : created" ($r.Code -eq 0) "($($r.Out.Trim()))"
  $r = Run-7z @("t", $arc)
  Check "$t : integrity test passes" ($r.Code -eq 0)
  $dest = Join-Path $work "out_plain_$t"
  Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
  $r = Run-7z @("x", $arc, "-o$dest", "-y")
  Check "$t : extracted" ($r.Code -eq 0)
  Check "$t : contents match the source" (Compare-Trees $src $dest)
}

# ---------------------------------------------------------------- 2. encrypted 7z
Write-Host "`n== 2. encrypted 7z (header encryption on) ==" -ForegroundColor Cyan
$enc = Join-Path $work "enc.7z"
Remove-Item $enc -Force -ErrorAction SilentlyContinue
$r = Run-7z @("a", "-t7z", "-pCorePw123", "-mhe=on", $enc, "$src\*")
Check "encrypted 7z created" ($r.Code -eq 0)
$r = Run-7z @("t", "-pCorePw123", $enc)
Check "correct password tests OK" ($r.Code -eq 0)
$r = Run-7z @("t", "-pWrongPw", $enc)
Check "wrong password is rejected" ($r.Code -ne 0)
# Header encryption requires a password even for listing. An omitted -p causes 7z
# to wait for terminal input and stalls unattended acceptance runs.
$r = Run-7z @("l", "-pWrongPw", $enc)
Check "encrypted headers hide the names" ($r.Code -ne 0 -and $r.Out -notmatch "small\.txt")
$dest = Join-Path $work "out_enc"
Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
$r = Run-7z @("x", "-pCorePw123", $enc, "-o$dest", "-y")
Check "encrypted 7z extracted" ($r.Code -eq 0)
Check "encrypted contents match the source" (Compare-Trees $src $dest)

# ---------------------------------------------------------------- 3. encrypted zip
Write-Host "`n== 3. encrypted zip (AES-256 and ZipCrypto) ==" -ForegroundColor Cyan
foreach ($m in @("AES256", "ZipCrypto")) {
  $zarc = Join-Path $work "enc_$m.zip"
  Remove-Item $zarc -Force -ErrorAction SilentlyContinue
  $r = Run-7z @("a", "-tzip", "-pZipPw456", "-mem=$m", $zarc, "$src\*")
  Check "zip/$m created" ($r.Code -eq 0) "($($r.Out.Trim()))"
  $r = Run-7z @("t", "-pZipPw456", $zarc)
  Check "zip/$m : correct password tests OK" ($r.Code -eq 0)
  $r = Run-7z @("t", "-pNope", $zarc)
  Check "zip/$m : wrong password is rejected" ($r.Code -ne 0)
  $dest = Join-Path $work "out_zip_$m"
  Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
  $r = Run-7z @("x", "-pZipPw456", $zarc, "-o$dest", "-y")
  Check "zip/$m : extracted" ($r.Code -eq 0)
  Check "zip/$m : contents match the source" (Compare-Trees $src $dest)
}

# ---------------------------------------------------------------- 4. damaged input
Write-Host "`n== 4. damaged archives are reported, not crashes ==" -ForegroundColor Cyan
$bad = Join-Path $work "damaged.7z"
Copy-Item $enc $bad -Force
$b = [IO.File]::ReadAllBytes($bad)
for ($i = 200; $i -lt 260 -and $i -lt $b.Length; $i++) { $b[$i] = $b[$i] -bxor 0xFF }
[IO.File]::WriteAllBytes($bad, $b)
$r = Run-7z @("t", "-pCorePw123", $bad)
Check "a corrupted archive fails the test" ($r.Code -ne 0)
$truncated = Join-Path $work "truncated.7z"
[IO.File]::WriteAllBytes($truncated, ($b[0..([Math]::Min(400, $b.Length - 1))]))
$r = Run-7z @("x", "-pCorePw123", $truncated, "-o$(Join-Path $work 'out_trunc')", "-y")
Check "a truncated archive is refused" ($r.Code -ne 0)
$notAnArchive = Join-Path $work "not-an-archive.7z"
Set-Content $notAnArchive -Value "this is not an archive" -Encoding ASCII
$r = Run-7z @("t", $notAnArchive)
Check "a non-archive file is refused" ($r.Code -ne 0)

# ---------------------------------------------------------------- 5. many entries / long names
Write-Host "`n== 5. many and awkward file names ==" -ForegroundColor Cyan
$many = Join-Path $work "many"
New-Item -ItemType Directory -Force -Path $many | Out-Null
for ($i = 1; $i -le 60; $i++) {
  Set-Content (Join-Path $many ("file_{0:D3}.txt" -f $i)) -Value "content $i" -Encoding UTF8
}
$longName = Join-Path $many ("L" * 120 + ".txt")
Set-Content $longName -Value "long name" -Encoding UTF8
$manyArc = Join-Path $work "many.7z"
Remove-Item $manyArc -Force -ErrorAction SilentlyContinue
$r = Run-7z @("a", "-t7z", "-pManyPw", "-mhe=on", $manyArc, "$many\*")
Check "60+ files archived" ($r.Code -eq 0)
$r = Run-7z @("t", "-pManyPw", $manyArc)
Check "60+ files test OK" ($r.Code -eq 0)
$dest = Join-Path $work "out_many"
Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
$r = Run-7z @("x", "-pManyPw", $manyArc, "-o$dest", "-y")
Check "60+ files extracted" ($r.Code -eq 0)
Check "60+ files match the source" (Compare-Trees $many $dest)

# ---------------------------------------------------------------- 6. storing a password only
Write-Host "`n== 6. encryption only where asked ==" -ForegroundColor Cyan
$mixed = Join-Path $work "mixed.7z"
Remove-Item $mixed -Force -ErrorAction SilentlyContinue
$r = Run-7z @("a", "-t7z", $mixed, "$src\*")
Check "an archive without -p is created" ($r.Code -eq 0)
$r = Run-7z @("t", $mixed)
Check "an archive without -p needs no password" ($r.Code -eq 0)
$r = Run-7z @("t", "-pSomePw", $mixed)
Check "a password on an unencrypted archive is not fatal" ($r.Code -eq 0)

Write-Host "`n== summary ==" -ForegroundColor Cyan
Write-Host ("  passed: {0}   failed: {1}" -f $script:pass, $script:fail)
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
} finally {
if (-not $KeepArtifacts -and $work -and (Test-Path -LiteralPath $work)) {
  if (-not ([IO.Path]::GetFullPath($work)).StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd("\") + "\7z_core_test-", [StringComparison]::OrdinalIgnoreCase)) { throw "unsafe test cleanup" }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if($ownedRuntime -and (Test-Path -LiteralPath $ownedRuntime)){
  if($KeepArtifacts){Write-Host "Runtime retained: $ownedRuntime"}
  else {
    $base=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'b')).TrimEnd('\')+'\'
    $target=[IO.Path]::GetFullPath($ownedRuntime)
    if(-not $target.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($target) -notmatch '^core-runtime-[a-f0-9]{32}$'){throw 'Unsafe runtime cleanup path'}
    $ancestor=Get-Item -LiteralPath $target -Force
    while($ancestor){if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Runtime cleanup refused reparse ancestor'};$ancestor=$ancestor.Parent}
    if(@(Get-ChildItem -LiteralPath $target -Recurse -Force | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Runtime cleanup refused reparse child'}
    try{Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop;Write-Host "Runtime cleaned: $target"}catch{Write-Warning "Runtime cleanup failed: $target : $_";throw}
  }
}
}
