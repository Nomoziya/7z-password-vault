# Round 7: the three blockers the experts found in the uncommitted work.
$ErrorActionPreference = "Stop"
Set-Location "D:\DSH Work\7z-passward"
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Patch([string]$file, [hashtable[]]$pairs) {
  $p = (Resolve-Path $file).Path
  $t = ([IO.File]::ReadAllText($p)) -replace "`r`n", "`n"
  foreach ($pair in $pairs) {
    $from = ($pair.from -replace "`r`n", "`n").TrimEnd("`n")
    $to   = ($pair.to   -replace "`r`n", "`n")
    if ($t.Contains($to) -and $to.Length -gt 20) { continue }   # already applied
    if (-not $t.Contains($from)) { throw "$file : not found -> $($from.Split("`n")[0])" }
    $t = $t.Replace($from, $to)
  }
  [IO.File]::WriteAllText($p, $t, $utf8)
  Write-Host ("  patched {0}" -f (Split-Path $file -Leaf))
}

# =============================================================== the harness
$ui = (Resolve-Path "tests\ui-test.ps1").Path
$t = ([IO.File]::ReadAllText($ui)) -replace "`r`n", "`n"

# E: restore the password character the control really had, and drop the alias
$from = @'
  public static string GetEditText(IntPtr h) {
    long style = GetWindowLongW(h, -16 /*GWL_STYLE*/);
    bool wasPassword = ((style & 0x20 /*ES_PASSWORD*/) != 0);
    if (wasPassword) Send(h, 0x00CC /*EM_SETPASSWORDCHAR*/, IntPtr.Zero, IntPtr.Zero);
    var sb = new StringBuilder(512);
    SendBuf(h, 0x000D, (IntPtr)512, sb);
    if (wasPassword) Send(h, 0x00CC, (IntPtr)0x25CF /* restore a bullet */, IntPtr.Zero);
    return sb.ToString();
  }
  public static string GetEditTextUnmasked(IntPtr h) { return GetEditText(h); }
'@ -replace "`r`n", "`n"
$to = @'
  public static string GetEditText(IntPtr h) {
    long style = GetWindowLongW(h, -16 /*GWL_STYLE*/);
    bool wasPassword = ((style & 0x20 /*ES_PASSWORD*/) != 0);
    long oldChar = 0;
    if (wasPassword) {
      /* Remember what the dialog itself used ('*' for 7-Zip) and put it back afterwards,
         so the control is left exactly as it was found. */
      oldChar = (long)Send(h, 0x00D2 /*EM_GETPASSWORDCHAR*/, IntPtr.Zero, IntPtr.Zero);
      Send(h, 0x00CC /*EM_SETPASSWORDCHAR*/, IntPtr.Zero, IntPtr.Zero);
    }
    var sb = new StringBuilder(512);
    SendBuf(h, 0x000D, (IntPtr)512, sb);
    if (wasPassword) Send(h, 0x00CC, (IntPtr)oldChar, IntPtr.Zero);
    return sb.ToString();
  }
'@ -replace "`r`n", "`n"
if ($t.Contains($from)) { $t = $t.Replace($from, $to) } else { Write-Host "  (reader already patched)" }

# A: creating an entry must never take the whole suite down when the dialog is not there
$from2 = @'
function New-VaultEntry([uint32]$procId, [IntPtr]$dlg, [string]$name, [string]$password, [string]$checkName) {
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))     # new password
  $ed = Expect-Dialog $procId $T.NewPassword $checkName
  [VaultUiTest]::SetEditText((Wait-Child $ed 121 5), $name)
  [VaultUiTest]::SetEditText((Wait-Child $ed 122 5), $password)
  Start-Sleep -Milliseconds 300
  [VaultUiTest]::ClickButton((Wait-Child $ed 1 5))
  Start-Sleep -Seconds 1
  return $ed
}
'@ -replace "`r`n", "`n"
$to2 = @'
function New-VaultEntry([uint32]$procId, [IntPtr]$dlg, [string]$name, [string]$password, [string]$checkName) {
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))     # new password
  $ed = Expect-Dialog $procId $T.NewPassword $checkName
  if ($ed -eq [IntPtr]::Zero) {
    # No name window: the caller is told and this function stops here. Sending a message
    # to a null handle would abort the whole run instead of failing one check.
    return [IntPtr]::Zero
  }
  [VaultUiTest]::SetEditText((Wait-Child $ed 121 5), $name)
  [VaultUiTest]::SetEditText((Wait-Child $ed 122 5), $password)
  Start-Sleep -Milliseconds 300
  [VaultUiTest]::ClickButton((Wait-Child $ed 1 5))
  Start-Sleep -Seconds 1
  return $ed
}
'@ -replace "`r`n", "`n"
if ($t.Contains($from2)) { $t = $t.Replace($from2, $to2) }

