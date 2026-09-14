<#
  uninstall.ps1 - remove the 7-Zip Password Vault build from this machine.

  What it removes:
    * the running 7zFM / 7zG / 7z processes started from this folder
    * HKCU\Software\7-Zip                    (the vault settings AND 7-Zip's own
                                              per-user settings: associations, the
                                              language, the panel settings)
    * the per-user file associations and the shell-extension registration, but only
                                              the ones that point at THIS folder
    * shortcuts in the Start Menu / Desktop that point at this folder
    * this folder itself (everything in it)
    * the vault file - only if you say so (asked, default: keep it)

  What it never touches:
    * archives, documents or anything else you created
    * HKLM (machine-wide entries of a previously installed official 7-Zip) unless you
      pass -AllUsers, which needs an administrator

  Before the settings key is deleted its contents are exported to
  %TEMP%\7zip-vault-settings-<date>.reg (unless -NoBackup is given), because that key
  also holds the vault path. The summary prints the file and how to restore it.

  Usage (the .cmd next to it calls this with the same arguments):
    uninstall.cmd                       # asks about the vault, then confirms
    uninstall.cmd -KeepVault            # never deletes the vault file
    uninstall.cmd -DeleteVault          # deletes the vault without asking
    uninstall.cmd -AllUsers             # also remove machine-wide leftovers (admin)
    uninstall.cmd -NoBackup             # do not write the settings backup
    uninstall.cmd -WhatIf               # only print what would be removed
#>

param(
  [string]$InstallDir = "",
  [switch]$KeepVault,
  [switch]$DeleteVault,
  [switch]$AllUsers,
  [switch]$Yes,
  [switch]$NoBackup,
  [string]$BackupPath = "",
  [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# The documented flags are switches: a mistyped argument then fails loudly instead of
# being ignored (which is how "-DeleteVault" silently kept the vault at first).
if ($KeepVault -and $DeleteVault) { throw "-KeepVault and -DeleteVault cannot be combined" }
$VaultAction = if ($KeepVault) { "Keep" } elseif ($DeleteVault) { "Delete" } else { "Ask" }

$script:removed = New-Object System.Collections.Generic.List[string]
$script:kept = New-Object System.Collections.Generic.List[string]

function Say([string]$text) { Write-Host $text }
function Ok([string]$text) { Write-Host "  [removed] $text" -ForegroundColor Green; $script:removed.Add($text) }
function Keep([string]$text) { Write-Host "  [kept]    $text" -ForegroundColor Yellow; $script:kept.Add($text) }
function Skip([string]$text) { Write-Host "  [skip]    $text" -ForegroundColor DarkGray }

function Remove-ItemSafe([string]$path, [string]$what) {
  if (-not (Test-Path -LiteralPath $path)) { Skip "$what ($path does not exist)"; return }
  if ($WhatIf) { Say "  [would remove] $what -> $path"; return }
  Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $path) { Say "  [failed]  $what -> $path" -ForegroundColor Red }
  else { Ok "$what -> $path" }
}

function Remove-RegKeySafe([string]$key, [string]$what) {
  if (-not (Test-Path -LiteralPath $key)) { Skip "$what ($key does not exist)"; return }
  if ($WhatIf) { Say "  [would remove] $what -> $key"; return }
  Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $key) { Say "  [failed]  $what -> $key" -ForegroundColor Red }
  else { Ok "$what -> $key" }
}

