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

# A path is only "ours" when it is inside the install folder AND behind a separator:
# "C:\7-Zip-old" must not count as being inside "C:\7-Zip".
function Test-InsideDir([string]$path, [string]$dir) {
  if (-not $path) { return $false }
  $p = $path.Trim().Trim([char]34)
  $d = $dir.TrimEnd([char]92)
  return ($p.Equals($d, [StringComparison]::OrdinalIgnoreCase) -or
          $p.StartsWith($d + [char]92, [StringComparison]::OrdinalIgnoreCase))
}

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
    if (Test-InsideDir $path $installDirFull) {
      if (-not $WhatIf) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
      Say ("  [stopped] {0} (pid {1})" -f $path, $proc.Id)
      $stopped++
    } elseif ($path) { Skip "$name from another folder: $path" }
  }
}
if ($stopped -eq 0) { Skip "no process from this folder was running" }
if (-not $WhatIf) { Start-Sleep -Milliseconds 500 }

# ---------------------------------------------------------------- the vault, before anything is deleted
# Nothing may be deleted before the vault is safe: the default location is inside the
# program folder, which the end of this script removes.
if ($VaultAction -eq "Keep" -and (Test-InsideDir $vaultPath $installDirFull) -and
    (Test-Path -LiteralPath $vaultPath) -and -not $WhatIf) {
  # %APPDATA%\7-Zip is the location the program looks in when the program folder has no
  # vault, so a reinstall finds it there without any manual step.
  $roamingDir = Join-Path $env:APPDATA "7-Zip"
  New-Item -ItemType Directory -Force -Path $roamingDir -ErrorAction SilentlyContinue | Out-Null
  $rescue = Join-Path $roamingDir "7zPasswordVault.dat"
  $manual = $false
  if (Test-Path -LiteralPath $rescue) {
    # do not overwrite a vault that is already there
    $rescue = Join-Path $roamingDir ("7zPasswordVault-rescued-{0}.dat" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $manual = $true
  }
  try {
    Move-Item -LiteralPath $vaultPath -Destination $rescue -Force:$false -ErrorAction Stop
  } catch {
    Say ""
    Say "  [STOP] the vault file is inside the program folder and could not be moved:" -ForegroundColor Red
    Say "         $vaultPath" -ForegroundColor Red
    Say "         $($_.Exception.Message)" -ForegroundColor Red
    Say "  Move it somewhere else by hand, then run the uninstaller again." -ForegroundColor Red
    Say "  Nothing was deleted." -ForegroundColor Red
    exit 1
  }
  $vaultPath = $rescue
  Say ""
  Say "Your saved passwords were moved out of the program folder to:"
  Say "  $rescue"
  if ($manual) {
    Say "  (another vault was already there, so this one keeps its own name:"
    Say "   point Tools -> Options -> Password manager at this file to use it)"
  }
}

# ---------------------------------------------------------------- registry (per user)
Say ""
Say "Registry (current user)..."
Remove-RegKeySafe $regRoot "7-Zip per-user settings (vault options, associations, panel)"

# the entry the installer created in "Apps & features"
if (Test-Path -LiteralPath $uninstallEntry) {
  $entryLocation = (Get-ItemProperty -LiteralPath $uninstallEntry -Name InstallLocation -ErrorAction SilentlyContinue).InstallLocation
  if (-not $entryLocation -or $entryLocation.TrimEnd([char]92).Equals($installDirFull, [StringComparison]::OrdinalIgnoreCase)) {
    Remove-RegKeySafe $uninstallEntry "Apps & features entry"
  } else { Skip "the Apps & features entry points at another folder: $entryLocation" }
} else { Skip "no Apps & features entry" }

$classes = "HKCU:\Software\Classes"
$ours = 0
# file type keys "7-Zip.<ext>" and the "<ext>" keys that point at them
if (Test-Path -LiteralPath $classes) {
  # A "7-Zip.*" key is only ours when its command points into this folder: an officially
  # installed 7-Zip uses the same names and keeps its own files, so deleting by name
  # alone would wipe the associations of that installation.
  function Test-ProgramKeyOurs([string]$programKey) {
    $cmd = (Get-ItemProperty -LiteralPath (Join-Path $programKey "shell\open\command") -Name "(default)" -ErrorAction SilentlyContinue)."(default)"
    if (-not $cmd) { $cmd = (Get-ItemProperty -LiteralPath (Join-Path $programKey "DefaultIcon") -Name "(default)" -ErrorAction SilentlyContinue)."(default)" }
    if (-not $cmd) { return $false }
    $exe = ($cmd -split [char]44)[0].Trim().Trim([char]34)
    return (Test-InsideDir $exe $installDirFull)
  }
  foreach ($key in @(Get-ChildItem -LiteralPath $classes -ErrorAction SilentlyContinue)) {
    $name = $key.PSChildName
    if ($name -like "7-Zip.*") {
      if (Test-ProgramKeyOurs $key.PSPath) { Remove-RegKeySafe $key.PSPath "file type $name"; $ours++ }
      else { Skip "$name belongs to another 7-Zip, left alone" }
      continue
    }
    if ($name -like ".*") {
      $value = (Get-ItemProperty -LiteralPath $key.PSPath -Name "(default)" -ErrorAction SilentlyContinue)."(default)"
      if ($value -like "7-Zip.*" -and (Test-ProgramKeyOurs (Join-Path $classes $value))) {
        Remove-RegKeySafe $key.PSPath "association $name -> $value"; $ours++
      }
    }
  }
  # the shell extension is registered as a COM class pointing at 7-zip.dll
  $clsidRoot = Join-Path $classes "CLSID"
  if (Test-Path -LiteralPath $clsidRoot) {
    foreach ($clsid in @(Get-ChildItem -LiteralPath $clsidRoot -ErrorAction SilentlyContinue)) {
      $server = (Get-ItemProperty -LiteralPath (Join-Path $clsid.PSPath "InprocServer32") -Name "(default)" -ErrorAction SilentlyContinue)."(default)"
      if (Test-InsideDir $server $installDirFull) {
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
      if (Test-InsideDir $target $installDirFull) {
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
    $machineDir = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\7-Zip" -Name "Path" -ErrorAction SilentlyContinue).Path
    if (-not $machineDir -or (Test-InsideDir $machineDir $installDirFull)) {
      Remove-RegKeySafe "HKLM:\SOFTWARE\7-Zip" "7-Zip machine settings"
    } else {
      Skip "the machine-wide 7-Zip settings point at $machineDir, left alone"
    }
    $hklmClasses = "HKLM:\SOFTWARE\Classes"
    if (Test-Path -LiteralPath $hklmClasses) {
      foreach ($key in @(Get-ChildItem -LiteralPath $hklmClasses -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "7-Zip.*" })) {
        $cmd = (Get-ItemProperty -LiteralPath (Join-Path $key.PSPath "shell\open\command") -Name "(default)" -ErrorAction SilentlyContinue)."(default)"
        if ($cmd -and (Test-InsideDir (($cmd -split [char]44)[0].Trim().Trim([char]34)) $installDirFull)) {
          Remove-RegKeySafe $key.PSPath "machine file type $($key.PSChildName)"
        } else { Skip "machine file type $($key.PSChildName) belongs to another 7-Zip" }
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
  $vaultDir = if ($vaultPath) { Split-Path -Parent $vaultPath } else { "" }
  foreach ($tmp in @(if ($vaultDir) { Get-ChildItem -LiteralPath $vaultDir -Filter ((Split-Path $vaultPath -Leaf) + ".tmp*") -Force -ErrorAction SilentlyContinue })) {
    # a temporary file is a complete vault that was written but never renamed: tell the
    # user instead of deleting it silently
    Say ""
    Say "  [note]    a temporary vault from an interrupted save is here:" -ForegroundColor Yellow
    Say "            $($tmp.FullName)" -ForegroundColor Yellow
    Say "            (it can be opened by renaming it to 7zPasswordVault.dat)" -ForegroundColor Yellow
  }
} else {
  Remove-ItemSafe $vaultPath "your saved passwords"
  if ($vaultPath) {
    Get-ChildItem -LiteralPath (Split-Path -Parent $vaultPath) -Filter ((Split-Path $vaultPath -Leaf) + ".tmp*") -Force -ErrorAction SilentlyContinue |
      ForEach-Object { Remove-ItemSafe $_.FullName "leftover temporary vault" }
  }
  $vaultFolder = Split-Path -Parent $vaultPath
  if ($vaultFolder -and (Test-Path -LiteralPath $vaultFolder)) {
    $left = @(Get-ChildItem -LiteralPath $vaultFolder -Force -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) { Remove-ItemSafe $vaultFolder "empty vault folder" }
    else { Skip "$vaultFolder still holds other files, left in place" }
  }
}

# ---------------------------------------------------------------- the folder
Say ""
# Windows refuses to remove a directory that is a process's current directory, and a user
# who double-clicks uninstall.cmd inside the program folder makes that folder the current
# directory of this script and of the shell that started it. Move out of the way first so the
# folder can really be deleted; the helper below is started with its own working directory.
try { Set-Location -LiteralPath $env:TEMP -ErrorAction Stop } catch { }
Say "Program folder..."
if ($WhatIf) {
  Say "  [would remove] these files in $installDirFull (everything else stays):"
  $ourFiles = @("7zFM.exe", "7zG.exe", "7z.exe", "7z.dll", "7-zip.dll", "7-zip32.dll",
                "7z.sfx", "7zCon.sfx", "7-zip.chm", "History.txt", "License.txt", "readme.txt",
                "descript.ion", "README.md", "BUILD.md", "uninstall.cmd", "uninstall.ps1",
                "install.cmd", "install.ps1", "SHA256SUMS.txt")
  foreach ($name in $ourFiles) {
    if (Test-Path -LiteralPath (Join-Path $installDirFull $name)) { Say "      $name" }
  }
  foreach ($d in @("Lang", "Codecs", "Formats")) {
    if (Test-Path -LiteralPath (Join-Path $installDirFull $d)) { Say "      $d\" }
  }
} else {
  $self = $MyInvocation.MyCommand.Path
  # Only the files that ship with this package are removed by name. The folder may be a
  # download or tools folder that holds other things, and a portable package must not
  # delete what it does not own.
  $ourFiles = @("7zFM.exe", "7zG.exe", "7z.exe", "7z.dll", "7-zip.dll", "7-zip32.dll",
                "7z.sfx", "7zCon.sfx", "7-zip.chm", "History.txt", "License.txt", "readme.txt",
                "descript.ion", "README.md", "BUILD.md", "uninstall.cmd", "uninstall.ps1",
                "install.cmd", "install.ps1", "SHA256SUMS.txt")
  $removedFiles = 0
  $keptFiles = @()
  $manifestPath = Join-Path $installDirFull "SHA256SUMS.txt"
  $manifestUsed = Test-Path -LiteralPath $manifestPath
  $manifestHasCmd = $false
  $manifestIsOurs = $false
  if ($manifestUsed) {
    # A hash list is only used as the deletion plan when it really is this package's list.
    # A file with that name from elsewhere (a download page, another tool) lists other
    # files, and deleting by its hashes would remove things that are not ours. The first
    # line is the package header, so it identifies the list.
    $firstLine = ""
    try { $firstLine = [string](Get-Content -LiteralPath $manifestPath -TotalCount 1 -ErrorAction Stop) } catch { $firstLine = "" }
    $manifestIsOurs = ($firstLine -match '7-Zip Password Vault')
    if (-not $manifestIsOurs) {
      Say ""
      Say "  [warn]    the SHA256SUMS.txt in this folder is not this package's list:" -ForegroundColor Yellow
      Say "            $firstLine"
      Say "            nothing is deleted by it, and nothing is deleted by name either." -ForegroundColor Yellow
      Keep "the program folder (a foreign hash list was found): $installDirFull"
    }
  }
  # uninstall.cmd is the script that started this one (or the user double-clicked it), and
  # cmd.exe reads a batch file while it executes it: deleting it here makes cmd report
  # "The batch file cannot be found." and exit 1 although everything was removed. It is
  # therefore always left to the delayed helper, in both deletion branches.
  $handedToHelper = @()
  if (Test-Path -LiteralPath (Join-Path $installDirFull "uninstall.cmd")) {
    $handedToHelper += "uninstall.cmd"
  }

  if ($manifestUsed -and $manifestIsOurs) {
    # The hash list decides what belongs to this package: a file of the same name that
    # does not match is somebody else's (an official 7-Zip in the same folder, or a file
    # the user put there) and is left alone.
    $entries = @()
    foreach ($line in (Get-Content -LiteralPath $manifestPath)) {
      if ($line -match '^\s*#' -or $line.Trim() -eq "") { continue }
      $parts = $line -split '\s+', 2
      if ($parts.Count -ne 2) { continue }
      $entries += @{ hash = $parts[0].Trim().ToLower(); rel = $parts[1].Trim() }
    }
    $manifestDirs = @()
    foreach ($e in $entries) {
      if ($e.rel -match '\.\.' -or $e.rel.StartsWith("\") -or $e.rel -match '^[A-Za-z]:') {
        Skip "manifest entry rejected: $($e.rel)"; continue
      }
      if ($e.rel -ieq "uninstall.cmd") { $manifestHasCmd = $true; continue }
      if ($e.rel -ieq "uninstall.ps1" -or $e.rel -ieq "SHA256SUMS.txt") { continue }
      $full = Join-Path $installDirFull $e.rel
      $dir = Split-Path -Parent $full
      if ($dir -and $dir -ne $installDirFull -and ($manifestDirs -notcontains $dir)) { $manifestDirs += $dir }
      if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
      $hash = $null
      try { $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower() } catch { $hash = $null }
      if ($hash -eq $e.hash) {
        Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $full) {
          Say "  [failed]  cannot delete $full (in use?)" -ForegroundColor Red
          $keptFiles += $full
        } else { $removedFiles++ }
      } elseif ($null -eq $hash) {
        Say "  [kept]    cannot read $full (in use?), left alone" -ForegroundColor Yellow
        $keptFiles += $full
      } else {
        $keptFiles += $full
      }
    }
    # The installer adds these two to the payload after the hash list was written.
    foreach ($extra in @("install.ps1", "install.cmd")) {
      $f = Join-Path $installDirFull $extra
      if (Test-Path -LiteralPath $f) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $f) { $keptFiles += $f } else { $removedFiles++ }
      }
    }
    # The hash list itself is ours by definition: only this package ships one. It has to
    # go too, otherwise it stays behind with uninstall.cmd and the folder is never empty.
    if (Test-Path -LiteralPath $manifestPath) {
      Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $manifestPath) { $keptFiles += $manifestPath } else { $removedFiles++ }
    }
    Ok ("program files removed ({0} files, checked against SHA256SUMS.txt)" -f $removedFiles)
    if ($keptFiles.Count) {
      Say ""
      Say "  [kept]    these files do not match the package's hash list, so they are not ours:" -ForegroundColor Yellow
      $keptFiles | Select-Object -First 10 | ForEach-Object { Say "              $_" -ForegroundColor Yellow }
    }
    # only directories that the manifest mentions, and only when they are empty
    foreach ($dir in ($manifestDirs | Sort-Object Length -Descending)) {
      if ((Test-Path -LiteralPath $dir) -and
          @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
      }
    }
  } elseif (-not $manifestUsed) {
    Say "  [warn]    no SHA256SUMS.txt: falling back to deleting by name. A file of the" -ForegroundColor Yellow
    Say "            same name that belongs to another 7-Zip in this folder would be removed." -ForegroundColor Yellow
    foreach ($name in $ourFiles) {
      if ($handedToHelper -contains $name) { continue }   # the helper deletes uninstall.cmd
      $f = Join-Path $installDirFull $name
      if (Test-Path -LiteralPath $f) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $f)) { $removedFiles++ }
      }
    }
    foreach ($d in @("Lang", "Codecs", "Formats")) {
      $dd = Join-Path $installDirFull $d
      if (Test-Path -LiteralPath $dd) { Remove-Item -LiteralPath $dd -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Ok ("program files removed ({0} files, by name)" -f $removedFiles)
  } else {
    Say "  [skipped] the hash list is not this package's, so no program file was deleted"
  }
  # uninstall.cmd was already put aside for the helper above; the rest of the accounting is
  # done here.
  $leftFiles = @(Get-ChildItem -LiteralPath $installDirFull -File -Force -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -ne (Split-Path $self -Leaf) -and $handedToHelper -notcontains $_.Name })
  $leftDirs = @(Get-ChildItem -LiteralPath $installDirFull -Directory -Force -ErrorAction SilentlyContinue)
  Remove-Item -LiteralPath $self -Force -ErrorAction SilentlyContinue
  if ($leftFiles.Count -eq 0 -and $leftDirs.Count -eq 0) {
    # Nothing of ours and nothing foreign left: remove the (empty) folder itself, which the
    # running script may still hold for a moment, so a helper does it. The batch launcher goes
    # with it, after cmd.exe has had time to finish reading it.
    #
    # The helper must NOT inherit this folder as its working directory: Windows refuses to
    # remove a directory that is some process's current directory, and a user who double-clicks
    # uninstall.cmd right inside the program folder is exactly that case - the folder used to
    # survive as an empty leftover. Both the helper and this script therefore move their own
    # working directory out of the way first.
    $helper = @("/c", "timeout", "/t", "3", ">nul", "&")
    foreach ($name in $handedToHelper) {
      $helper += @("del", "/q", "`"$(Join-Path $installDirFull $name)`"", ">nul", "2>nul", "&")
    }
    $helper += @("rmdir", "/q", "`"$installDirFull`"")
    Start-Process -FilePath "cmd.exe" -ArgumentList $helper -WindowStyle Hidden -WorkingDirectory $env:TEMP
    Ok "program folder (emptied; a helper removes the folder itself)"
  } else {
    Say ""
    Say "  [kept]    this folder still holds something that is not ours, so it stays:" -ForegroundColor Yellow
    Say "            $installDirFull" -ForegroundColor Yellow
    ($leftFiles + $leftDirs) | Select-Object -First 12 | ForEach-Object { Say "              $($_.Name)" -ForegroundColor Yellow }
    if (($leftFiles.Count + $leftDirs.Count) -gt 12) {
      Say ("              ... and {0} more" -f ($leftFiles.Count + $leftDirs.Count - 12)) -ForegroundColor Yellow
    }
    Keep "the program folder (it holds other files): $installDirFull"
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

# An explicit success code: without it the exit code of this script is whatever the last child
# process or failed cmdlet left behind, and uninstall.cmd turns that into "the uninstaller
# reported a problem" even when everything was removed (measured: the no-hash-list fallback
# exited 1 while its folder was gone).
exit 0