# B: test 23 must assert what really happens - a vault that cannot be read refuses, and
#    the file is untouched. Rewrite it from its marker up to the end-of-tests marker.
$start = $t.IndexOf("# ---------------------------------------------------------------- test 23")
$end = $t.IndexOf("} finally {", $start)
if ($start -lt 0 -or $end -lt 0) { throw "test 23 block not found" }
$newTest23 = @'
# ---------------------------------------------------------------- test 23
Write-Host "`n== 23. a vault that cannot be read is never overwritten ==" -ForegroundColor Cyan
# A file with a valid header and a truncated body: it exists, it opens, reading it fails.
# Saving in that state would replace it with the empty list in memory, so the program has
# to refuse - and the file must be byte for byte what it was.
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (damaged vault)"
New-VaultEntry ([uint32]$p.Id) $dlg "damaged-base" "PwDamagedBase" "an entry is stored before the file is damaged"
Stop-Fm $p
Check "the vault exists before it is damaged" (Test-Path $vault)
if ((Test-Path $vault) -and (Get-Item $vault).Length -gt 16) {
  $bytes = [IO.File]::ReadAllBytes($vault)
  $cut = $bytes[0..($bytes.Length - 9)]
  [IO.File]::WriteAllBytes($vault, $cut)
  Check "the vault file is damaged now (shorter than before)" ($cut.Length -lt $bytes.Length)
  $damagedHash = (Get-FileHash -LiteralPath $vault -Algorithm SHA256).Hash

  $p = Start-Fm $archive
  # the vault cannot be read, so the password dialog reports it and offers no name window
  $box = Wait-Dialog ([uint32]$p.Id) $T.Caption 10
  Check "the damaged vault is reported when it is opened" ($box -ne [IntPtr]::Zero)
  if ($box -ne [IntPtr]::Zero) { [void](Close-Box ([uint32]$p.Id) $box $T.Caption) }
  $dlg = Wait-Dialog ([uint32]$p.Id) $T.Password 8
  Check "the password dialog is still usable" ($dlg -ne [IntPtr]::Zero)
  if ($dlg -ne [IntPtr]::Zero) {
    # pressing "new password" must not open the name window: saving is refused
    [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
    $ed = Wait-Dialog ([uint32]$p.Id) $T.NewPassword 4
    Check "no name window opens for an unreadable vault" ($ed -eq [IntPtr]::Zero)
    $again = Wait-Dialog ([uint32]$p.Id) $T.Caption 4
    Check "the refusal is reported" ($again -ne [IntPtr]::Zero)
    if ($again -ne [IntPtr]::Zero) { [void](Close-Box ([uint32]$p.Id) $again $T.Caption) }
  }
  Check "the damaged file was not overwritten" ((Get-FileHash -LiteralPath $vault -Algorithm SHA256).Hash -eq $damagedHash)
  Check "process alive after the damaged vault test" (-not $p.HasExited)
  Stop-Fm $p
}

'@ -replace "`r`n", "`n"
$t = $t.Substring(0, $start) + $newTest23 + $t.Substring($end)
[IO.File]::WriteAllText($ui, $t, $utf8)
Write-Host "  ui-test.ps1: reader restores the real password char, entry helper is defensive, test 23 rewritten"

# =============================================================== uninstaller
Patch "tools\uninstall.ps1" @(
  # C: the file list has to exist before -WhatIf prints it (it used to be defined in the
  #    else branch, so -WhatIf printed nothing)
  @{ from = '  Say "  [would remove] these files in $installDirFull (everything else stays):"
  foreach ($name in $ours) {';
     to   = '  Say "  [would remove] these files in $installDirFull (everything else stays):"
  $ourFiles = @("7zFM.exe", "7zG.exe", "7z.exe", "7z.dll", "7-zip.dll", "7-zip32.dll",
                "7z.sfx", "7zCon.sfx", "7-zip.chm", "History.txt", "License.txt", "readme.txt",
                "descript.ion", "README.md", "BUILD.md", "uninstall.cmd", "uninstall.ps1",
                "install.cmd", "install.ps1", "SHA256SUMS.txt")
  foreach ($name in $ourFiles) {' },
  # F: install.cmd / install.ps1 are added to the payload at build time, so they are not
  #    in the hash list - they are still ours and must be removed
  @{ from = '      if ($e.rel -eq "uninstall.ps1" -or $e.rel -eq "uninstall.cmd" -or $e.rel -eq "SHA256SUMS.txt") { continue }';
     to   = '      if ($e.rel -ieq "uninstall.ps1" -or $e.rel -ieq "uninstall.cmd" -or $e.rel -ieq "SHA256SUMS.txt") { continue }' },
  @{ from = '    Ok ("program files removed ({0} files, checked against SHA256SUMS.txt)" -f $removedFiles)';
     to   = '    # The installer adds these two to the payload after the hash list was written.
    foreach ($extra in @("install.ps1", "install.cmd")) {
      $f = Join-Path $installDirFull $extra
      if (Test-Path -LiteralPath $f) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $f) { $keptFiles += $f } else { $removedFiles++ }
      }
    }
    Ok ("program files removed ({0} files, checked against SHA256SUMS.txt)" -f $removedFiles)' },
  # D: a file that could not be deleted has to be reported (it is the only delete path)
  @{ from = '      if ($hash -eq $e.hash) {
        Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $full)) { $removedFiles++ }
      } else {
        $keptFiles += $full
      }';
     to   = '      if ($hash -eq $e.hash) {
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
      }' },
  # a manifest entry that points at a directory must not be treated as a file
  @{ from = '      if (-not (Test-Path -LiteralPath $full)) { continue }';
     to   = '      if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }' },
  # the name-based fallback list is the same list
  @{ from = '  $ours = @("7zFM.exe", "7zG.exe", "7z.exe", "7z.dll", "7-zip.dll", "7-zip32.dll",
            "7z.sfx", "7zCon.sfx", "7-zip.chm", "History.txt", "License.txt", "readme.txt",
            "descript.ion", "README.md", "BUILD.md", "uninstall.cmd", "uninstall.ps1",
            "install.cmd", "install.ps1", "SHA256SUMS.txt")
  $removedFiles = 0';
     to   = '  $ourFiles = @("7zFM.exe", "7zG.exe", "7z.exe", "7z.dll", "7-zip.dll", "7-zip32.dll",
                "7z.sfx", "7zCon.sfx", "7-zip.chm", "History.txt", "License.txt", "readme.txt",
                "descript.ion", "README.md", "BUILD.md", "uninstall.cmd", "uninstall.ps1",
                "install.cmd", "install.ps1", "SHA256SUMS.txt")
  $removedFiles = 0' },
  @{ from = '    foreach ($name in $ours) {
      $f = Join-Path $installDirFull $name
      if (Test-Path -LiteralPath $f) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $f)) { $removedFiles++ }
      }
    }';
     to   = '    foreach ($name in $ourFiles) {
      $f = Join-Path $installDirFull $name
      if (Test-Path -LiteralPath $f) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $f)) { $removedFiles++ }
      }
    }' }
)

