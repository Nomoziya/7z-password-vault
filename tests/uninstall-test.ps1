# uninstall-test.ps1 - test tools\uninstall.ps1 without touching anything real.
#
# The uninstaller removes HKCU\Software\7-Zip, so this test backs up that key (and the
# real vault file) first, and puts both back in a finally block. Everything else it
# creates lives in %TEMP% and is removed again.
#
# Usage:  pwsh -NoProfile -File tests\uninstall-test.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root "7-Zip-密码管家版"
$regRoot = "HKCU:\Software\7-Zip"
$regKey = "$regRoot\PasswordVault"
$realVault = Join-Path $env:APPDATA "7-Zip\7zPasswordVault.dat"
$classes = "HKCU:\Software\Classes"
$desktop = [Environment]::GetFolderPath("Desktop")

$script:pass = 0
$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$extra = "") {
  if ($ok) { $script:pass++; Write-Host ("  [PASS] " + $name) -ForegroundColor Green }
  else     { $script:fail++; Write-Host ("  [FAIL] " + $name + " " + $extra) -ForegroundColor Red }
}

$work = Join-Path $env:TEMP "7zpw-uninstall-test"
$backupReg = Join-Path $env:TEMP "7zpw-uninstall-backup.reg"
$backupVault = Join-Path $env:TEMP "7zpw-real-vault-backup.dat"
$fakeShortcut = Join-Path $desktop "7-Zip Password Vault (test).lnk"
$hadReg = Test-Path -LiteralPath $regRoot
$hadVault = Test-Path -LiteralPath $realVault

Write-Host "== setup ==" -ForegroundColor Cyan
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work | Out-Null
if ($hadReg) { & reg.exe export "HKCU\Software\7-Zip" $backupReg /y | Out-Null }
if ($hadVault) { Copy-Item -LiteralPath $realVault -Destination $backupVault -Force }
Check "the registry was backed up (or did not exist)" ((-not $hadReg) -or (Test-Path $backupReg))
Check "the real vault was backed up (or did not exist)" ((-not $hadVault) -or (Test-Path $backupVault))

# a fake installation: enough files that "the folder is gone" means something
function New-FakeInstall([string]$dir) {
  Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  foreach ($f in "7zFM.exe", "7zG.exe", "7z.dll", "7-zip.dll") {
    Copy-Item -LiteralPath (Join-Path $dist $f) -Destination (Join-Path $dir $f) -Force
  }
  Copy-Item -LiteralPath (Join-Path $root "tools\uninstall.ps1") -Destination (Join-Path $dir "uninstall.ps1") -Force
  Copy-Item -LiteralPath (Join-Path $root "tools\uninstall.cmd") -Destination (Join-Path $dir "uninstall.cmd") -Force
  New-Item -ItemType Directory -Force -Path (Join-Path $dir "Lang") | Out-Null
  Set-Content -LiteralPath (Join-Path $dir "Lang\en.txt") -Value "x" -Encoding UTF8
}

function New-FakeState([string]$installDir, [string]$vaultPath) {
  New-Item -Path $regKey -Force | Out-Null
  Set-ItemProperty -Path $regKey -Name "VaultPath" -Value $vaultPath -Type String
  Set-ItemProperty -Path $regKey -Name "UseMasterPassword" -Value 0 -Type DWord
  Set-Content -LiteralPath $vaultPath -Value "fake vault" -Encoding UTF8
  # a per-user association and shell-extension registration of this folder
  New-Item -Path (Join-Path $classes "7-Zip.zztest") -Force | Out-Null
  New-Item -Path (Join-Path $classes ".zztest") -Force | Out-Null
  Set-ItemProperty -Path (Join-Path $classes ".zztest") -Name "(default)" -Value "7-Zip.zztest"
  $clsid = Join-Path $classes "CLSID\{23170F69-40C1-278A-1000-000100029999}"
  New-Item -Path (Join-Path $clsid "InprocServer32") -Force | Out-Null
  Set-ItemProperty -Path (Join-Path $clsid "InprocServer32") -Name "(default)" -Value (Join-Path $installDir "7-zip.dll")
  # a shortcut pointing at this folder
  $shell = New-Object -ComObject WScript.Shell
  $lnk = $shell.CreateShortcut($fakeShortcut)
  $lnk.TargetPath = Join-Path $installDir "7zFM.exe"
  $lnk.Save()
  return $clsid
}

function Invoke-Uninstaller([string]$installDir, [string[]]$arguments) {
  $exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
  $all = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $installDir "uninstall.ps1"),
           "-InstallDir", $installDir) + $arguments
  $out = & $exe @all 2>&1 | Out-String
  return $out
}

