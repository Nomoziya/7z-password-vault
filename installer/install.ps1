<#
  install.ps1 - what the setup.exe does after it has extracted the files.

  It creates the shortcuts, registers the program in Windows' "Apps & features"
  (per user, no administrator needed) and prints what to do next. The uninstaller
  next to it is what that entry runs.

  Called by install.cmd, which the self-extracting package runs. It can also be run
  by hand from an extracted folder.
#>

param(
  [string]$InstallDir = "",
  [switch]$NoShortcuts,
  [switch]$Quiet
)

$ErrorActionPreference = "Stop"
if (-not $InstallDir) { $InstallDir = $PSScriptRoot }
$InstallDir = (Resolve-Path -LiteralPath $InstallDir).Path.TrimEnd("\")

$fm = Join-Path $InstallDir "7zFM.exe"
if (-not (Test-Path -LiteralPath $fm)) { throw "7zFM.exe is not in $InstallDir" }

$appName = "7-Zip Password Vault"
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\7ZipPasswordVault"

function Say([string]$text) { if (-not $Quiet) { Write-Host $text } }

# ---------------------------------------------------------------- shortcuts
$created = @()
if (-not $NoShortcuts) {
  $shell = New-Object -ComObject WScript.Shell
  $startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
  New-Item -ItemType Directory -Force -Path $startMenu | Out-Null
  foreach ($spec in @(
      @{ Path = (Join-Path $startMenu "$appName.lnk");        Target = $fm },
      @{ Path = (Join-Path ([Environment]::GetFolderPath("Desktop")) "$appName.lnk"); Target = $fm }
    )) {
    try {
      $lnk = $shell.CreateShortcut($spec.Path)
      $lnk.TargetPath = $spec.Target
      $lnk.WorkingDirectory = $InstallDir
      $lnk.IconLocation = "$fm,0"
      $lnk.Description = "$appName - local encrypted password vault for 7-Zip"
      $lnk.Save()
      $created += $spec.Path
    } catch { Say "  could not create $($spec.Path): $($_.Exception.Message)" }
  }
}

# ---------------------------------------------------------------- Apps & features entry
# Per user, so no administrator is needed. Windows shows it in "Apps & features" and the
# uninstall button runs the uninstaller that ships with the package.
$size = 0
Get-ChildItem -LiteralPath $InstallDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $size += $_.Length }
New-Item -Path $uninstallKey -Force | Out-Null
$info = @{
  DisplayName     = "$appName 26.03"
  DisplayVersion  = "1.4.2"
  Publisher       = "Nomoziya"
  DisplayIcon     = $fm
  InstallLocation = $InstallDir
  UninstallString = "`"$InstallDir\uninstall.cmd`""
  QuietUninstallString = "`"$InstallDir\uninstall.cmd`" -KeepVault -Yes -NoBackup"
  InstallDate     = (Get-Date -Format "yyyyMMdd")
  EstimatedSize   = [int]($size / 1KB)
  NoModify        = 1
  NoRepair        = 1
  URLInfoAbout    = "https://github.com/Nomoziya/7z-password-vault"
}
foreach ($k in $info.Keys) {
  $type = if ($info[$k] -is [int]) { "DWord" } else { "String" }
  Set-ItemProperty -Path $uninstallKey -Name $k -Value $info[$k] -Type $type
}

# ---------------------------------------------------------------- summary
Say ""
Say "$appName is installed in:"
Say "  $InstallDir"
if ($created.Count) { Say "Shortcuts: $($created.Count) created (Start Menu, Desktop)" }
Say ""
Say "The password vault lives next to the program ($InstallDir\7zPasswordVault.dat),"
Say "so it does not use space on the system drive. To keep it somewhere else, set the"
Say "location in Tools -> Options -> Password manager - a folder is accepted too."
Say ""
Say "To make 7z / zip files open with this build and get their icons back:"
Say "  Tools -> Options -> System -> select the formats -> OK"
Say ""
Say "Uninstall: Apps & features (or `"$InstallDir\uninstall.cmd`")"
Say ""
