# install-acceptance.ps1 - end-to-end acceptance test for the self-extracting installer
# (dist\7z-password-vault-26.03-win64-setup.exe) and for the uninstaller that ships in it.
#
# What it does:
#   phase 0  extract the payload of the setup.exe into a unique folder under %TEMP%
#            (with the 7z.exe that ships in the package). The SFX stub is never started,
#            so no GUI appears and no SFX RunProgram runs.
#   phase 1  check the extracted file set, every hash in SHA256SUMS.txt, and the
#            payload-vs-manifest gap (install.cmd / install.ps1 are NOT in the manifest)
#   phase 2  install into an isolated folder and look at what install.cmd / install.ps1
#            write into HKCU (only with -IncludeRegistry)
#   phase 3  uninstall from that isolated folder and assert that the folder, the
#            "Apps & features" entry and the package files (uninstall.cmd, uninstall.ps1,
#            install.cmd, install.ps1, SHA256SUMS.txt) are really gone (only with -IncludeRegistry)
#   phase 4  the same uninstaller without a hash list (the by-name fallback) and the
#            shared-folder rule: a same-named file with another hash must survive
#
# Nothing outside %TEMP% is written by default. The registry phases are off unless
# -IncludeRegistry is given, because install.ps1 and uninstall.ps1 work on the real
# per-user keys; with the switch, HKCU\Software\7-Zip and the Apps & features entry are
# snapshotted first and put back in a finally block, the same way tests\uninstall-test.ps1
# does it. A 7-Zip that is running while the registry phases run can write its settings
# between the snapshot and the restore.
#
# Usage:
#   pwsh -NoProfile -File tests\install-acceptance.ps1
#   pwsh -NoProfile -File tests\install-acceptance.ps1 -Package "D:\dist\...setup.exe"
#   pwsh -NoProfile -File tests\install-acceptance.ps1 -IncludeRegistry
#   pwsh -NoProfile -File tests\install-acceptance.ps1 -IncludeRegistry -Strict
#   pwsh -NoProfile -File tests\install-acceptance.ps1 -IncludeShortcuts    # writes .lnk files
#   pwsh -NoProfile -File tests\install-acceptance.ps1 -KeepArtifacts
#
# Exit code: 0 = no check failed (warnings allowed), 1 = a check failed (-Strict also fails
#            on warnings), 2 = the run could not start (no package / no extractor).