try {
  # ---------------------------------------------------------------- case 1: keep the vault
  Write-Host "`n== 1. uninstall and keep the vault ==" -ForegroundColor Cyan
  $install = Join-Path $work "install-keep"
  $vaultA = Join-Path $work "keep-vault.dat"
  New-FakeInstall $install
  $clsid = New-FakeState $install $vaultA

  $settingsBackup = Join-Path $work "settings-backup.reg"
  $out = Invoke-Uninstaller $install @("-KeepVault", "-Yes", "-BackupPath", $settingsBackup)
  Start-Sleep -Seconds 3
  Check "the vault file was kept" (Test-Path -LiteralPath $vaultA)
  Check "a settings backup was written before the key was deleted" (Test-Path -LiteralPath $settingsBackup) "(no $settingsBackup)"
  if (Test-Path -LiteralPath $settingsBackup) {
    $backupText = Get-Content -LiteralPath $settingsBackup -Raw
    Check "the backup really holds the settings" ($backupText -match "VaultPath") "(size $($backupText.Length))"
  }
  Check "HKCU\Software\7-Zip was removed" (-not (Test-Path -LiteralPath $regRoot))
  Check "the per-user file type was removed" (-not (Test-Path -LiteralPath (Join-Path $classes "7-Zip.zztest")))
  Check "the per-user association was removed" (-not (Test-Path -LiteralPath (Join-Path $classes ".zztest")))
  Check "the shell extension registration was removed" (-not (Test-Path -LiteralPath $clsid))
  Check "the shortcut pointing here was removed" (-not (Test-Path -LiteralPath $fakeShortcut))
  $gone = $false
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline) {
    if (-not (Test-Path -LiteralPath $install)) { $gone = $true; break }
    Start-Sleep -Milliseconds 300
  }
  Check "the program folder was removed" $gone "(still there: $install)"
  if (-not (Test-Path -LiteralPath $vaultA)) { Check "vault kept (recheck)" $false }

  # ---------------------------------------------------------------- case 2: delete the vault
  Write-Host "`n== 2. uninstall and delete the vault ==" -ForegroundColor Cyan
  $install = Join-Path $work "install-delete"
  $vaultB = Join-Path $work "delete-vault.dat"
  New-FakeInstall $install
  [void](New-FakeState $install $vaultB)
  $vaultBFolder = Split-Path -Parent $vaultB

  $out = Invoke-Uninstaller $install @("-DeleteVault", "-Yes")
  Start-Sleep -Seconds 3
  Check "the vault file was deleted" (-not (Test-Path -LiteralPath $vaultB))
  Check "HKCU\Software\7-Zip was removed again" (-not (Test-Path -LiteralPath $regRoot))
  Check "the real vault file was untouched" ((Test-Path -LiteralPath $realVault) -eq $hadVault) "(was $hadVault)"
  Check "the program folder was removed" (-not (Test-Path -LiteralPath $install))

  # ---------------------------------------------------------------- case 3: -WhatIf
  Write-Host "`n== 3. -WhatIf changes nothing ==" -ForegroundColor Cyan
  $install = Join-Path $work "install-whatif"
  $vaultC = Join-Path $work "whatif-vault.dat"
  New-FakeInstall $install
  [void](New-FakeState $install $vaultC)
  $out = Invoke-Uninstaller $install @("-DeleteVault", "-Yes", "-WhatIf")
  Start-Sleep -Seconds 1
  Check "-WhatIf keeps the program folder" (Test-Path -LiteralPath $install)
  Check "-WhatIf keeps the vault file" (Test-Path -LiteralPath $vaultC)
  Check "-WhatIf keeps the registry key" (Test-Path -LiteralPath $regKey)
  Check "-WhatIf says what it would do" ($out -match "would remove") "(output was [$($out.Trim())])"
  Check "-WhatIf mentions the vault" ($out -match "vault") ""
  Remove-Item -Recurse -Force $install -ErrorAction SilentlyContinue
  Remove-Item -Path (Join-Path $classes "7-Zip.zztest"),(Join-Path $classes ".zztest") -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $fakeShortcut -Force -ErrorAction SilentlyContinue
} finally {
  Write-Host "`n== restore ==" -ForegroundColor Cyan
  Remove-Item -Path $regRoot -Recurse -Force -ErrorAction SilentlyContinue
  if ($hadReg -and (Test-Path $backupReg)) {
    & reg.exe import $backupReg | Out-Null
    Write-Host "  HKCU\Software\7-Zip restored"
  }
  if ($hadVault -and (Test-Path $backupVault) -and -not (Test-Path -LiteralPath $realVault)) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $realVault) | Out-Null
    Copy-Item -LiteralPath $backupVault -Destination $realVault -Force
    Write-Host "  the real vault file was restored"
  }
  Remove-Item -Path (Join-Path $classes "7-Zip.zztest"),(Join-Path $classes ".zztest") -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $fakeShortcut -Force -ErrorAction SilentlyContinue
  if (-not $KeepArtifacts) {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backupReg,$backupVault -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "`n== summary ==" -ForegroundColor Cyan
Write-Host ("  passed: {0}   failed: {1}" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })
Write-Host ("  real vault: {0}" -f $realVault) -ForegroundColor DarkGray
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