# ---------------------------------------------------------------- where are we
if (-not $InstallDir) { $InstallDir = $PSScriptRoot }
try { $InstallDir = (Resolve-Path -LiteralPath $InstallDir).Path } catch { throw "install folder not found: $InstallDir" }
$installDirFull = $InstallDir.TrimEnd("\")

$hasApp = (Test-Path -LiteralPath (Join-Path $installDirFull "7zFM.exe")) -or
          (Test-Path -LiteralPath (Join-Path $installDirFull "7zG.exe"))
if (-not $hasApp -and -not $Yes) {
  Say "This folder does not look like a 7-Zip Password Vault folder (no 7zFM.exe / 7zG.exe):"
  Say "  $installDirFull"
  $answer = Read-Host "Continue anyway? [y/N]"
  if ($answer -notmatch '^(y|Y)') { Say "nothing was done."; exit 1 }
}
if ($installDirFull -match '^[A-Za-z]:$' -or $installDirFull.Length -lt 4) {
  throw "refusing to work on '$installDirFull': that is a drive root"
}

$regRoot = "HKCU:\Software\7-Zip"
$regVault = "$regRoot\PasswordVault"
$uninstallEntry = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\7ZipPasswordVault"

# ---------------------------------------------------------------- what to do with the vault
# The default location is the program folder (portable); an older build kept the vault
# in %APPDATA%\7-Zip. Whichever exists is the one to look at, and the other one is
# only reported, never deleted silently.
$portableVault = Join-Path $installDirFull "7zPasswordVault.dat"
$roamingVault = Join-Path $env:APPDATA "7-Zip\7zPasswordVault.dat"
$vaultPath = ""
if (Test-Path -LiteralPath $regVault) {
  $configured = (Get-ItemProperty -LiteralPath $regVault -Name VaultPath -ErrorAction SilentlyContinue).VaultPath
  if ($configured) { $vaultPath = $configured }
}
$otherVault = ""
if (-not $vaultPath) {
  if (Test-Path -LiteralPath $portableVault) { $vaultPath = $portableVault; if (Test-Path -LiteralPath $roamingVault) { $otherVault = $roamingVault } }
  elseif (Test-Path -LiteralPath $roamingVault) { $vaultPath = $roamingVault }
  else { $vaultPath = $portableVault }
}

if ($VaultAction -eq "Ask" -and -not $WhatIf) {
  if ($Yes) {
    # non-interactive run: keep the passwords, deleting them needs -DeleteVault
    $VaultAction = "Keep"
    Skip "vault question skipped (-Yes): keeping the vault file"
  } else {
    Say ""
    Say "Your saved passwords live in:"
    Say "  $vaultPath"
    if (Test-Path -LiteralPath $vaultPath) {
      $size = (Get-Item -LiteralPath $vaultPath).Length
      try {
        # the entry count is not readable without the key, so only the size is shown
        Say ("  ({0} bytes, last written {1})" -f $size, (Get-Item -LiteralPath $vaultPath).LastWriteTime)
      } catch { }
    } else {
      Say "  (no vault file there)"
    }
    Say ""
    Say "Keep this file? [Y/n]  Y keeps your passwords for a later reinstall."
    $answer = Read-Host
    if ($answer -match '^(n|N)') { $VaultAction = "Delete" } else { $VaultAction = "Keep" }
  }
}

# ---------------------------------------------------------------- confirm
Say ""
Say "Folder to remove : $installDirFull"
Say "Registry (HKCU)  : $regRoot"
Say "Vault file       : $vaultPath  ->  $VaultAction"
if ($AllUsers) { Say "Machine-wide     : HKLM\SOFTWARE\7-Zip and matching classes (needs admin)" }
Say ""
if (-not $Yes -and -not $WhatIf) {
  $answer = Read-Host "Remove everything listed above? [y/N]"
  if ($answer -notmatch '^(y|Y)') { Say "nothing was done."; exit 1 }
}

# ---------------------------------------------------------------- backup
if (-not $BackupPath) { $BackupPath = Join-Path $env:TEMP ("7zip-vault-settings-{0}.reg" -f (Get-Date -Format "yyyyMMdd-HHmmss")) }
if (Test-Path -LiteralPath $regRoot) {
  if ($WhatIf) { Say "  [would write] settings backup -> $BackupPath" }
  elseif ($NoBackup) { Skip "settings backup switched off (-NoBackup)" }
  else {
    & reg.exe export "HKCU\Software\7-Zip" $BackupPath /y | Out-Null
    if (Test-Path -LiteralPath $BackupPath) { Ok "settings backup -> $BackupPath" }
    else { Say "  [failed]  the settings backup could not be written" -ForegroundColor Yellow }
  }
} else { Skip "no settings to back up" }

# ---------------------------------------------------------------- processes
Say ""
Say "Stopping running 7-Zip processes from this folder..."
$stopped = 0
foreach ($name in "7zFM", "7zG", "7z", "7zCon") {
  foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
    $path = ""
    try { $path = $proc.Path } catch { }
    if ($path -and $path.StartsWith($installDirFull, [StringComparison]::OrdinalIgnoreCase)) {
      if (-not $WhatIf) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
      Say ("  [stopped] {0} (pid {1})" -f $path, $proc.Id)
      $stopped++
    } elseif ($path) { Skip "$name from another folder: $path" }
  }
}
if ($stopped -eq 0) { Skip "no process from this folder was running" }
if (-not $WhatIf) { Start-Sleep -Milliseconds 500 }