param(
  [string]$Package = "",
  [string]$PackageDir = "",
  [switch]$IncludeRegistry,
  [switch]$IncludeShortcuts,
  [switch]$Strict,
  [switch]$KeepArtifacts,
  [int]$WriteWaitSeconds = 20
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root = Split-Path $PSScriptRoot -Parent
if (-not $PackageDir) { $PackageDir = Join-Path $root "7-Zip-密码管家版" }
if (-not $Package) { $Package = Join-Path $root "dist\7z-password-vault-26.03-win64-setup.exe" }

$work = Join-Path $env:TEMP ("7zpw-install-acceptance-{0}-{1}" -f (Get-Date -Format "HHmmss"), $PID)
$extractDir = Join-Path $work "payload"
$regRoot = "HKCU:\Software\7-Zip"
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\7ZipPasswordVault"
$roamingDir = Join-Path $env:APPDATA "7-Zip"
$roamingVault = Join-Path $roamingDir "7zPasswordVault.dat"
$startMenuLink = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\7-Zip Password Vault.lnk"
$desktopLink = Join-Path ([Environment]::GetFolderPath("Desktop")) "7-Zip Password Vault.lnk"

# ------------------------------------------------------------------ output helpers
$script:pass = 0
$script:fail = 0
$script:warn = 0
function Check([string]$name, [bool]$ok, [string]$extra = "") {
  if ($ok) { $script:pass++; Write-Host ("  [PASS] " + $name) -ForegroundColor Green }
  else     { $script:fail++; Write-Host ("  [FAIL] " + $name + " " + $extra) -ForegroundColor Red }
}
function Warn([string]$name, [string]$extra = "") {
  $script:warn++
  Write-Host ("  [WARN] " + $name + " " + $extra) -ForegroundColor Yellow
}
function Skip-Phase([string]$name, [string]$why) {
  Write-Host ("  [SKIP] " + $name + " - " + $why) -ForegroundColor DarkGray
}
function Head([string]$title) { Write-Host ("`n== " + $title + " ==") -ForegroundColor Cyan }

# ------------------------------------------------------------------ process helpers
# A native command returning non-zero is normal here (7z, reg, cmd), and
# $ErrorActionPreference = "Stop" would turn that into a terminating error.
$script:lastExit = -1
function Invoke-Native([string]$exe, [string[]]$argv) {
  $out = ""
  try {
    $out = & $exe @argv 2>&1 | Out-String
    $script:lastExit = $LASTEXITCODE
  } catch {
    $out = "$out`n$($_.Exception.Message)"
    $script:lastExit = -1
  }
  return $out
}
# A batch launcher must not be able to wait for a keypress, so stdin comes from a file.
# Output goes through files, which also keeps a long dump out of the console.
function Invoke-Capture([string]$exe, [string[]]$argv, [string]$cwd, [string]$stdinFile, [int]$timeoutSec = 240) {
  $stdout = Join-Path $work ("cap-out-{0}.txt" -f (Get-Random))
  $stderr = Join-Path $work ("cap-err-{0}.txt" -f (Get-Random))
  $p = Start-Process -FilePath $exe -ArgumentList $argv -WorkingDirectory $cwd `
       -RedirectStandardInput $stdinFile -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
       -NoNewWindow -PassThru
  if (-not $p.WaitForExit($timeoutSec * 1000)) {
    try { $p.Kill() } catch { }
    return @{ Code = -2; Out = "timeout after $timeoutSec s" }
  }
  $text = ""
  foreach ($f in $stdout, $stderr) {
    if (Test-Path -LiteralPath $f) { $text += (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue) }
  }
  return @{ Code = $p.ExitCode; Out = $text }
}

# ------------------------------------------------------------------ file helpers
function Get-Sha256([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }

# The manifest holds non-ASCII-free paths, but it is UTF-8 and Windows PowerShell 5.1
# reads a BOM-less UTF-8 file as ANSI, so the encoding is decided by the first bytes.
function Read-SumFile([string]$path) {
  $bytes = [IO.File]::ReadAllBytes($path)
  $text = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
  } else { [Text.Encoding]::UTF8.GetString($bytes) }
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($line in ($text -split "`r?`n")) {
    if ($line -match '^\s*#' -or $line.Trim() -eq "") { continue }
    $parts = $line -split '\s+', 2
    if ($parts.Count -ne 2) { continue }
    $list.Add(@{ hash = $parts[0].Trim().ToLower(); rel = $parts[1].Trim().Replace("/", "\") })
  }
  return $list
}
function Get-RelativePaths([string]$dir, [string[]]$excludeNames = @()) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File -Force)) {
    if ($excludeNames -contains $f.Name) { continue }
    $out.Add($f.FullName.Substring($dir.Length + 1))
  }
  return $out
}
function Get-MissingFrom([string[]]$source, [string[]]$reference) {
  $set = @{}
  foreach ($x in $reference) { $set[$x.ToLower()] = $true }
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($x in $source) { if (-not $set.ContainsKey($x.ToLower())) { $out.Add($x) } }
  return $out
}
# Writes SHA256SUMS.txt the way tests\deploy.ps1 does: every file except the list itself.
function Write-SumFile([string]$dir, [string[]]$skipRel) {
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# acceptance test hash list")
  foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File -Force | Sort-Object FullName)) {
    $rel = $f.FullName.Substring($dir.Length + 1)
    if ($rel -ieq "SHA256SUMS.txt" -or $skipRel -contains $rel) { continue }
    $lines.Add(("{0}  {1}" -f (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower(), $rel))
  }
  Set-Content -LiteralPath (Join-Path $dir "SHA256SUMS.txt") -Value $lines -Encoding UTF8
}
function Wait-Gone([string]$path, [int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    if (-not (Test-Path -LiteralPath $path)) { return $true }
    Start-Sleep -Milliseconds 300
  }
  return (-not (Test-Path -LiteralPath $path))
}
function Get-RelativeList([string]$dir) {
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  return @(Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue |
           ForEach-Object { $_.FullName.Substring($dir.Length + 1) })
}

# ------------------------------------------------------------------ registry helpers
# A value snapshot, not reg save: that needs SeBackupPrivilege. tests\ui-test.ps1 uses the
# same technique for HKCU\Software\7-Zip.
function Get-KeyBag([string]$key) {
  if (-not (Test-Path -LiteralPath $key)) { return $null }
  $bag = @{}
  foreach ($prop in (Get-ItemProperty -LiteralPath $key).PSObject.Properties) {
    if ($prop.Name -like "PS*") { continue }
    $bag[$prop.Name] = $prop.Value
  }
  return $bag
}
function Set-KeyBag([string]$key, $bag) {
  Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
  if ($null -eq $bag) { return }
  New-Item -Path $key -Force | Out-Null
  foreach ($name in $bag.Keys) {
    $value = $bag[$name]
    $type = if ($value -is [int] -or $value -is [long]) { "DWord" } else { "String" }
    Set-ItemProperty -Path $key -Name $name -Value $value -Type $type
  }
}

$script:bagRegRoot = $null
$script:bagUninstall = $null
$script:hadRoamingVault = $false
$script:rescueBefore = @()
$script:preLinks = @()

# ================================================================== preconditions
Write-Host "7-Zip Password Vault - installer acceptance test" -ForegroundColor White
Write-Host ("  package   : {0}" -f $Package) -ForegroundColor Gray
Write-Host ("  packageDir: {0}" -f $PackageDir) -ForegroundColor Gray
Write-Host ("  work      : {0}" -f $work) -ForegroundColor Gray
Write-Host ("  registry  : {0}" -f $(if ($IncludeRegistry) { "INCLUDED (HKCU is snapshotted and restored)" } else { "not touched (pass -IncludeRegistry)" })) `
  -ForegroundColor $(if ($IncludeRegistry) { "Yellow" } else { "Gray" })

$sevenZip = Join-Path $PackageDir "7z.exe"
if (-not (Test-Path -LiteralPath $Package)) {
  Write-Host "ERROR: no installer package at '$Package'" -ForegroundColor Red
  Write-Host "       build it with: pwsh -NoProfile -File installer\build.ps1" -ForegroundColor Red
  exit 2
}
if (-not (Test-Path -LiteralPath $sevenZip)) {
  Write-Host "ERROR: no extractor at '$sevenZip' (the deployed package holds one)" -ForegroundColor Red
  exit 2
}

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work, $extractDir | Out-Null
$nul = Join-Path $work "nul.txt"
Set-Content -LiteralPath $nul -Value "" -Encoding ASCII

try {
  # ================================================================ phase 0: unpack
  Head "0. unpack the installer payload (the SFX stub is not started)"
  $privateZip = Join-Path $work "7z.exe"
  Copy-Item -LiteralPath $sevenZip -Destination $privateZip -Force
  $sevenZip = $privateZip   # a private copy cannot be locked by another process
  $t0 = Get-Date
  $out = Invoke-Native $sevenZip @("x", "-y", "-bso0", "-bsp0", "-o$extractDir", $Package)
  $seconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  Check "the package extracts with the bundled 7z.exe" ($script:lastExit -eq 0) "(7z exit $($script:lastExit): $($out.Trim()))"
  $payloadFiles = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File -Force)
  Check "the payload is not empty" ($payloadFiles.Count -gt 0) "(0 files in $extractDir)"
  if ($payloadFiles.Count -eq 0) { throw "nothing was extracted - the rest of the test cannot run" }
  Write-Host ("        {0} files extracted in {1} s" -f $payloadFiles.Count, $seconds) -ForegroundColor DarkGray

  # also prove the archive can be *listed* by the same tool (an SFX is a 7z with a stub)
  $out = Invoke-Native $sevenZip @("l", "-bso0", "-bsp0", $Package)
  Check "the installer can be read back as a 7z archive" ($script:lastExit -eq 0) "(7z l exit $($script:lastExit))"

  # ================================================================ phase 1: payload
  Head "1. payload vs. the hash list that ships inside it"
  $manifestPath = Join-Path $extractDir "SHA256SUMS.txt"
  $exeFm = Join-Path $extractDir "7zFM.exe"
  $exeG = Join-Path $extractDir "7zG.exe"
  $exeCli = Join-Path $extractDir "7z.exe"
  $uninstPs1 = Join-Path $extractDir "uninstall.ps1"
  $uninstCmd = Join-Path $extractDir "uninstall.cmd"
  $installCmd = Join-Path $extractDir "install.cmd"
  $installPs1 = Join-Path $extractDir "install.ps1"
  foreach ($f in $manifestPath, $exeFm, $exeG, $exeCli, $uninstPs1, $uninstCmd, $installCmd, $installPs1) {
    Check ("the payload contains {0}" -f (Split-Path $f -Leaf)) (Test-Path -LiteralPath $f)
  }

  # ---- the file set: compared in both directions, because the gap is the point here
  # SHA256SUMS.txt never lists itself (tests\deploy.ps1 excludes it), so it is not a gap.
  $expectedGaps = @("install.cmd", "install.ps1")
  $entries = @()
  if (Test-Path -LiteralPath $manifestPath) { $entries = @(Read-SumFile $manifestPath) }
  $listedRel = @($entries | ForEach-Object { $_.rel })
  $actualRel = @(Get-RelativePaths $extractDir @("SHA256SUMS.txt"))

  $notListed = @(Get-MissingFrom $actualRel $listedRel)
  $notPresent = @(Get-MissingFrom $listedRel $actualRel)
  $unexpectedGap = @($notListed | Where-Object { $expectedGaps -notcontains $_ })
  $expectedGapPresent = @($expectedGaps | Where-Object { $notListed -contains $_ })

  Check "the manifest names no file that is missing from the payload" ($notPresent.Count -eq 0) `
    "(listed but absent: $($notPresent -join ', '))"
  Check "the payload holds no file the manifest does not know, apart from the two installer scripts" `
    ($unexpectedGap.Count -eq 0) "(not listed: $($notListed -join ', '))"
  Write-Host ("        payload {0} files, manifest {1} entries" -f $actualRel.Count, $entries.Count) -ForegroundColor DarkGray

  if ($expectedGapPresent.Count -eq 0) {
    Check "install.cmd / install.ps1 are in SHA256SUMS.txt (the payload/manifest gap is closed)" $true
  } else {
    Warn ("{0} payload file(s) are missing from SHA256SUMS.txt: {1}" -f $expectedGapPresent.Count, ($expectedGapPresent -join ", ")) `
      "- open defect: the uninstaller deletes install.cmd/install.ps1 by name, so a same-named file of another package in the same folder would be removed"
  }

  # ---- every listed hash has to match the file it names
  $missing = New-Object System.Collections.Generic.List[string]
  $bad = New-Object System.Collections.Generic.List[string]
  $checked = 0
  foreach ($e in $entries) {
    if ($e.rel -match '\.\.' -or $e.rel.StartsWith("\") -or $e.rel -match '^[A-Za-z]:') { $bad.Add("$($e.rel) (rejected path)"); continue }
    $full = Join-Path $extractDir $e.rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $missing.Add($e.rel); continue }
    $checked++
    if ((Get-Sha256 $full) -ne $e.hash) { $bad.Add($e.rel) }
  }
  Check "every file named in the manifest is present" ($missing.Count -eq 0) "(missing: $($missing -join ', '))"
  Check ("all {0} listed hashes match the extracted file" -f $checked) ($bad.Count -eq 0) "(wrong hash/path: $($bad -join ', '))"

  # ---- the two executables are byte-identical to the deployed package
  foreach ($name in "7zFM.exe", "7zG.exe") {
    $a = Join-Path $extractDir $name
    $b = Join-Path $PackageDir $name
    if ((Test-Path -LiteralPath $a) -and (Test-Path -LiteralPath $b)) {
      Check ("{0} in the payload is byte-identical to the packaged build" -f $name) ((Get-Sha256 $a) -eq (Get-Sha256 $b))
    } else { Check ("{0} can be compared with the package" -f $name) $false "(one of the two copies is missing)" }
  }

  # ---- what the "Apps & features" entry will show, read from the script itself
  if (Test-Path -LiteralPath $installPs1) {
    $t = Get-Content -LiteralPath $installPs1 -Raw
    Check "install.ps1 sets a DisplayName" ($t -match 'DisplayName\s*=') "(no DisplayName)"
    Check "install.ps1 sets a DisplayVersion of the form x.y.z" ($t -match 'DisplayVersion\s*=\s*"\d+\.\d+\.\d+"') "(no DisplayVersion)"
    Check "install.ps1 sets both UninstallString and QuietUninstallString" `
      (($t -match 'UninstallString') -and ($t -match 'QuietUninstallString'))
    Check "install.ps1 registers per user only (HKCU)" (($t -match 'HKCU:') -and ($t -notmatch 'HKLM:')) "(HKCU/HKLM mismatch)"
    Check "install.ps1 registers under the key the uninstaller looks at" `
      ($t -match 'Uninstall\\7ZipPasswordVault') "(key name differs from tools\uninstall.ps1)"
    if (Test-Path -LiteralPath $uninstPs1) {
      $vInstall = [regex]::Match($t, 'DisplayVersion\s*=\s*"(\d+\.\d+\.\d+)"').Groups[1].Value
      $tU = Get-Content -LiteralPath $uninstPs1 -Raw
      Check "the version in install.ps1 looks like a real version ([$vInstall])" (-not [string]::IsNullOrWhiteSpace($vInstall))
      Check "the uninstaller uses the same uninstall key as install.ps1" ($tU -match 'Uninstall\\7ZipPasswordVault')
    }
  }
  Check "no vault file (*.dat) was packed by accident" `
    (@(Get-ChildItem -LiteralPath $extractDir -Recurse -File -Filter "*.dat" -Force).Count -eq 0)

  # ================================================================ phases 2/3: registry
  if (-not $IncludeRegistry) {
    Head "2./3. install.cmd and the uninstaller (skipped)"
    Skip-Phase "install.cmd / install.ps1 write into HKCU" "run again with -IncludeRegistry (HKCU is snapshotted and restored)"
    Skip-Phase "uninstall end to end" "run again with -IncludeRegistry"
    Skip-Phase "shortcut creation" "run again with -IncludeShortcuts"
  } else {
    Head "2. install.cmd / install.ps1 in an isolated folder"
    $script:bagRegRoot = Get-KeyBag $regRoot
    $script:bagUninstall = Get-KeyBag $uninstallKey
    $script:hadRoamingVault = Test-Path -LiteralPath $roamingVault
    $script:rescueBefore = @(Get-ChildItem -LiteralPath $roamingDir -Filter "7zPasswordVault-rescued-*.dat" -ErrorAction SilentlyContinue |
                             Select-Object -ExpandProperty FullName)
    $script:preLinks = @($startMenuLink, $desktopLink) | Where-Object { Test-Path -LiteralPath $_ }
    Check "HKCU\Software\7-Zip was snapshotted (or did not exist)" `
      (($null -ne $script:bagRegRoot) -or (-not (Test-Path -LiteralPath $regRoot)))
    Check "the Apps & features entry was snapshotted (or did not exist)" `
      (($null -ne $script:bagUninstall) -or (-not (Test-Path -LiteralPath $uninstallKey)))
    if ($null -ne $script:bagUninstall) {
      Warn "an Apps & features entry for 7ZipPasswordVault existed before the run" "- it is replaced and put back afterwards"
    }
    foreach ($lnk in $script:preLinks) { Warn ("the shortcut {0} exists already" -f (Split-Path $lnk -Leaf)) "- it is not touched by this run" }

    $installDir = Join-Path $work "install"
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Copy-Item -Path (Join-Path $extractDir "*") -Destination $installDir -Recurse -Force
    Remove-Item -LiteralPath $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue
    Check "the Apps & features entry does not exist before the install" (-not (Test-Path -LiteralPath $uninstallKey))

    $installArgs = if ($IncludeShortcuts) { @("-InstallDir", $installDir) } else { @("-NoShortcuts", "-InstallDir", $installDir) }
    if (-not $IncludeShortcuts) {
      Skip-Phase "shortcut creation" "pass -IncludeShortcuts (it writes into the real Start Menu / Desktop for a moment)"
    } else {
      Warn "shortcuts are created for real (-IncludeShortcuts)" "- both .lnk files are removed again at the end"
    }

    # through install.cmd: the command installer\sfx-config.txt names in RunProgram
    $r = Invoke-Capture "cmd.exe" (@("/c", "`"$installDir\install.cmd`"") + $installArgs) $installDir $nul
    Check "install.cmd runs and reports success" ($r.Code -eq 0) "(exit $($r.Code): $($r.Out.Trim()))"

    Check "the Apps & features entry was created" (Test-Path -LiteralPath $uninstallKey)
    if (Test-Path -LiteralPath $uninstallKey) {
      $props = Get-ItemProperty -LiteralPath $uninstallKey
      Check "DisplayName names the product and the version" `
        ($props.DisplayName -match '7-Zip Password Vault' -and $props.DisplayName -match '\d\d\.\d\d') "(got [$($props.DisplayName)])"
      Check "DisplayVersion is a version number" ($props.DisplayVersion -match '^\d+\.\d+\.\d+$') "(got [$($props.DisplayVersion)])"
      Check "Publisher is set" (-not [string]::IsNullOrWhiteSpace($props.Publisher)) "(got [$($props.Publisher)])"
      Check "DisplayIcon points at 7zFM.exe of this folder" ($props.DisplayIcon -like "*$installDir*7zFM.exe*") "(got [$($props.DisplayIcon)])"
      Check "InstallLocation points into this test's folder (not at a real installation)" `
        ($props.InstallLocation.TrimEnd("\") -ieq $installDir.TrimEnd("\")) "(got [$($props.InstallLocation)])"
      Check "UninstallString starts the uninstaller of this folder" `
        (($props.UninstallString -like "*uninstall.cmd*") -and ($props.UninstallString -like "*$installDir*")) "(got [$($props.UninstallString)])"
      Check "QuietUninstallString uses the isolated path as well" ($props.QuietUninstallString -like "*$installDir*") "(got [$($props.QuietUninstallString)])"
      Check "NoModify and NoRepair are set (an uninstall-only entry)" ($props.NoModify -eq 1 -and $props.NoRepair -eq 1)
      Check "EstimatedSize was measured (not zero)" ($props.EstimatedSize -gt 0) "(got [$($props.EstimatedSize)])"
      Check "InstallDate has the yyyymmdd form" ($props.InstallDate -match '^\d{8}$') "(got [$($props.InstallDate)])"
    }
    if ($IncludeShortcuts) {
      $shell = New-Object -ComObject WScript.Shell
      foreach ($lnk in @($startMenuLink, $desktopLink)) {
        if (Test-Path -LiteralPath $lnk) {
          $target = ""
          try { $target = $shell.CreateShortcut($lnk).TargetPath } catch { }
          Check ("{0} points into the install folder" -f (Split-Path $lnk -Leaf)) `
            ($target -ieq (Join-Path $installDir "7zFM.exe")) "(target [$target])"
        } else { Check ("{0} was created" -f (Split-Path $lnk -Leaf)) $false }
      }
    }

    # ================================================================ phase 3: uninstall
    Head "3. uninstall from the isolated folder"
    # -Lcid1033: the checks below read the output, and the uninstaller falls back to the
    # system language without it. The uninstaller passes the arguments through to
    # powershell.exe, so the switch is honoured there.
    $r = Invoke-Capture "cmd.exe" @("/c", "`"$installDir\uninstall.cmd`" -DeleteVault -Yes -NoBackup -Lcid1033") $installDir $nul
    Check "uninstall.cmd runs and reports success" ($r.Code -eq 0) "(exit $($r.Code): $($r.Out.Trim()))"
    Check "the Apps & features entry is gone" (-not (Test-Path -LiteralPath $uninstallKey))

    $gone = Wait-Gone $installDir $WriteWaitSeconds
    $left = @(Get-RelativeList $installDir)
    Check "the program folder is removed (the delayed helper finished)" $gone "(still there: $($left -join ', '))"
    foreach ($name in "uninstall.cmd", "uninstall.ps1", "SHA256SUMS.txt", "install.cmd", "install.ps1") {
      Check ("no {0} is left behind in the program folder" -f $name) (-not (Test-Path -LiteralPath (Join-Path $installDir $name)))
    }
    Check "the uninstaller used the hash list, not the by-name fallback" `
      (($r.Out -notmatch "by name") -and ($r.Out -match "SHA256SUMS|hash list")) "(output was [$($r.Out.Trim())])"
    Check "no file of the payload survived anywhere in the folder" ($left.Count -eq 0) "(left: $($left -join ', '))"
    Check "the per-user settings key of the uninstaller was removed" (-not (Test-Path -LiteralPath $regRoot))

    # the uninstaller must not have written into the user's own vault folder
    foreach ($f in $script:rescueBefore) {
      Check ("the rescue file that existed before ({0}) is untouched" -f (Split-Path $f -Leaf)) (Test-Path -LiteralPath $f)
    }
    $rescued = @(Get-ChildItem -LiteralPath $roamingDir -Filter "7zPasswordVault-rescued-*.dat" -ErrorAction SilentlyContinue |
                 Where-Object { $script:rescueBefore -notcontains $_.FullName })
    Check "no vault was rescued into %APPDATA% (the test folder never held one)" `
      ($rescued.Count -eq 0) "(new: $(($rescued | ForEach-Object { $_.Name }) -join ', '))"
    Check "the user's own vault file is unchanged in existence" `
      ((Test-Path -LiteralPath $roamingVault) -eq $script:hadRoamingVault) "(was $($script:hadRoamingVault))"
    if (Test-Path -LiteralPath (Join-Path $work "install")) {
      Warn "the test installation folder survived the uninstall" "- see the output above"
    }

    # ================================================================ phase 4: fallback
    Head "4. the same uninstaller without a hash list, and in a folder shared with another 7-Zip"
    # 4a: no SHA256SUMS.txt at all -> the by-name fallback, which has to announce itself
    $dirA = Join-Path $work "fallback"
    New-Item -ItemType Directory -Force -Path $dirA | Out-Null
    Copy-Item -Path (Join-Path $extractDir "*") -Destination $dirA -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $dirA "SHA256SUMS.txt") -Force
    Check "the fixture really has no SHA256SUMS.txt" (-not (Test-Path -LiteralPath (Join-Path $dirA "SHA256SUMS.txt")))
    $r = Invoke-Capture "cmd.exe" @("/c", "`"$dirA\uninstall.cmd`" -DeleteVault -Yes -NoBackup -Lcid1033") $dirA $nul
    Check "the fallback run finishes" ($r.Code -eq 0) "(exit $($r.Code))"
    $goneA = Wait-Gone $dirA $WriteWaitSeconds
    $leftA = @(Get-RelativeList $dirA)
    Check "without a hash list the folder is still emptied (it is ours by name)" ($goneA -and $leftA.Count -eq 0) "(left: $($leftA -join ', '))"
    Check "the fallback announces that it deletes by name" ($r.Out -match "by name") "(output was [$($r.Out.Trim())])"

    # 4b: a shared folder - a same-named file with someone else's hash must survive
    $dirB = Join-Path $work "shared"
    New-Item -ItemType Directory -Force -Path $dirB | Out-Null
    Copy-Item -Path (Join-Path $extractDir "*") -Destination $dirB -Recurse -Force
    Set-Content -LiteralPath (Join-Path $dirB "7z.exe") -Value "someone else's 7-Zip" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $dirB "their-tool.exe") -Value "not ours" -Encoding ASCII
    $r = Invoke-Capture "cmd.exe" @("/c", "`"$dirB\uninstall.cmd`" -DeleteVault -Yes -NoBackup -Lcid1033") $dirB $nul
    Check "the shared-folder run finishes" ($r.Code -eq 0) "(exit $($r.Code))"
    Check "a same-named file with another hash was kept" (Test-Path -LiteralPath (Join-Path $dirB "7z.exe"))
    Check "a file the manifest never listed was kept" (Test-Path -LiteralPath (Join-Path $dirB "their-tool.exe"))
    Check "our own files were removed from the shared folder" (-not (Test-Path -LiteralPath (Join-Path $dirB "7zFM.exe")))
    Check "the folder was kept because it still holds foreign files" (Test-Path -LiteralPath $dirB)
    Check "the uninstaller says which files it kept" `
      (($r.Out -match "not ours") -or ($r.Out -match "\[kept\]")) "(output was [$($r.Out.Trim())])"
    Check "our hash list and launchers are gone from the shared folder" `
      ((-not (Test-Path -LiteralPath (Join-Path $dirB "SHA256SUMS.txt"))) -and
       (-not (Test-Path -LiteralPath (Join-Path $dirB "uninstall.ps1"))) -and
       (-not (Test-Path -LiteralPath (Join-Path $dirB "install.cmd"))))
  }
} catch {
  Write-Host ("`n[FAIL] the run stopped: {0}" -f $_.Exception.Message) -ForegroundColor Red
  $script:fail++
} finally {
  # ================================================================ restore + cleanup
  Head "restore"
  if ($IncludeRegistry) {
    try {
      Set-KeyBag $regRoot $script:bagRegRoot
      Set-KeyBag $uninstallKey $script:bagUninstall
      Write-Host ("  HKCU\Software\7-Zip: {0}" -f $(if ($null -eq $script:bagRegRoot) { "removed (it did not exist before)" } else { "restored, {0} value(s)" -f $script:bagRegRoot.Count })) -ForegroundColor Gray
      Write-Host ("  Apps & features entry: {0}" -f $(if ($null -eq $script:bagUninstall) { "removed (it did not exist before)" } else { "restored" })) -ForegroundColor Gray
    } catch {
      Write-Host ("  [FAIL] the registry could not be restored: {0}" -f $_.Exception.Message) -ForegroundColor Red
      $script:fail++
    }
  } else {
    Write-Host "  the registry was not touched by this run" -ForegroundColor Gray
  }
  # a shortcut this run created points into our own temp folder; one it did not create is left alone
  foreach ($lnk in @($startMenuLink, $desktopLink)) {
    if ((Test-Path -LiteralPath $lnk) -and ($script:preLinks -notcontains $lnk)) {
      $ours = $false
      try {
        $shell = New-Object -ComObject WScript.Shell
        $ours = ($shell.CreateShortcut($lnk).TargetPath -like "$work*")
      } catch { }
      if ($ours) {
        Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
        Write-Host ("  removed the shortcut this run created: {0}" -f $lnk) -ForegroundColor Gray
      } else {
        Write-Host ("  left alone (it does not point into the test folder): {0}" -f $lnk) -ForegroundColor Yellow
      }
    }
  }
  # a test run must never leave a test vault in the user's own folder
  foreach ($f in @(Get-ChildItem -LiteralPath $roamingDir -Filter "7zPasswordVault-rescued-*.dat" -ErrorAction SilentlyContinue)) {
    if ($script:rescueBefore -notcontains $f.FullName) {
      Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
      Write-Host ("  removed the rescue file this run produced: {0}" -f $f.Name) -ForegroundColor Gray
    }
  }
  if ($KeepArtifacts) {
    Write-Host ("  artifacts kept: {0} (remove them yourself)" -f $work) -ForegroundColor Yellow
  } else {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    Write-Host ("  the temp folder was removed: {0}" -f $work) -ForegroundColor Gray
  }
}

# ================================================================== summary
Head "summary"
$fatal = ($script:fail -gt 0) -or ($Strict -and $script:warn -gt 0)
Write-Host ("  passed: {0}   failed: {1}   warnings: {2}" -f $script:pass, $script:fail, $script:warn) `
  -ForegroundColor $(if ($fatal) { "Red" } else { "Green" })
if ($script:warn -gt 0) {
  Write-Host "  the warnings are open points (see docs\acceptance-plan.md); -Strict turns them into failures" -ForegroundColor Yellow
}
Write-Host ("  verdict: {0}" -f $(if ($fatal) { "NOT ACCEPTED" } else { "accepted for this scope" })) `
  -ForegroundColor $(if ($fatal) { "Red" } else { "Green" })
exit $(if ($fatal) { 1 } else { 0 })