# =============================================================== the two blockers
# G: a location may only be stored once the old file could be read (or was written)
Patch "CPP\7zip\UI\FileManager\PasswordPage.cpp" @(
  @{ from = '  {
    NPasswordVault::CInfo settings;
    settings.Load();
    settings.VaultPath = us2fs(pathU);
    settings.UseMasterPassword = newUseMaster;';
     to   = '  if (!oldVaultReadable && pathChanged)
  {
    /* The old vault could not be read and the location changed: storing the new path
       would point the program at a file that has never been written, while the real
       passwords stay behind - and the next save would create an empty vault there.
       Nothing is stored; the user can change the location once the old file is usable. */
    ::MessageBoxW(*this, PasswordVault_GetText(IDT_PASSWORD_PATH_NEEDS_VAULT,
        L"无法读取当前密码库，因此没有更改位置。\n\n请先确认旧文件可以打开（或把它改名后重试），再修改位置。"),
        PasswordVault_GetCaption(), MB_ICONWARNING | MB_OK);
    return PSNRET_INVALID_NOCHANGEPAGE;
  }

  {
    NPasswordVault::CInfo settings;
    settings.Load();
    settings.VaultPath = us2fs(pathU);
    settings.UseMasterPassword = newUseMaster;' }
)

# H: the file decides its mode; the registry is only the default for a new file
Patch "CPP\7zip\UI\FileManager\PasswordVault.cpp" @(
  @{ from = '      NPasswordVault::CInfo settings;
      settings.Load();
      const bool useMaster = settings.UseMasterPassword;
      const Byte flags = useMaster ? 1 : 0;';
     to   = '      NPasswordVault::CInfo settings;
      settings.Load();
      /* The mode belongs to the file: when this object read one, that file''s mode is
         kept. Only a new vault takes the setting as its default, and an explicit change
         from the settings page overrides both. */
      bool useMaster = _haveLoadedMode ? _masterMode : (settings.UseMasterPassword != 0);
      if (modeOverride >= 0)
        useMaster = (modeOverride != 0);
      const Byte flags = useMaster ? 1 : 0;' },
  @{ from = 'bool CPasswordVault::Save(UString &errorMessage, HWND parent)
{';
     to   = 'bool CPasswordVault::Save(UString &errorMessage, HWND parent, int modeOverride)
{' },
  @{ from = '  _readFailed = true;
  _loadedSize = 0;
  _loadedWriteTime = 0;';
     to   = '  _readFailed = true;
  _loadedSize = 0;
  _loadedWriteTime = 0;
  _haveLoadedMode = false;
  _loadedExisted = false;' },
  @{ from = '  if (ok)
  {
    _readFailed = false;
    RememberFileState();
  }
  return ok;';
     to   = '  if (ok)
  {
    _readFailed = false;
    _haveLoadedMode = true;
    _loadedExisted = true;
    RememberFileState();
  }
  return ok;' },
  # P2-A: an explicit flag instead of the 0/0 sentinel
  @{ from = '      if ((size != _loadedSize || when != _loadedWriteTime) && (_loadedSize != 0 || _loadedWriteTime != 0))
      {';
     to   = '      if (size != _loadedSize || when != _loadedWriteTime)
      {' }
)

Patch "CPP\7zip\UI\FileManager\PasswordVault.h" @(
  @{ from = '  bool _readFailed = false;';
     to   = '  bool _readFailed = false;
  /* Whether this object ever read a file: decides where the mode comes from and whether
     the file may be replaced. */
  bool _haveLoadedMode = false;
  bool _loadedExisted = false;' },
  @{ from = '  bool Save(UString &errorMessage, HWND parent = NULL);';
     to   = '  /* modeOverride: -1 keep (the file decides), 0 DPAPI, 1 master password. */
  bool Save(UString &errorMessage, HWND parent = NULL, int modeOverride = -1);' },
  @{ from = '  static UString GetDefaultPath();';
     to   = '  static bool settings_DefaultMaster();
  static UString GetDefaultPath();' }
)

Patch "CPP\7zip\UI\FileManager\PasswordDialogRes.h" @(
  @{ from = '#define IDT_PASSWORD_ERR_CHANGED        3863';
     to   = '#define IDT_PASSWORD_ERR_CHANGED        3863

/* the location cannot be changed while the current vault is unreadable */
#define IDT_PASSWORD_PATH_NEEDS_VAULT   3864' }
)

# I: the mode-changing buttons pass an explicit override
Patch "CPP\7zip\UI\FileManager\PasswordPage.cpp" @(
  @{ from = '  if (!vault.Save(error, *this))
  {
    NPasswordVault::CInfo back;
    back.Load();
    back.UseMasterPassword = false;';
     to   = '  if (!vault.Save(error, *this, 0))
  {
    NPasswordVault::CInfo back;
    back.Load();
    back.UseMasterPassword = false;' },
  @{ from = '    UString error;
    vault.SetPath(newPath);
    if (!vault.Save(error, *this))';
     to   = '    UString error;
    vault.SetPath(newPath);
    if (!vault.Save(error, *this, newUseMaster ? 1 : 0))' }
)

$rows = @{
  "Lang\en.ttt"    = 'The current vault cannot be read, so the location was not changed.\n\nMake sure the old file can be opened (or rename it) and then change the location.'
  "Lang\en.txt"    = 'The current vault cannot be read, so the location was not changed.\n\nMake sure the old file can be opened (or rename it) and then change the location.'
  "Lang\zh-cn.txt" = '无法读取当前密码库，因此没有更改位置。\n\n请先确认旧文件可以打开（或把它改名后重试），再修改位置。'
  "Lang\zh-tw.txt" = '無法讀取目前密碼庫，因此沒有變更位置。\n\n請先確認舊檔案可以開啟（或將它改名後重試），再修改位置。'
}
foreach ($f in $rows.Keys) {
  $fp = (Resolve-Path $f).Path
  $ft = ([IO.File]::ReadAllText($fp)) -replace "`r`n", "`n"
  if ($ft -match "(?m)^3864$") { continue }
  $ft = $ft.Replace("`n3900`n", "`n3864`n" + $rows[$f] + "`n3900`n")
  [IO.File]::WriteAllText($fp, $ft, $utf8)
  Write-Host "  $f +3864"
}

Write-Host "`ndone"