# ---------------------------------------------------------------- registry (per user)
Say ""
Say "Registry (current user)..."
Remove-RegKeySafe $regRoot "7-Zip per-user settings (vault options, associations, panel)"

# the entry the installer created in "Apps & features"
if (Test-Path -LiteralPath $uninstallEntry) {
  $entryLocation = (Get-ItemProperty -LiteralPath $uninstallEntry -Name InstallLocation -ErrorAction SilentlyContinue).InstallLocation
  if (-not $entryLocation -or $entryLocation.TrimEnd("\") -eq $installDirFull) {
    Remove-RegKeySafe $uninstallEntry "Apps & features entry"
  } else { Skip "the Apps & features entry points at another folder: $entryLocation" }
} else { Skip "no Apps & features entry" }

$classes = "HKCU:\Software\Classes"
$ours = 0
# file type keys "7-Zip.<ext>" and the "<ext>" keys that point at them
if (Test-Path -LiteralPath $classes) {
  foreach ($key in @(Get-ChildItem -LiteralPath $classes -ErrorAction SilentlyContinue)) {
    $name = $key.PSChildName
    if ($name -like "7-Zip.*") { Remove-RegKeySafe $key.PSPath "file type $name"; $ours++; continue }
    if ($name -like ".*") {
      $value = (Get-ItemProperty -LiteralPath $key.PSPath -Name "(default)" -ErrorAction SilentlyContinue)."(default)"
      if ($value -like "7-Zip.*") { Remove-RegKeySafe $key.PSPath "association $name -> $value"; $ours++ }
    }
  }
  # the shell extension is registered as a COM class pointing at 7-zip.dll
  $clsidRoot = Join-Path $classes "CLSID"
  if (Test-Path -LiteralPath $clsidRoot) {
    foreach ($clsid in @(Get-ChildItem -LiteralPath $clsidRoot -ErrorAction SilentlyContinue)) {
      $server = (Get-ItemProperty -LiteralPath (Join-Path $clsid.PSPath "InprocServer32") -Name "(default)" -ErrorAction SilentlyContinue)."(default)"
      if ($server -and $server.Trim('"').StartsWith($installDirFull, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-RegKeySafe $clsid.PSPath "shell extension $($clsid.PSChildName)"
        $ours++
      }
    }
  }
}
if ($ours -eq 0) { Skip "no per-user association of this folder was registered" }

# ---------------------------------------------------------------- shortcuts
Say ""
Say "Shortcuts pointing at this folder..."
$shortcutDirs = @(
  (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"),
  (Join-Path $env:USERPROFILE "Desktop"),
  (Join-Path $env:PUBLIC "Desktop")
) | Where-Object { Test-Path -LiteralPath $_ }
$shell = New-Object -ComObject WScript.Shell
$found = 0
foreach ($dir in $shortcutDirs) {
  foreach ($lnk in @(Get-ChildItem -LiteralPath $dir -Filter *.lnk -Recurse -ErrorAction SilentlyContinue)) {
    try {
      $target = $shell.CreateShortcut($lnk.FullName).TargetPath
      if ($target -and $target.StartsWith($installDirFull, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-ItemSafe $lnk.FullName "shortcut"; $found++
      }
    } catch { }
  }
}
if ($found -eq 0) { Skip "none" }

# ---------------------------------------------------------------- machine-wide (optional)
if ($AllUsers) {
  Say ""
  Say "Registry (all users)..."
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    Say "  [skip]    needs an administrator: run this again from an elevated prompt with -AllUsers" -ForegroundColor Yellow
  } else {
    Remove-RegKeySafe "HKLM:\SOFTWARE\7-Zip" "7-Zip machine settings"
    $hklmClasses = "HKLM:\SOFTWARE\Classes"
    if (Test-Path -LiteralPath $hklmClasses) {
      foreach ($key in @(Get-ChildItem -LiteralPath $hklmClasses -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "7-Zip.*" })) {
        Remove-RegKeySafe $key.PSPath "machine file type $($key.PSChildName)"
      }
      # entries of a previously installed official 7-Zip whose files are gone
      foreach ($key in @(Get-ChildItem -LiteralPath $hklmClasses -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like ".*" })) {
        $value = (Get-ItemProperty -LiteralPath $key.PSPath -Name "(default)" -ErrorAction SilentlyContinue)."(default)"
        if ($value -like "7-Zip.*" -and -not (Test-Path -LiteralPath (Join-Path $hklmClasses $value))) {
          Remove-RegKeySafe $key.PSPath "stale association $($key.PSChildName) -> $value"
        }
      }
    }
  }
}

# ---------------------------------------------------------------- the vault
Say ""
Say "Vault file..."
if ($VaultAction -eq "Keep") {
  Keep "your saved passwords: $vaultPath"
  $tmp = "$vaultPath.tmp"
  if (Test-Path -LiteralPath $tmp) { Remove-ItemSafe $tmp "leftover temporary vault" }
} else {
  Remove-ItemSafe $vaultPath "your saved passwords"
  Remove-ItemSafe "$vaultPath.tmp" "leftover temporary vault"
  $vaultFolder = Split-Path -Parent $vaultPath
  if ($vaultFolder -and (Test-Path -LiteralPath $vaultFolder)) {
    $left = @(Get-ChildItem -LiteralPath $vaultFolder -Force -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) { Remove-ItemSafe $vaultFolder "empty vault folder" }
    else { Skip "$vaultFolder still holds other files, left in place" }
  }
}

# ---------------------------------------------------------------- the folder
Say ""
Say "Program folder..."
if ($WhatIf) {
  Say "  [would remove] $installDirFull (everything in it)"
} else {
  $self = $MyInvocation.MyCommand.Path
  $sibling = @(Get-ChildItem -LiteralPath $installDirFull -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -ne (Split-Path $self -Leaf) })
  foreach ($f in $sibling) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
  foreach ($d in @(Get-ChildItem -LiteralPath $installDirFull -Directory -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
  }
  # the script itself cannot remove its own folder while it runs from there: hand the
  # last step to a detached shell that waits a moment.
  Remove-Item -LiteralPath $self -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $installDirFull) {
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "timeout", "/t", "2", ">nul", "&",
        "rmdir", "/s", "/q", "`"$installDirFull`"") -WindowStyle Hidden
    Say "  [removing] $installDirFull (a helper finishes this in a second)"
    Ok "program folder (scheduled)"
  } else {
    Ok "program folder"
  }
}

# ---------------------------------------------------------------- summary
Say ""
Say "== summary =="
Say ("  removed : {0} item(s)" -f $script:removed.Count)
foreach ($r in $script:removed) { Say "            $r" }
if ($script:kept.Count) {
  Say ("  kept    : {0}" -f ($script:kept -join ", "))
  Say "            (the vault file stays usable: put the same build back and it opens again)"
}
if ($otherVault) {
  Say ""
  Say "There is also a vault file at the old location:"
  Say "  $otherVault"
  Say "  (it was not touched - delete it yourself if you do not need it)"
}
if (-not $WhatIf -and -not $NoBackup -and (Test-Path -LiteralPath $BackupPath)) {
  Say ""
  Say "The 7-Zip settings were backed up before they were removed:"
  Say "  $BackupPath"
  Say "  restore them with:  reg import `"$BackupPath`""
}
if ($WhatIf) { Say "  this was a -WhatIf run: nothing was changed" }
Say ""
if (-not $WhatIf -and -not $Yes) { [void](Read-Host "Press Enter to close") }
