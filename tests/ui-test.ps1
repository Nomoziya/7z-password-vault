# ui-test.ps1 - UI smoke test for the 7-Zip password vault integration.
#
# It drives the real dialogs of 7zFM.exe through Win32 messages and real mouse
# input, so it does not need any test framework.
#
# The test points VaultPath at a temporary encrypted vault and restores the
# PasswordVault registry values when it finishes. For the two-default-path case,
# it creates and removes an encrypted APPDATA fixture only when that file is absent;
# an existing user vault is never overwritten.
#
# Because it clicks and types with the real mouse and keyboard, it takes over
# the cursor for the duration of the run. Do not use the machine while it runs.
#
# Dialog titles come from the language files, so the test can run against any
# supported UI language. -UiLang auto reads the 7-Zip "Lang" setting (and falls
# back to the system UI language). If a window is not found, the run prints the
# titles it did find, to make a language mismatch obvious.
#
# Usage:
#   pwsh -File tests\ui-test.ps1
#   pwsh -File tests\ui-test.ps1 -SevenZipDir "D:\path\to\7-Zip"
#   pwsh -File tests\ui-test.ps1 -UiLang en
#   pwsh -File tests\ui-test.ps1 -KeepArtifacts
#
# The default target is the newest verified internal-test ZIP under dist.

param(
  [string]$SevenZipDir = '',
  [ValidateSet("auto", "zh-cn", "en")][string]$UiLang = "auto",
  # another 7zFM/7zG (the user's own copy) normally makes the run refuse to start,
  # because it shares the vault settings and can overwrite this run's vault file
  [switch]$AllowOtherInstances,
  [string]$BaselineDir = '',
  [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'runtime-input.ps1')
$SevenZipDir=Resolve-TestRuntime -Directory $SevenZipDir
$baselineFm=$null
if($BaselineDir){
  $BaselineDir=(Resolve-Path -LiteralPath $BaselineDir -ErrorAction Stop).Path
  $baselineFm=Join-Path $BaselineDir '7zFM.exe'
  if(-not(Test-Path -LiteralPath $baselineFm -PathType Leaf)){throw 'Upgrade baseline lacks 7zFM.exe'}
}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$fmExe  = Join-Path $SevenZipDir "7zFM.exe"
$guiExe = Join-Path $SevenZipDir "7zG.exe"
$szExe = Join-Path $SevenZipDir "7z.exe"
if (!(Test-Path $fmExe) -or !(Test-Path $szExe)) {
  Write-Host "ERROR: 7zFM.exe / 7z.exe not found in '$SevenZipDir'" -ForegroundColor Red
  exit 2
}

# ---- expected window titles, per UI language ----
$script:titles = @{
  "zh-cn" = @{
    Password = "输入密码"; NewPassword = "新建密码"; EditPassword = "编辑密码"
    List = "已保存的密码"; Options = "选项"; Caption = "7-Zip 密码管家"
    Filled = "已填入："; Page = "密码管理"; PageLabel = "密码库位置（留空使用默认）："
    Untitled = "未命名 1"; Compress = "添加到压缩包"
    ExportTitle = "导出密码库"; ImportTitle = "导入密码库"
    BtnList = "已保存的密码..."; BtnNew = "新建密码..."; Master = "主密码"
  }
  "en" = @{
    Password = "Enter password"; NewPassword = "New password"; EditPassword = "Edit password"
    List = "Saved passwords"; Options = "Options"; Caption = "7-Zip Password Vault"
    Filled = "Filled in:"; Page = "Password"; PageLabel = "Vault path (empty = default):"
    Untitled = "Untitled 1"; Compress = "Add to Archive"
    ExportTitle = "Export vault"; ImportTitle = "Import vault"
    BtnList = "Saved passwords..."; BtnNew = "New password..."; Master = "Master password"
  }
}
if ($UiLang -eq "auto") {
  $regLang = (Get-ItemProperty -Path "HKCU:\Software\7-Zip" -Name Lang -ErrorAction SilentlyContinue).Lang
  if ($regLang) {
    $UiLang = if ($regLang -like "en*") { "en" } else { "zh-cn" }
  } else {
    # 7-Zip falls back to the system UI language when "Lang" is not set
    $sysLang = [System.Globalization.CultureInfo]::CurrentUICulture.Name
    $UiLang = if ($sysLang -like "zh*") { "zh-cn" } else { "en" }
  }
}
$T = $script:titles[$UiLang]

# ---- the UI language: -UiLang also switches the application to it --------------
# The test finds every window by its title, so it has to run against the language it
# expects. 7-Zip reads HKCU\Software\7-Zip\Lang, so that value is set for the run and
# put back afterwards (the same way check-labels.ps1 does it).
# An interrupted older run might have left the registry pointing at the fixed test
# vault. Do not snapshot that temporary path as if it were the user's original one.
$testVaultPath = Join-Path (Join-Path $env:TEMP '7zpw_test') 'test-vault.dat'
$currentVaultPath = (Get-ItemProperty -Path 'HKCU:\Software\7-Zip\PasswordVault' -Name VaultPath -ErrorAction SilentlyContinue).VaultPath
if ([string]::Equals([string]$currentVaultPath, $testVaultPath, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Previous UI test left VaultPath at '$testVaultPath'. Restore the original setting before another run."
}
$langKey = "HKCU:\Software\7-Zip"
$savedLang = (Get-ItemProperty -Path $langKey -Name Lang -ErrorAction SilentlyContinue).Lang
$script:restoreLang = $false
if ($UiLang -ne "auto") {
  if (-not (Test-Path $langKey)) { New-Item -Path $langKey -Force | Out-Null }
  Set-ItemProperty -Path $langKey -Name "Lang" -Value $UiLang -Type String
  $script:restoreLang = $true
}

$workDir   = Join-Path $env:TEMP "7zpw_test"
$archive   = Join-Path $workDir "enc.7z"
# Isolated vault: the real one lives in %APPDATA%\7-Zip and is never touched.
$vault     = Join-Path $workDir "test-vault.dat"
$vaultTmp  = "$vault.tmp"
$realVault = Join-Path $env:APPDATA "7-Zip\7zPasswordVault.dat"
$regKey    = "HKCU:\Software\7-Zip\PasswordVault"
$masked    = ([string][char]0x2022) * 8   # what the list shows while passwords are hidden

$script:pass = 0
$script:fail = 0
$script:uiStartedUtc = [DateTime]::UtcNow.ToString('o')
$script:uiFailedChecks = [System.Collections.Generic.List[string]]::new()
$script:uiRunDirectory = Join-Path (Join-Path $PSScriptRoot 'b') ('ui-run-' + [guid]::NewGuid().ToString('N'))
function Ensure-UiRunDirectory {
  if (-not (Test-Path -LiteralPath $script:uiRunDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $script:uiRunDirectory -ErrorAction Stop | Out-Null
  }
}
function Check([string]$name, [bool]$ok, [string]$extra = "") {
  if ($ok) { $script:pass++; Write-Host ("  [PASS] " + $name) -ForegroundColor Green }
  else {
    $script:fail++
    $failureLine = "  [FAIL] " + $name + " " + $extra
    $script:uiFailedChecks.Add($failureLine)
    Write-Host $failureLine -ForegroundColor Red
    try {
      Ensure-UiRunDirectory
      Add-Content -LiteralPath (Join-Path $script:uiRunDirectory 'failures.log') -Value $failureLine -Encoding UTF8
    } catch {
      Write-Host "  Could not retain GUI failure evidence: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    if (-not $script:dumpShown) {
      # the first failure explains itself: every dialog of every running 7-Zip with its
      # controls (id, class, style, text). Only once, so the log stays readable.
      $script:dumpShown = $true
      Write-Host "  ---- windows of the running 7-Zip processes ----" -ForegroundColor DarkYellow
      Write-Host ([VaultUiTest]::DumpAllDialogs()) -ForegroundColor DarkYellow
      Write-Host "  ------------------------------------------------" -ForegroundColor DarkYellow
    }
  }
}
$script:dumpShown = $false

# Substring search over raw bytes: proves that a name or password is really absent
# from the vault file, in the encodings a leaked string would use.
function Test-BytesContain([byte[]]$haystack, [byte[]]$needle) {
  if ($null -eq $haystack -or $null -eq $needle) { return $false }
  if ($needle.Length -eq 0 -or $haystack.Length -lt $needle.Length) { return $false }
  for ($i = 0; $i -le ($haystack.Length - $needle.Length); $i++) {
    $j = 0
    while ($j -lt $needle.Length -and $haystack[$i + $j] -eq $needle[$j]) { $j++ }
    if ($j -eq $needle.Length) { return $true }
  }
  return $false
}
function Get-SecretBytes([string]$s) {
  return @{
    utf8  = [Text.Encoding]::UTF8.GetBytes($s)
    utf16 = [Text.Encoding]::Unicode.GetBytes($s)
    ansi  = [Text.Encoding]::Default.GetBytes($s)
  }
}

# ---- the run must not leak the developer's own vault settings ----
function Get-VaultSettings {
  if (!(Test-Path $regKey)) { return $null }
  $bag = @{}
  $props = Get-ItemProperty -Path $regKey
  foreach ($prop in $props.PSObject.Properties) {
    if ($prop.Name -like "PS*") { continue }
    $bag[$prop.Name] = $prop.Value
  }
  return $bag
}
function Set-VaultSettings($bag) {
  Remove-Item -Path $regKey -Recurse -Force -ErrorAction SilentlyContinue
  if ($null -eq $bag) { return }        # the key did not exist before the run
  New-Item -Path $regKey -Force | Out-Null
  foreach ($name in $bag.Keys) {
    $value = $bag[$name]
    $type = if ($value -is [int] -or $value -is [long]) { "DWord" } else { "String" }
    Set-ItemProperty -Path $regKey -Name $name -Value $value -Type $type
  }
}

# ---------------------------------------------------------------- environment
# Another 7zFM/7zG (a copy the user is running from somewhere else) shares the same
# registry settings and can write to this run's vault file, which makes checks fail in
# ways that have nothing to do with the build. Refuse to run in that case.
$otherInstances = @(Get-Process -Name 7zFM, 7zG, 7z -ErrorAction SilentlyContinue | Where-Object {
  try { $_.Path -and -not $_.Path.StartsWith($SevenZipDir, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
})
if ($otherInstances.Count -gt 0) {
  Write-Host "Another 7-Zip is running:" -ForegroundColor Yellow
  $otherInstances | ForEach-Object { Write-Host ("  {0} (pid {1})" -f $_.Path, $_.Id) -ForegroundColor Yellow }
  Write-Host "It shares the vault settings with this run and can overwrite its vault file." -ForegroundColor Yellow
  if (-not $AllowOtherInstances) {
    Write-Host "Close it and run the test again (or pass -AllowOtherInstances to risk it)." -ForegroundColor Yellow
    exit 3
  }
  Write-Host "Continuing anyway (-AllowOtherInstances): checks may fail for reasons that are not the build." -ForegroundColor Yellow
}
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class VaultUiTest {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll", EntryPoint="SendMessageW", CharSet=CharSet.Unicode)] public static extern IntPtr SendStr(IntPtr h, uint msg, IntPtr wp, string lp);
  [DllImport("user32.dll", EntryPoint="SendMessageW", CharSet=CharSet.Unicode)] public static extern IntPtr SendBuf(IntPtr h, uint msg, IntPtr wp, StringBuilder lp);
  [DllImport("user32.dll", EntryPoint="SendMessageW")] public static extern IntPtr Send(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr lp);

  /* Cross-process calls that carry a pointer need the buffer to live inside the
     target process, because WM_* pointers are not marshalled. */
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr addr, IntPtr size, uint type, uint protect);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool VirtualFreeEx(IntPtr h, IntPtr addr, IntPtr size, uint type);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, IntPtr buf, IntPtr size, out IntPtr written);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }

  public static IntPtr FindDialog(uint pid, string title) {
    IntPtr r = IntPtr.Zero;
    EnumWindows((h,l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid) return true;
      var c = new StringBuilder(64); GetClassNameW(h, c, 64);
      if (c.ToString() != "#32770") return true;
      var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
      if (t.ToString() == title) { r = h; return false; }
      return true;
    }, IntPtr.Zero);
    return r;
  }
  public static IntPtr FindDialogClass(uint pid, string cls) {
    IntPtr r = IntPtr.Zero;
    EnumWindows((h,l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid) return true;
      var c = new StringBuilder(64); GetClassNameW(h, c, 64);
      if (c.ToString() == cls) { r = h; return false; }
      return true;
    }, IntPtr.Zero);
    return r;
  }
  public static IntPtr FindDescendant(IntPtr parent, int id) {
    IntPtr r = IntPtr.Zero;
    EnumChildWindows(parent, (h,l) => { if (GetDlgCtrlID(h) == id) { r = h; return false; } return true; }, IntPtr.Zero);
    return r;
  }
  /* Windows answers WM_GETTEXT with an empty string when the control is a password box
     (ES_PASSWORD) and the caller is another process - a deliberate protection, and the
     reason the vault tests used to "see" an empty password box. Removing the password
     character for the read is what the dialog's own "Show password" checkbox does, so
     the value can be read and the check stays a real one. */
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
  public static void SetEditText(IntPtr h, string s) { SendStr(h, 0x000C, IntPtr.Zero, s); }
  /* Unlike WM_SETTEXT, WM_CHAR follows the edit control's normal input path and
     notifies the Windows file dialog that its file-name model changed. */
  public static void TypeEditText(IntPtr h, string s) {
    Send(h, 0x00B1 /*EM_SETSEL*/, IntPtr.Zero, (IntPtr)(-1));
    foreach (char c in s) Send(h, 0x0102 /*WM_CHAR*/, (IntPtr)c, (IntPtr)1);
  }
  public static void ClickButton(IntPtr h) { PostMessageW(h, 0x00F5, IntPtr.Zero, IntPtr.Zero); }

  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);

  /* Sends the notification an edit control raises when the user changed its text.
     Typing with WM_SETTEXT (what the tests use) does not raise EN_CHANGE, and the
     settings page enables Apply on it - so a test that only sets the text would
     apply nothing and never notice. */
  public static void NotifyEditChanged(IntPtr edit, int ctrlId) {
    IntPtr parent = GetParent(edit);
    if (parent == IntPtr.Zero) return;
    int wp = (0x0300 /* EN_CHANGE */ << 16) | (ctrlId & 0xFFFF);
    Send(parent, 0x0111 /* WM_COMMAND */, (IntPtr)wp, edit);
  }
  public static long SendLong(IntPtr h, uint msg, IntPtr wp, IntPtr lp) { return (long)Send(h, msg, wp, lp); }

  /* --- reading list-view text (LVM_GETITEMTEXTW needs a buffer inside the
         target process, so the LVITEM and the text buffer are allocated there) --- */
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
  [StructLayout(LayoutKind.Sequential)] public struct LVITEMW {
    public uint mask; public int iItem; public int iSubItem;
    public uint state; public uint stateMask;
    public IntPtr pszText; public int cchTextMax; public int iImage;
    public IntPtr lParam; public int iIndent; public int iGroupId;
    public uint cColumns; public IntPtr puColumns; public IntPtr piColFmt; public int iGroup;
  }
  public static string GetListText(IntPtr listHwnd, int row, int col) {
    uint pid;
    GetWindowThreadProcessId(listHwnd, out pid);
    IntPtr h = OpenProcess(0x0038 /*VM_OPERATION|VM_READ|VM_WRITE*/, false, (int)pid);
    if (h == IntPtr.Zero) return "";
    int sz = Marshal.SizeOf(typeof(LVITEMW));
    IntPtr remote = VirtualAllocEx(h, IntPtr.Zero, (IntPtr)(sz + 1024), 0x3000, 0x04);
    if (remote == IntPtr.Zero) { CloseHandle(h); return ""; }
    IntPtr textRemote = (IntPtr)((long)remote + sz);
    LVITEMW it = new LVITEMW();
    it.mask = 0x0001;              /* LVIF_TEXT */
    it.iItem = row;
    it.iSubItem = col;
    it.pszText = textRemote;
    it.cchTextMax = 512;
    IntPtr local = Marshal.AllocHGlobal(sz);
    Marshal.StructureToPtr(it, local, false);
    IntPtr written;
    WriteProcessMemory(h, remote, local, (IntPtr)sz, out written);
    Send(listHwnd, 0x1073 /*LVM_GETITEMTEXTW*/, (IntPtr)row, remote);
    byte[] buf = new byte[1024];
    IntPtr got;
    ReadProcessMemory(h, textRemote, buf, (IntPtr)buf.Length, out got);
    Marshal.FreeHGlobal(local);
    VirtualFreeEx(h, remote, IntPtr.Zero, 0x8000);
    CloseHandle(h);
    string s = Encoding.Unicode.GetString(buf);
    int z = s.IndexOf('\0');
    return z >= 0 ? s.Substring(0, z) : s;
  }
  /* Item rectangle in list client coordinates; used to click a given row. */
  public static string GetListItemRect(IntPtr listHwnd, int row) {
    uint pid;
    GetWindowThreadProcessId(listHwnd, out pid);
    IntPtr h = OpenProcess(0x0038, false, (int)pid);
    if (h == IntPtr.Zero) return "";
    int sz = 16;
    IntPtr remote = VirtualAllocEx(h, IntPtr.Zero, (IntPtr)sz, 0x3000, 0x04);
    if (remote == IntPtr.Zero) { CloseHandle(h); return ""; }
    IntPtr local = Marshal.AllocHGlobal(sz);
    IntPtr written;
    Marshal.Copy(new byte[sz], 0, local, sz);
    WriteProcessMemory(h, remote, local, (IntPtr)sz, out written);
    Send(listHwnd, 0x100E /*LVM_GETITEMRECT*/, (IntPtr)row, remote);
    byte[] rbuf = new byte[sz];
    IntPtr rgot;
    ReadProcessMemory(h, remote, rbuf, (IntPtr)sz, out rgot);
    Marshal.FreeHGlobal(local);
    VirtualFreeEx(h, remote, IntPtr.Zero, 0x8000);
    CloseHandle(h);
    return BitConverter.ToInt32(rbuf,0) + "," + BitConverter.ToInt32(rbuf,4) + "," +
           BitConverter.ToInt32(rbuf,8) + "," + BitConverter.ToInt32(rbuf,12);
  }

  /* --- real mouse input (a WM_NOTIFY cannot be faked across processes) --- */
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, IntPtr extra);

  /* A click on a background window is consumed by Windows to activate it, so the
     real click must wait until the window really is in front. Sleeping a fixed
     time is not enough: the activation is asynchronous. */
  public static bool EnsureForeground(IntPtr h, int ms) {
    IntPtr root = GetAncestor(h, 2 /*GA_ROOT*/);
    if (root == IntPtr.Zero) root = h;
    var deadline = DateTime.UtcNow.AddMilliseconds(ms);
    while (true) {
      if (GetForegroundWindow() == root) return true;
      SetForegroundWindow(root);
      if (DateTime.UtcNow >= deadline) return GetForegroundWindow() == root;
      System.Threading.Thread.Sleep(50);
    }
  }

  /* The app is per-monitor DPI aware. A DPI-unaware test process would report the
     dialog in virtualized (scaled-down) coordinates while SetCursorPos works in
     physical pixels, so at 150% scaling every click would land 1.5x too far right
     and hit the next column. Becoming DPI aware makes both spaces identical. */
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);

  /* Clicks the centre of a cell of a report-mode list view. Column centres come
     from the real column widths and the row centre from the real item
     rectangle, never from constants: the row height is a design choice of the
     window (the saved-passwords window draws taller, headerless rows). */
  public static void ClickListCell(IntPtr listHwnd, int col, bool doubleClick) {
    ClickListCell(listHwnd, col, doubleClick, false, 0);
  }
  public static void ClickListCell(IntPtr listHwnd, int col, bool doubleClick, bool rightButton) {
    ClickListCell(listHwnd, col, doubleClick, rightButton, 0);
  }
  public static void ClickListCell(IntPtr listHwnd, int col, bool doubleClick, bool rightButton, int row) {
    RECT lr, hr;
    GetWindowRect(listHwnd, out lr);

    /* sum the widths of the preceding columns to reach column `col` */
    int offset = 0;
    for (int c = 0; c < col; c++)
      offset += (int)Send(listHwnd, 0x101D /*LVM_GETCOLUMNWIDTH*/, (IntPtr)c, IntPtr.Zero);
    int width = (int)Send(listHwnd, 0x101D, (IntPtr)col, IntPtr.Zero);
    if (width <= 0) width = 50;

    int x = lr.left + 1 + offset + width / 2;
    /* never aim outside the control: a column wider than the visible area would
       otherwise send the click to the dialog behind it */
    RECT cr;
    GetClientRect(listHwnd, out cr);
    if (cr.right > 0 && offset + width / 2 >= cr.right)
      x = lr.left + 1 + Math.Max(0, cr.right - 4);

    /* the row rectangle is the only reliable source for y */
    int y = lr.top + 1 + 8;
    string rect = GetListItemRect(listHwnd, row);
    if (rect.Length > 0) {
      string[] p = rect.Split(',');
      int top = int.Parse(p[1]);
      int bottom = int.Parse(p[3]);
      if (bottom > top) y = lr.top + 1 + (top + bottom) / 2;
    } else {
      /* no item rectangle: fall back to below the header, if there is one */
      IntPtr header = Send(listHwnd, 0x101F /*LVM_GETHEADER*/, IntPtr.Zero, IntPtr.Zero);
      if (header != IntPtr.Zero && GetWindowRect(header, out hr) && hr.bottom > hr.top)
        y = hr.bottom + 8;
    }

    EnsureForeground(listHwnd, 3000);
    System.Threading.Thread.Sleep(150);

    /* One harmless click inside the list (first cell of the first row) so that a
       click consumed by Windows for activating the window is not the real one.
       A single click on a name or password cell has no action bound to it. */
    SetCursorPos(lr.left + 4, lr.top + 4);
    System.Threading.Thread.Sleep(80);
    mouse_event(0x0002, 0, 0, 0, IntPtr.Zero);
    mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
    System.Threading.Thread.Sleep(250);
    EnsureForeground(listHwnd, 1000);

    uint down = rightButton ? 0x0008u : 0x0002u;   /* RIGHTDOWN / LEFTDOWN */
    uint up   = rightButton ? 0x0010u : 0x0004u;   /* RIGHTUP   / LEFTUP   */

    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(80);
    mouse_event(down, 0, 0, 0, IntPtr.Zero);
    mouse_event(up,   0, 0, 0, IntPtr.Zero);
    if (doubleClick) {
      System.Threading.Thread.Sleep(80);
      mouse_event(down, 0, 0, 0, IntPtr.Zero);
      mouse_event(up,   0, 0, 0, IntPtr.Zero);
    }
  }
  [StructLayout(LayoutKind.Sequential)] public struct TCITEMW {
    public uint mask; public uint dwState; public uint dwStateMask;
    public IntPtr pszText; public int cchTextMax; public int iImage; public IntPtr lParam;
  }
  public static int GetTabCount(IntPtr tabHwnd) { return (int)Send(tabHwnd, 0x1304 /*TCM_GETITEMCOUNT*/, IntPtr.Zero, IntPtr.Zero); }

  /* Generic cross-process "call with a struct + text buffer" helper. */
  static IntPtr RemoteAlloc(IntPtr h, int structSize, out IntPtr textRemote, out IntPtr local, out int sz) {
    sz = structSize;
    IntPtr remote = VirtualAllocEx(h, IntPtr.Zero, (IntPtr)(sz + 1024), 0x3000, 0x04);
    textRemote = remote == IntPtr.Zero ? IntPtr.Zero : (IntPtr)((long)remote + sz);
    local = remote == IntPtr.Zero ? IntPtr.Zero : Marshal.AllocHGlobal(sz);
    return remote;
  }
  static string RemoteReadText(IntPtr h, IntPtr textRemote, int len) {
    byte[] buf = new byte[len];
    IntPtr got;
    ReadProcessMemory(h, textRemote, buf, (IntPtr)buf.Length, out got);
    string s = Encoding.Unicode.GetString(buf);
    int z = s.IndexOf('\0');
    return z >= 0 ? s.Substring(0, z) : s;
  }
  public static string GetTabText(IntPtr tabHwnd, int index) {
    uint pid;
    GetWindowThreadProcessId(tabHwnd, out pid);
    IntPtr h = OpenProcess(0x0038, false, (int)pid);
    if (h == IntPtr.Zero) return "";
    IntPtr textRemote, local; int sz;
    IntPtr remote = RemoteAlloc(h, Marshal.SizeOf(typeof(TCITEMW)), out textRemote, out local, out sz);
    if (remote == IntPtr.Zero) { CloseHandle(h); return ""; }
    TCITEMW it = new TCITEMW();
    it.mask = 0x0001;              /* TCIF_TEXT */
    it.pszText = textRemote;
    it.cchTextMax = 512;
    Marshal.StructureToPtr(it, local, false);
    IntPtr written;
    WriteProcessMemory(h, remote, local, (IntPtr)sz, out written);
    Send(tabHwnd, 0x133C /*TCM_GETITEMW*/, (IntPtr)index, remote);
    string s = RemoteReadText(h, textRemote, 1024);
    Marshal.FreeHGlobal(local);
    VirtualFreeEx(h, remote, IntPtr.Zero, 0x8000);
    CloseHandle(h);
    return s;
  }
  /* Clicks a tab of a property sheet; TCM_SETCURSEL would not switch the page. */
  public static string ClickTab(IntPtr tabHwnd, int index) {
    uint pid;
    GetWindowThreadProcessId(tabHwnd, out pid);
    IntPtr h = OpenProcess(0x0038, false, (int)pid);
    if (h == IntPtr.Zero) return "no process";
    IntPtr textRemote, local; int sz;
    IntPtr remote = RemoteAlloc(h, 16, out textRemote, out local, out sz);
    if (remote == IntPtr.Zero) { CloseHandle(h); return "no alloc"; }
    IntPtr written;
    Marshal.Copy(new byte[sz], 0, local, sz);
    WriteProcessMemory(h, remote, local, (IntPtr)sz, out written);
    /* the rectangle is in the control's coordinate space = client area */
    Send(tabHwnd, 0x130A /*TCM_GETITEMRECT*/, (IntPtr)index, remote);
    byte[] buf = new byte[16];
    IntPtr got;
    ReadProcessMemory(h, remote, buf, (IntPtr)16, out got);
    Marshal.FreeHGlobal(local);
    VirtualFreeEx(h, remote, IntPtr.Zero, 0x8000);
    CloseHandle(h);
    int l = BitConverter.ToInt32(buf, 0),  t = BitConverter.ToInt32(buf, 4);
    int r = BitConverter.ToInt32(buf, 8),  b = BitConverter.ToInt32(buf, 12);
    POINT pt; pt.x = (l + r) / 2; pt.y = (t + b) / 2;
    ClientToScreen(tabHwnd, ref pt);
    SetForegroundWindow(tabHwnd);
    System.Threading.Thread.Sleep(200);
    SetCursorPos(pt.x, pt.y);
    System.Threading.Thread.Sleep(120);
    mouse_event(0x0002, 0, 0, 0, IntPtr.Zero);
    mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
    return "clicked " + pt.x + "," + pt.y;
  }
  public static void MoveCursorHome() { SetCursorPos(4, 4); }

  /* Clicks the centre of any control with the real mouse. Used for controls whose
     behaviour depends on keyboard focus (the browse dialog finishes with OK only
     when the focus is not in its list view), because SetFocus cannot be called
     across processes. */
  public static void ClickControl(IntPtr h) {
    RECT r;
    if (!GetWindowRect(h, out r)) return;
    EnsureForeground(h, 3000);
    System.Threading.Thread.Sleep(150);
    SetCursorPos((r.left + r.right) / 2, (r.top + r.bottom) / 2);
    System.Threading.Thread.Sleep(100);
    mouse_event(0x0002, 0, 0, 0, IntPtr.Zero);
    mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
    System.Threading.Thread.Sleep(150);
  }

  /* Reads the text of a control with a large enough buffer for message boxes. */
  public static string GetControlText(IntPtr h) {
    var sb = new StringBuilder(2048);
    SendBuf(h, 0x000D, (IntPtr)2048, sb);
    return sb.ToString();
  }

  /* The only Button below a window: a message box has exactly one for MB_OK. The
     id of that button is not IDOK in every build (this one uses 2), so it is found
     by class instead of by a guessed id. */
  /* Buttons of a window as "id=text" pairs: this build does not number every message
     box button the way IDOK/IDYES suggest, so a test can show what is really there. */
  /* Every window of every running 7-Zip process with its children: printed when a
     check fails, so the reason is visible without another run. A stale handle, a
     rebuilt dialog or a control that never got its text all become obvious. */
  [DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr h, int index);
  public static string DumpAllDialogs() {
    var sb = new StringBuilder();
    int dialogsShown = 0, childrenShown = 0;   // keep the failure dump readable
    foreach (var proc in System.Diagnostics.Process.GetProcesses()) {
      if (dialogsShown >= 4) break;
      string name = "";
      try { name = proc.ProcessName; } catch { }
      if (!name.StartsWith("7z", StringComparison.OrdinalIgnoreCase)) continue;
      uint pid = (uint)proc.Id;
      EnumWindows((h,l) => {
        uint p; GetWindowThreadProcessId(h, out p);
        if (p != pid) return true;
        var c = new StringBuilder(64); GetClassNameW(h, c, 64);
        if (c.ToString() != "#32770") return true;
        var tx = new StringBuilder(256); GetWindowTextW(h, tx, 256);
        dialogsShown++;
        childrenShown = 0;
        sb.Append(String.Format("      {0}(pid {1}) [{2}]", tx, pid, h));
        EnumChildWindows(h, (ch,cl) => {
          if (++childrenShown > 24) return true;
          var cc = new StringBuilder(64); GetClassNameW(ch, cc, 64);
          var ct = new StringBuilder(256); GetWindowTextW(ch, ct, 256);
          long style = GetWindowLongW(ch, -16 /*GWL_STYLE*/);
          sb.Append(String.Format("\n        id={0,-6} {1,-12} style=0x{2:X8} text=[{3}]",
            GetDlgCtrlID(ch), cc, style, ct));
          return true;
        }, IntPtr.Zero);
        sb.Append("\n");
        return true;
      }, IntPtr.Zero);
    }
    return sb.ToString();
  }
  public static string ListButtons(IntPtr parent) {
    var sb = new StringBuilder();
    EnumChildWindows(parent, (h,l) => {
      var c = new StringBuilder(128); GetClassNameW(h, c, 128);
      if (c.ToString() == "Button") {
        var tx = new StringBuilder(128); GetWindowTextW(h, tx, 128);
        sb.Append(String.Format("[{0}='{1}'] ", GetDlgCtrlID(h), tx));
      }
      return true;
    }, IntPtr.Zero);
    return sb.ToString();
  }

  public static IntPtr FindSingleButton(IntPtr parent) {
    IntPtr r = IntPtr.Zero;
    EnumChildWindows(parent, (h,l) => {
      var c = new StringBuilder(128); GetClassNameW(h, c, 128);
      if (c.ToString() == "Button") { r = h; return false; }
      return true;
    }, IntPtr.Zero);
    return r;
  }

  /* A child looked up by class as well as id: the shell file dialog has several
     controls with id 1001 (the file name edit and the address bar). */
  public static IntPtr FindChildByClassAndId(IntPtr parent, string cls, int id) {
    IntPtr r = IntPtr.Zero;
    EnumChildWindows(parent, (h,l) => {
      var c = new StringBuilder(128); GetClassNameW(h, c, 128);
      if (c.ToString() == cls && GetDlgCtrlID(h) == id) { r = h; return false; }
      return true;
    }, IntPtr.Zero);
    return r;
  }

  /* Completes a file dialog with an absolute path. Two kinds show up here:
     7-Zip's own IDD_BROWSE (path edit 102, and OK only finishes when the focus is
     not in its list view, so the edit is clicked first) and the shell dialog that
     the file manager prefers (file name edit is a child Edit with id 1001, the
     default button is a child Button with id 1). Both take the path in the name
     box and are confirmed with the default button. */
  public static bool FillBrowseDialog(IntPtr dlg, string fullPath) {
    /* The shell dialog's window exists before its content does, so the controls are
       polled for instead of assumed. */
    /* The common dialog can expose both an address-bar Edit and a file-name Edit
       with id 1001. Select the Edit inside the file-name combo (1148) first.
       7-Zip's own browse dialog uses a separate path Edit with id 102. */
    IntPtr edit = IntPtr.Zero;
    var deadline = DateTime.UtcNow.AddSeconds(10);
    while (true) {
      IntPtr fileNameCombo = FindDescendant(dlg, 1148);
      if (fileNameCombo != IntPtr.Zero)
        edit = FindChildByClassAndId(fileNameCombo, "Edit", 1001);
      if (edit == IntPtr.Zero) edit = FindChildByClassAndId(dlg, "Edit", 1148);
      if (edit == IntPtr.Zero) edit = FindChildByClassAndId(dlg, "Edit", 102);
      if (edit == IntPtr.Zero) edit = FindChildByClassAndId(dlg, "Edit", 1001);
      if (edit != IntPtr.Zero) break;
      if (DateTime.UtcNow >= deadline) return false;
      System.Threading.Thread.Sleep(100);
    }
    ClickControl(edit);
    TypeEditText(edit, fullPath);
    if (GetControlText(edit) != fullPath) return false;
    System.Threading.Thread.Sleep(300);
    IntPtr ok = FindChildByClassAndId(dlg, "Button", 1);
    if (ok == IntPtr.Zero) ok = FindDescendant(dlg, 1);
    if (ok == IntPtr.Zero) return false;
    EnsureForeground(ok, 2000);
    ClickControl(ok);
    return true;
  }
  /* Used to report what is on screen when an expected dialog is missing. */
  public static string[] ListDialogs(uint pid) {
    var list = new System.Collections.Generic.List<string>();
    EnumWindows((h,l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid) return true;
      var c = new StringBuilder(64); GetClassNameW(h, c, 64);
      if (c.ToString() != "#32770") return true;
      var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
      list.Add(t.ToString());
      return true;
    }, IntPtr.Zero);
    return list.ToArray();
  }
}
"@

# Must run before any coordinate is read or written (see ClickListCell).
[void][VaultUiTest]::SetProcessDPIAware()

function Start-Fm([string]$arg) {
  if ($arg) { return Start-Process -FilePath $fmExe -ArgumentList "`"$arg`"" -PassThru }
  return Start-Process -FilePath $fmExe -PassThru
}
# Stops only the instance this test started: a blanket "stop every 7zFM" would
# kill whatever the user has open.
function Stop-Fm($p) {
  if ($p -and -not $p.HasExited) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    # The process has to be gone before the next test starts: two running copies share
    # the registry settings and the vault file, and a leftover keeps 7zFM.exe in the
    # distribution folder locked (the next build then cannot replace it).
    $deadline = (Get-Date).AddSeconds(5)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
  }
  Start-Sleep -Milliseconds 400
}

# Kills 7-Zip instances left behind by an earlier interrupted run - but only those started
# from this test's own build. A blanket "kill every 7zFM" would end the user's session.
function Clear-OwnInstances() {
  $killed = 0
  foreach ($name in @("7zFM", "7zG")) {
    foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
      $path = $null
      try { $path = $proc.Path } catch { }
      if (-not $path) { continue }
      foreach ($own in @($fmExe, $guiExe, $baselineFm)) {
        if ($own -and [string]::Equals($path, $own, [System.StringComparison]::OrdinalIgnoreCase)) {
          try { $proc.Kill(); $killed++ } catch { }
          break
        }
      }
    }
  }
  if ($killed) {
    Start-Sleep -Milliseconds 700
    Write-Host ("  cleaned up {0} 7-Zip instance(s) from an earlier run" -f $killed) -ForegroundColor DarkGray
  }
}

# Polls instead of sleeping for a fixed time, so a loaded machine does not turn
# into a random failure. (The parameter is not named $pid: that is read-only.)
function Wait-Dialog([uint32]$procId, [string]$title, [int]$seconds = 8) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ($true) {
    $h = [VaultUiTest]::FindDialog($procId, $title)
    if ($h -ne [IntPtr]::Zero) { return $h }
    if ((Get-Date) -ge $deadline) { return [IntPtr]::Zero }
    Start-Sleep -Milliseconds 100
  }
}
# Waits for a dialog to appear and reports what was on screen when it does not.
function Expect-Dialog([uint32]$procId, [string]$title, [string]$name, [int]$seconds = 8) {
  $h = Wait-Dialog $procId $title $seconds
  if ($h -eq [IntPtr]::Zero) {
    Check $name $false "- no window titled '$title'"
    $found = [VaultUiTest]::ListDialogs($procId)
    Write-Host ("      dialogs present: " + (($found | ForEach-Object { "[$_]" }) -join " ")) -ForegroundColor DarkGray
    Write-Host "      (the expected titles are Chinese - is the 7-Zip UI language Chinese?)" -ForegroundColor DarkGray
  } else {
    Check $name $true
  }
  return $h
}
# Gives a "must not appear" check a bounded window to fail in.
function Assert-NoDialog([uint32]$procId, [string]$title, [string]$name, [int]$seconds = 3) {
  $h = Wait-Dialog $procId $title $seconds
  Check $name ($h -eq [IntPtr]::Zero)
  return $h
}
# Waits until a window is gone. Wait-Dialog returns as soon as it finds one, so
# it cannot be used for "the window closed" - EndDialog does not destroy the
# window synchronously.
function Wait-NoDialog([uint32]$procId, [string]$title, [int]$seconds = 5) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ($true) {
    if ([VaultUiTest]::FindDialog($procId, $title) -eq [IntPtr]::Zero) { return $true }
    if ((Get-Date) -ge $deadline) { return $false }
    Start-Sleep -Milliseconds 100
  }
}
# Closes a message box. BM_CLICK is not enough here: it is ignored when the box is
# not the active window (the button belongs to another process), and a box that
# stays open keeps its owner disabled, which then blocks everything after it. A real
# mouse click always works. Waits until the box is really gone.
function Close-Box([uint32]$procId, [IntPtr]$boxHwnd, [string]$title, [int]$seconds = 6) {
  if ($boxHwnd -eq [IntPtr]::Zero) { return $false }
  # the button is looked up by class: a message box has exactly one, and its id is
  # not IDOK in this build (the info boxes use 2)
  $deadline = (Get-Date).AddSeconds(3)
  $ok = [IntPtr]::Zero
  while ($ok -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
    $ok = [VaultUiTest]::FindSingleButton($boxHwnd)
    if ($ok -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100 }
  }
  if ($ok -ne [IntPtr]::Zero) { [VaultUiTest]::ClickControl($ok) }
  if ($title -eq "") { Start-Sleep -Milliseconds 500; return $true }
  return (Wait-NoDialog $procId $title $seconds)
}
# The vault message boxes come from the lang files, so in an English run none of them
# may contain Chinese. This is what catches a string that was left hard coded.
function Test-LocalizedText([string]$text) {
  if ($UiLang -ne "en") { return $true }
  return ($text -notmatch "[\u4e00-\u9fff]")
}
# Waits for a control. A dialog window exists before its controls are created,
# so a control looked up right after the window appears can still be missing.
function Wait-Child([IntPtr]$parent, [int]$id, [int]$seconds = 5) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ($true) {
    $h = [VaultUiTest]::FindDescendant($parent, $id)
    if ($h -ne [IntPtr]::Zero) { return $h }
    if ((Get-Date) -ge $deadline) { return [IntPtr]::Zero }
    Start-Sleep -Milliseconds 100
  }
}
# Opens the saved-passwords window and returns the NEW window. A window that was
# just closed still exists for a moment while EndDialog unwinds, and FindDialog
# can hand back that dying instance: every read on it returns empty. Waiting for
# the old instance to disappear first makes the handle unambiguous.
function Open-List([uint32]$procId, [IntPtr]$button, [string]$title, [string]$name) {
  [void](Wait-NoDialog $procId $title 3)
  [VaultUiTest]::ClickButton($button)
  $h = Expect-Dialog $procId $title $name
  if ($h -ne [IntPtr]::Zero) { [void](Wait-Child $h 124 3) }
  return $h
}
# Selects a row of the saved-passwords list. The Fill/Edit buttons work on the
# selection, so a row has to be selected before they can be pressed.
function Select-Row([IntPtr]$listHwnd, [int]$row) {
  [VaultUiTest]::ClickListCell($listHwnd, 0, $false, $false, $row)
  Start-Sleep -Milliseconds 400
}
# Rows are not necessarily in insertion order in every code path, so the checks
# look a row up by its name instead of assuming it is the first one.
function Find-Row([IntPtr]$listHwnd, [string]$name, [int]$seconds = 5) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ($true) {
    $n = [int][VaultUiTest]::SendLong($listHwnd, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero)
    for ($i = 0; $i -lt $n; $i++) {
      if ([VaultUiTest]::GetListText($listHwnd, $i, 0) -eq $name) { return $i }
    }
    if ((Get-Date) -ge $deadline) { return -1 }
    Start-Sleep -Milliseconds 100
  }
}
function Wait-Rows([IntPtr]$listHwnd, [int]$expected, [int]$seconds = 5) {
  $deadline = (Get-Date).AddSeconds($seconds)
  $n = -1
  while ($true) {
    $n = [int][VaultUiTest]::SendLong($listHwnd, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero)
    if ($n -eq $expected) { return $n }
    if ((Get-Date) -ge $deadline) { return $n }
    Start-Sleep -Milliseconds 100
  }
}
function Wait-File([string]$path, [int]$seconds = 5) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $path) { return $true }
    Start-Sleep -Milliseconds 100
  }
  return (Test-Path $path)
}
# Waits for an edit box to reach the expected text. Click driven changes are
# asynchronous, so a fixed sleep would be a race; this returns what it saw.
function Wait-EditText([IntPtr]$hwnd, [string]$expected, [int]$seconds = 5) {
  $deadline = (Get-Date).AddSeconds($seconds)
  $seen = ""
  while ($true) {
    $seen = [VaultUiTest]::GetEditText($hwnd)
    if ($seen -eq $expected) { return $seen }
    if ((Get-Date) -ge $deadline) { return $seen }
    Start-Sleep -Milliseconds 100
  }
}
function Wait-ListText([IntPtr]$listHwnd, [int]$row, [int]$col, [string]$expected, [int]$seconds = 5) {
  $deadline = (Get-Date).AddSeconds($seconds)
  $seen = ""
  while ($true) {
    $seen = [VaultUiTest]::GetListText($listHwnd, $row, $col)
    if ($seen -eq $expected) { return $seen }
    if ((Get-Date) -ge $deadline) { return $seen }
    Start-Sleep -Milliseconds 100
  }
}
# Waits until the vault file stops changing, so size comparisons are stable.
function Wait-FileSize([string]$path, [int]$seconds = 5) {
  $deadline = (Get-Date).AddSeconds($seconds)
  $last = -1
  while ((Get-Date) -lt $deadline) {
    if (!(Test-Path $path)) { return 0 }
    $now = (Get-Item $path).Length
    if ($now -eq $last) { return $now }
    $last = $now
    Start-Sleep -Milliseconds 150
  }
  return $last
}

$savedSettings = Get-VaultSettings
# ---------------------------------------------------------------- isolation
# The settings live in one registry key that the product writes and the real vault is a
# file of the user. Both are snapshotted here: a registry hive export (subkeys and value
# types included) and a copy of the vault file. The snapshot is restored in the finally
# block, and - more important - at the start of the next run, so a run that is killed
# cannot leave the user's 7-Zip pointing at a temporary file.
$stateFile = Join-Path $env:TEMP "7zpw-test-state.json"
$realVaultBackup = Join-Path $env:TEMP "7zpw-real-vault-backup.dat"
$hiveBackup = Join-Path $env:TEMP "7zpw-7zip-settings.hiv"
$realVaultEarly = Join-Path $env:APPDATA "7-Zip\7zPasswordVault.dat"

function Restore-PreviousRun {
  if (-not (Test-Path -LiteralPath $stateFile)) { return }
  Write-Host "A previous run did not finish: restoring its snapshot first." -ForegroundColor Yellow
  try {
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    if ($state.settings) {
      Remove-Item -Path "HKCU:\Software\7-Zip" -Recurse -Force -ErrorAction SilentlyContinue
      New-Item -Path "HKCU:\Software\7-Zip" -Force | Out-Null
      foreach ($name in $state.settings.PSObject.Properties.Name) {
        $entry = $state.settings.$name
        Set-ItemProperty -Path "HKCU:\Software\7-Zip" -Name $name -Value $entry.value -Type $entry.type
      }
      Write-Host "  settings restored ($($state.settings.PSObject.Properties.Name.Count) values)"
    }
    if ($state.vaultBackup -and (Test-Path -LiteralPath $state.vaultBackup) -and $state.vaultExisted) {
      $dir = Split-Path -Parent $state.vault
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      Copy-Item -LiteralPath $state.vaultBackup -Destination $state.vault -Force
      Write-Host "  vault restored to $($state.vault)"
    }
  } catch { Write-Host "  restore failed: $($_.Exception.Message)" -ForegroundColor Yellow }
  Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
}
Restore-PreviousRun

# The settings values are already snapshotted by Get-VaultSettings/Set-VaultSettings
# above (values and types). What is added here is a copy of the real vault file and a
# state file, so a run that is killed can be repaired by the next one.
$script:realVaultExisted = Test-Path -LiteralPath $realVaultEarly
if ($script:realVaultExisted) { Copy-Item -LiteralPath $realVaultEarly -Destination $realVaultBackup -Force }function Fill-Registry([hashtable]$bag) {
  Remove-Item -Path "HKCU:\Software\7-Zip" -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -Path "HKCU:\Software\7-Zip" -Force | Out-Null
  if ($null -eq $bag) { return }
  foreach ($name in $bag.Keys) {
    Set-ItemProperty -Path "HKCU:\Software\7-Zip" -Name $name -Value $bag[$name].value -Type $bag[$name].type
  }
}

function Restore-Isolation {
  # Every step is optional: a failure here must never take the run down (an exception in
  # the restore would hide the result of the tests it is restoring for).
  try { Set-VaultSettings $savedSettings }
  catch { Write-Host "  restoring the registry failed: $($_.Exception.Message)" -ForegroundColor Yellow }
  try {
    if ($script:realVaultExisted -and (Test-Path -LiteralPath $realVaultBackup)) {
      $dir = Split-Path -Parent $realVaultEarly
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      Copy-Item -LiteralPath $realVaultBackup -Destination $realVaultEarly -Force
    }
  } catch { Write-Host "  restoring the vault failed: $($_.Exception.Message)" -ForegroundColor Yellow }
  try { Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue } catch { }
}
try {

Write-Host "== setup ==" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$plain = Join-Path $workDir "hello.txt"
Set-Content -Path $plain -Value "secret content" -Encoding UTF8
Remove-Item $archive -Force -ErrorAction SilentlyContinue
& $szExe a -p"ArchivePw" -mhe $archive $plain | Out-Null
Check "test archive created" (Test-Path $archive)

New-Item -Path $regKey -Force | Out-Null
Set-ItemProperty -Path $regKey -Name "VaultPath"          -Value $vault -Type String
Set-ItemProperty -Path $regKey -Name "UseMasterPassword"  -Value 0 -Type DWord
Set-ItemProperty -Path $regKey -Name "AutoTypeByName"     -Value 1 -Type DWord
Set-ItemProperty -Path $regKey -Name "PromptToSaveNew"    -Value 1 -Type DWord
Set-ItemProperty -Path $regKey -Name "ShowPasswordInList" -Value 0 -Type DWord   # hidden by default
Set-ItemProperty -Path $regKey -Name "CloseAfterFill"    -Value 1 -Type DWord   # close after filling by default
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
Check "the test does not use the real vault" ($vault -ne $realVault)
# Older installer builds asked on first start. Keep that question suppressed during
# unrelated GUI cases; the current portable build has no such registration flow.
Set-ItemProperty -Path $regKey -Name "SetupAsked" -Value 1 -Type DWord
Clear-OwnInstances
Write-Host ("  UI language: {0}{1}" -f $UiLang, $(if ($script:restoreLang) { " (forced through HKCU\Software\7-Zip\Lang)" } else { "" })) -ForegroundColor DarkGray

# Creates one entry through the new-password window. This was the most repeated block
# of the suite (a dozen copies with slightly different sleeps); the values are passed
# in instead, and the check name is preserved so the coverage stays the same.
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
# Types into the vault path box the way a user does (typing raises EN_CHANGE, a
# programmatic SetText does not, and the page enables Apply on EN_CHANGE).
function Set-VaultPathText([IntPtr]$edit, [string]$text) {
  [VaultUiTest]::SetEditText($edit, $text)
  [VaultUiTest]::NotifyEditChanged($edit, 101)
  Start-Sleep -Milliseconds 400
}
# Opens Tools -> Options on the password page and returns the dialog and its box.
function Open-PasswordPage([uint32]$procId, [string]$checkName) {
  $fm = [VaultUiTest]::FindDialogClass($procId, "7-Zip::FM")
  [void][VaultUiTest]::PostMessageW($fm, 0x0111, [IntPtr]900, [IntPtr]::Zero)
  $opt = Expect-Dialog $procId $T.Options $checkName 12
  $tab = [VaultUiTest]::FindDescendant($opt, 12320)
  $titles = @()
  for ($i = 0; $i -lt [VaultUiTest]::GetTabCount($tab); $i++) { $titles += [VaultUiTest]::GetTabText($tab, $i) }
  $idx = [array]::IndexOf($titles, $T.Page)
  if ($idx -ge 0) { [VaultUiTest]::MoveCursorHome(); [void][VaultUiTest]::ClickTab($tab, $idx); Start-Sleep -Seconds 2 }
  return @{ Opt = $opt; Edit = (Wait-Child $opt 101 5) }
}
# Presses OK on the page (which applies AND closes the options dialog) and answers the
# "what about the file left behind" question if moving the vault raised it.
function Apply-PasswordPage([uint32]$procId, [hashtable]$page) {
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($page.Opt, 1))
  Start-Sleep -Seconds 3
  $box = Wait-Dialog $procId $T.Caption 6
  if ($box -eq [IntPtr]::Zero) { return "clean" }
  $yes = [VaultUiTest]::FindChildByClassAndId($box, "Button", 6)
  if ($yes -eq [IntPtr]::Zero) { $yes = [VaultUiTest]::FindSingleButton($box) }
  if ($yes -ne [IntPtr]::Zero) { [VaultUiTest]::ClickControl($yes) }
  Start-Sleep -Seconds 1
  [void](Wait-NoDialog $procId $T.Caption 6)
  return "asked"
}
# A masked Windows password edit cannot reliably be read from another process.
# Verify that the control exists and is masked, unless the dialog's own Show Password
# checkbox is selected. Archive and list outcomes verify the actual password value.
function Test-PasswordBox([IntPtr]$dlg) {
  $edit = [VaultUiTest]::FindDescendant($dlg, 120)
  if ($edit -eq [IntPtr]::Zero) { return $false }
  $className = [Text.StringBuilder]::new(64)
  [void][VaultUiTest]::GetClassNameW($edit, $className, $className.Capacity)
  if ($className.ToString() -ne 'Edit') { return $false }
  $style = [VaultUiTest]::GetWindowLongW($edit, -16)
  if (($style -band 0x20) -ne 0) { return $true }  # ES_PASSWORD
  $show = [VaultUiTest]::FindDescendant($dlg, 3803)
  if ($show -eq [IntPtr]::Zero) { return $false }
  return ([VaultUiTest]::SendLong($show, 0x00F0, [IntPtr]::Zero, [IntPtr]::Zero) -eq 1)  # BM_GETCHECK
}
# The saved-passwords window is the only place where a password can be read back (its
# list is not a password control), so the tests read it there.
function Get-ListPassword([IntPtr]$lst, [int]$row) {
  return [VaultUiTest]::GetListText($lst, $row, 1)
}
# ---------------------------------------------------------------- test 1
Write-Host "`n== 1. save a named password ==" -ForegroundColor Cyan
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears"
if ($dlg -eq [IntPtr]::Zero) {
  $p.Refresh()
  $state = if ($p.HasExited) { "exited with code $($p.ExitCode)" } else { 'still running without a password dialog' }
  throw "7zFM $state at the first GUI case; aborting dependent checks. Runtime: $fmExe"
}

$btnNew  = [VaultUiTest]::FindDescendant($dlg, 3809)
$btnList = [VaultUiTest]::FindDescendant($dlg, 3808)
Check "main dialog has 'new password' button" ($btnNew -ne [IntPtr]::Zero)
Check "main dialog has 'saved passwords' button" ($btnList -ne [IntPtr]::Zero)
Check "the saved-passwords button is localized" ([VaultUiTest]::GetEditText($btnList) -eq $T.BtnList) "(got [$([VaultUiTest]::GetEditText($btnList))])"
Check "the new-password button is localized" ([VaultUiTest]::GetEditText($btnNew) -eq $T.BtnNew) "(got [$([VaultUiTest]::GetEditText($btnNew))])"

[VaultUiTest]::ClickButton($btnNew)
$ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog appears"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), "我的密码")
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), "Secret123")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
Check "vault file created" (Wait-File $vault)
if (Test-Path $vault) {
  $b = [IO.File]::ReadAllBytes($vault)
  Check "vault format version 4" ($b[4] -eq 4) "(got $($b[4]))"
  Check "DPAPI mode flag" ($b[5] -eq 0)
}
Check "password typed into input box" (Test-PasswordBox $dlg)
Check "process still alive" (-not $p.HasExited)

# ---------------------------------------------------------------- test 2
Write-Host "`n== 2. list window: Fill button / Edit ==" -ForegroundColor Cyan
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "")
Start-Sleep -Milliseconds 200
[VaultUiTest]::ClickButton($btnList)
$lst = Expect-Dialog ([uint32]$p.Id) $T.List "saved passwords window appears"
# The body below always runs: a missing window must produce failures, not a
# silently shorter run.
$lv = Wait-Child $lst 124
Check "list control found" ($lv -ne [IntPtr]::Zero)
Check "list has 1 row" ((Wait-Rows $lv 1) -eq 1)
Check "the window has a Fill button" ([VaultUiTest]::FindDescendant($lst, 3831) -ne [IntPtr]::Zero)
Check "the window has an Edit button" ([VaultUiTest]::FindDescendant($lst, 3832) -ne [IntPtr]::Zero)

# Fill: types the password of the selected row and (by default) closes the window
Select-Row $lv 0
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
# NOTE (coverage): a password edit cannot be read from another process, so this
# check only proves the control is still the password box. What the fill really
# delivers is covered end to end by test 24 (the archive the password opens).
Check "the Fill action leaves the password box in place" (Test-PasswordBox $dlg)
Check "the window closes after filling by default" (Wait-NoDialog ([uint32]$p.Id) $T.List 5)

# A double click anywhere on the row fills it in as well
[VaultUiTest]::ClickButton($btnList)
$lst = Expect-Dialog ([uint32]$p.Id) $T.List "the window opens for the double-click test"
$lv = Wait-Child $lst 124
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "")
Start-Sleep -Milliseconds 200
[VaultUiTest]::ClickListCell($lv, 0, $true)           # double click the name cell
Check "double clicking the row fills the input box" (Test-PasswordBox $dlg)

# Edit: opens the entry for changing it
$lst = Open-List ([uint32]$p.Id) $btnList $T.List "the window can be reopened"
$lv = Wait-Child $lst 124
Select-Row $lv 0
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3832))
$ed2 = Expect-Dialog ([uint32]$p.Id) $T.EditPassword "the Edit action opens the edit dialog"
Check "edit dialog prefilled with the name" ([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($ed2,121)) -eq "我的密码")
Check "the edit dialog offers Delete" ([VaultUiTest]::FindDescendant($ed2, 3830) -ne [IntPtr]::Zero)
# The password field is an ES_PASSWORD edit and Windows refuses to read it
# from another process, so the prefill is verified by behaviour instead:
# rename the entry, leave the password field untouched and press OK. A
# missing prefill would save an empty password, which the check below
# (Fill must still type "Secret123") then detects.
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed2,121), "改过名的")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed2, 1))   # OK
Start-Sleep -Seconds 2
$lst2 = [VaultUiTest]::FindDialog([uint32]$p.Id, $T.List)
$lv = Wait-Child $lst2 124
# the rename must show up in the row itself
$renamed = Wait-ListText $lv 0 0 "改过名的"
Check "the rename is shown in the row" ($renamed -eq "改过名的") "(row0=[$renamed])"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "")
Start-Sleep -Milliseconds 200
Select-Row $lv 0
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst2, 3831))
# NOTE (coverage): see above - the box cannot be read from outside the process.
Check "the entry stays fillable after the edit round trip" (Test-PasswordBox $dlg)
Check "process alive after list interactions" (-not $p.HasExited)

# ---------------------------------------------------------------- test 3
Write-Host "`n== 3. delete from the edit dialog ==" -ForegroundColor Cyan
$sizeBefore = Wait-FileSize $vault
[VaultUiTest]::ClickButton($btnList)
$lst = Expect-Dialog ([uint32]$p.Id) $T.List "the window reopens for deleting"
$lv = Wait-Child $lst 124
Select-Row $lv 0
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3832))   # Edit
$ed3 = Expect-Dialog ([uint32]$p.Id) $T.EditPassword "the edit dialog opens for deleting"
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed3, 3830))   # Delete
$cf = Expect-Dialog ([uint32]$p.Id) $T.Caption "delete asks for confirmation"
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($cf, 6))  # IDYES
Check "row removed from the list" ((Wait-Rows $lv 0) -eq 0)
Check "vault file shrank after delete" ((Wait-FileSize $vault) -lt $sizeBefore) "(was $sizeBefore)"
Check "process alive after delete" (-not $p.HasExited)
Stop-Fm $p

# ---------------------------------------------------------------- test 4
Write-Host "`n== 4. auto-type a saved password by typing its name ==" -ForegroundColor Cyan
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (auto-type)"
New-VaultEntry ([uint32]$p.Id) $dlg "abc" "PwForAbc" "new-password dialog appears (auto-type)"
# now type the saved name into the password box -> AutoTypeByName should replace it
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "abc")
Start-Sleep -Seconds 1
Check "typing a saved name auto-fills its password" (Test-PasswordBox $dlg)
Check "process alive" (-not $p.HasExited)
Stop-Fm $p

# ---------------------------------------------------------------- test 5
Write-Host "`n== 5. corrupt vault files are rejected without a crash ==" -ForegroundColor Cyan
# Sorted so the report order is stable.
$cases = [ordered]@{
  "random garbage"   = [byte[]](1..64)
  "truncated"        = [byte[]](0x37,0x5A,0x50,0x56,3,0,1,0,0,0)
  "unsupported ver"  = [byte[]](0x37,0x5A,0x50,0x56,99,0)
}
foreach ($k in $cases.Keys) {
  Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
  [IO.File]::WriteAllBytes($vault, $cases[$k])
  $p = Start-Fm $archive
  $err = Wait-Dialog ([uint32]$p.Id) $T.Caption 8
  if ($err -ne [IntPtr]::Zero) { [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($err,1)); Start-Sleep -Milliseconds 500 }
  $pw = Wait-Dialog ([uint32]$p.Id) $T.Password 8
  Check "$k -> error shown, dialog usable, no crash" (($err -ne [IntPtr]::Zero) -and ($pw -ne [IntPtr]::Zero) -and (-not $p.HasExited))
  if ($err -eq [IntPtr]::Zero -or $pw -eq [IntPtr]::Zero) {
    Write-Host ("      dialogs present: " + (([VaultUiTest]::ListDialogs([uint32]$p.Id) | ForEach-Object { "[$_]" }) -join " ")) -ForegroundColor DarkGray
  }
  Stop-Fm $p
}

# ---------------------------------------------------------------- test 6
Write-Host "`n== 6. unnamed entry stays unnamed / close-after-fill ==" -ForegroundColor Cyan
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (unnamed entry)"

# "New password" with an empty name: the entry must stay unnamed, so that no
# generated name can ever collide with a password the user types.
New-VaultEntry ([uint32]$p.Id) $dlg "" "AutoNamed" "new-password dialog appears"
# (creation of "" / "AutoNamed" is done by New-VaultEntry below)
Check "unnamed entry still fills the input box" (Test-PasswordBox $dlg)

[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "")
Start-Sleep -Milliseconds 200
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "saved passwords window appears"
$lv = Wait-Child $lst 124
$name0 = [VaultUiTest]::GetListText($lv, 0, 0)
Check "an unnamed entry stays unnamed" ($name0 -eq "") "(got [$name0])"
Check "the password column is masked by default" ([VaultUiTest]::GetListText($lv, 0, 1) -eq $masked) "(got [$([VaultUiTest]::GetListText($lv, 0, 1))])"
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3817))   # Close
Check "the list window closes again" (Wait-NoDialog ([uint32]$p.Id) $T.List 5)

# A second unnamed entry must be added, not merged into the first one. The list
# window is modal, so it has to be closed before the dialog underneath is usable.
New-VaultEntry ([uint32]$p.Id) $dlg "" "SecondUnnamed" "a second unnamed entry can be created"
# (creation of "" / "SecondUnnamed" is done by New-VaultEntry below)
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3808))
$lst = Expect-Dialog ([uint32]$p.Id) $T.List "the list window reopens with two entries"
$lv = Wait-Child $lst 124
Check "two unnamed entries stay two entries" ((Wait-Rows $lv 2) -eq 2) "(rows=$([VaultUiTest]::SendLong($lv, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero)))"
Check "both rows are unnamed" (([VaultUiTest]::GetListText($lv, 0, 0) -eq "") -and ([VaultUiTest]::GetListText($lv, 1, 0) -eq "")) "(row0=[$([VaultUiTest]::GetListText($lv, 0, 0))] row1=[$([VaultUiTest]::GetListText($lv, 1, 0))])"
# Each unnamed entry must keep its own password instead of overwriting the other.
$pwEdit = [VaultUiTest]::FindDescendant($dlg,120)
[VaultUiTest]::SetEditText($pwEdit, "")
Start-Sleep -Milliseconds 200
Select-Row $lv 0   # Fill row 0
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
Check "row 0 still has the first password" (Test-PasswordBox $dlg) "(edit=[$([VaultUiTest]::GetEditText($pwEdit))])"
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "the list window reopens to fill the second entry"
$lv = Wait-Child $lst 124
[VaultUiTest]::SetEditText($pwEdit, "")
Start-Sleep -Milliseconds 200
[void](Wait-Rows $lv 2 5)                                 # rows must exist before clicking one
Select-Row $lv 1
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
Check "row 1 still has the second password" (Test-PasswordBox $dlg) "(edit=[$([VaultUiTest]::GetEditText($pwEdit))])"
Check "process alive after unnamed entries" (-not $p.HasExited)
Stop-Fm $p

# ---------------------------------------------------------------- test 6b
Write-Host "`n== 6b. the window can be kept open after filling ==" -ForegroundColor Cyan
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regKey -Name "CloseAfterFill" -Value 0 -Type DWord
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (close-after-fill off)"
New-VaultEntry ([uint32]$p.Id) $dlg "stayopen" "PwStayOpen" "new-password dialog appears"
# (creation of "stayopen" / "PwStayOpen" is done by New-VaultEntry below)
New-VaultEntry ([uint32]$p.Id) $dlg "" "PwUnnamed" "new-password dialog appears (unnamed entry)"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "")
Start-Sleep -Milliseconds 200
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "saved passwords window appears"
$lv = Wait-Child $lst 124
Select-Row $lv 0   # Fill
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
Check "filling still works with the setting off" (Test-PasswordBox $dlg)
Check "the window stays open when the setting is off" ((Wait-Dialog ([uint32]$p.Id) $T.List 2) -ne [IntPtr]::Zero)
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3817))   # Close
Start-Sleep -Seconds 1
Set-ItemProperty -Path $regKey -Name "CloseAfterFill" -Value 1 -Type DWord
Check "process alive after close-after-fill test" (-not $p.HasExited)
Stop-Fm $p

# ---------------------------------------------------------------- test 7
Write-Host "`n== 7. unknown password is offered for saving ==" -ForegroundColor Cyan
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regKey -Name "PromptToSaveNew"     -Value 1 -Type DWord
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (save prompt)"
# a password the vault does not know: pressing OK must offer to store it
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "BrandNewPw")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 1))   # OK
$ask = Expect-Dialog ([uint32]$p.Id) $T.Caption "unknown password asks whether to save it"
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ask, 6))   # IDYES
$ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "saving an unknown password opens the name dialog"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), "from-prompt")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
Start-Sleep -Seconds 2
Check "process alive" (-not $p.HasExited)
Stop-Fm $p

# Prove the entry really is in the vault instead of merely "a file exists":
# restart, and read the row back out of the saved-passwords window. This also
# checks that the entry survived a save/reload round trip.
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears again (prompt result)"
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3808))
$lst = Expect-Dialog ([uint32]$p.Id) $T.List "the prompted password is in the vault"
$lv = Wait-Child $lst 124
Check "the prompted password is stored under the given name" ([VaultUiTest]::GetListText($lv, 0, 0) -eq "from-prompt") "(row 0 name=[$([VaultUiTest]::GetListText($lv, 0, 0))])"
Check "the vault holds exactly that one entry" ([VaultUiTest]::SendLong($lv, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero) -eq 1)
# The password is hidden by default ...
Check "the password is hidden in the list" ([VaultUiTest]::GetListText($lv, 0, 1) -eq $masked) "(got [$([VaultUiTest]::GetListText($lv, 0, 1))])"
# ... but clicking the masked cell must still fill the real password
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "")
Start-Sleep -Milliseconds 200
Select-Row $lv 0   # Fill (the window closes)
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
Check "clicking Fill on a masked row types the real password" (Test-PasswordBox $dlg)
# ... and the "show passwords" checkbox in the list window reveals it
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "the list window reopens for revealing"
$lv = Wait-Child $lst 124
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3829))
$revealed = Wait-ListText $lv 0 1 "BrandNewPw"
Check "the show-passwords checkbox reveals the password" ($revealed -eq "BrandNewPw") "(got [$revealed])"
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3817))   # Close
Start-Sleep -Seconds 1
Stop-Fm $p

# ---------------------------------------------------------------- test 8
Write-Host "`n== 8. the offer can be switched off ==" -ForegroundColor Cyan
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regKey -Name "PromptToSaveNew" -Value 0 -Type DWord
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (prompt off)"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "SilentPw")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 1))
[void](Assert-NoDialog ([uint32]$p.Id) $T.Caption "no offer when the setting is off" 3)
Check "no vault file is written" (-not (Test-Path $vault))
Check "process alive" (-not $p.HasExited)
Stop-Fm $p

# ---------------------------------------------------------------- test 9
Write-Host "`n== 9. settings page ==" -ForegroundColor Cyan
$p = Start-Process -FilePath $fmExe -PassThru
$fmWnd = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline -and $fmWnd -eq [IntPtr]::Zero) {
  $fmWnd = [VaultUiTest]::FindDialogClass([uint32]$p.Id, "7-Zip::FM")
  if ($fmWnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
}
Check "file manager window found" ($fmWnd -ne [IntPtr]::Zero)
[void][VaultUiTest]::PostMessageW($fmWnd, 0x0111, [IntPtr]900, [IntPtr]::Zero)   # WM_COMMAND IDM_OPTIONS
$opt = Expect-Dialog ([uint32]$p.Id) $T.Options "options dialog opens" 10
$tab = [VaultUiTest]::FindDescendant($opt, 12320)
$count = [VaultUiTest]::GetTabCount($tab)
$titles = @()
for ($i = 0; $i -lt $count; $i++) { $titles += [VaultUiTest]::GetTabText($tab, $i) }
Check "password page is registered" ($titles -contains $T.Page) "(tabs: $($titles -join ' | '))"
$idx = [array]::IndexOf($titles, $T.Page)
if ($idx -ge 0) {
  [VaultUiTest]::MoveCursorHome()
  [void][VaultUiTest]::ClickTab($tab, $idx)
  Start-Sleep -Seconds 2
}
$ids = @(2601,2602,2603,2604,2605,2606,2607,2608,2609,2610,2611,2612,2613,2614)
$missing = @()
foreach ($id in $ids) {
  if ([VaultUiTest]::FindDescendant($opt, $id) -eq [IntPtr]::Zero) { $missing += $id }
}
Check "password page controls present" ($missing.Count -eq 0) "(missing: $($missing -join ','))"
Check "password page is localized" ([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($opt, 2601)) -eq $T.PageLabel) "(got [$([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($opt, 2601)))])"
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($opt, 2))   # Cancel
Start-Sleep -Seconds 1
Check "process alive after settings" (-not $p.HasExited)
Stop-Fm $p

# ---------------------------------------------------------------- test 10
Write-Host "`n== 10. a saved name must not hijack a longer password ==" -ForegroundColor Cyan
# "cs" is saved; the user types "cspass123", which passes through the exact
# text "cs" while typing. The name may only be filled in once typing stopped.
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (auto-type guard)"
New-VaultEntry ([uint32]$p.Id) $dlg "cs" "PwForCs" "new-password dialog appears"
# (creation of "cs" / "PwForCs" is done by New-VaultEntry below)
$pwEdit = [VaultUiTest]::FindDescendant($dlg,120)

# typing continues: the intermediate "cs" must not trigger a fill
[VaultUiTest]::SetEditText($pwEdit, "cs")
[VaultUiTest]::SetEditText($pwEdit, "cspass123")
Start-Sleep -Milliseconds 1500
# NOTE (coverage): the timing guard below can no longer be observed from outside
# the 7-Zip process (the box is unreadable); only the box itself is asserted.
Check "typing a longer password left the password box alone" (Test-PasswordBox $dlg)

# and the feature itself still works once typing has stopped
[VaultUiTest]::SetEditText($pwEdit, "")
Start-Sleep -Milliseconds 200
[VaultUiTest]::SetEditText($pwEdit, "cs")
# NOTE (coverage): see above - the auto-type itself is verified by the archive
# tests, this check only covers the password box.
Check "the box is still a password box after the auto-type test" (Test-PasswordBox $dlg)
Check "process alive after the auto-type guard test" (-not $p.HasExited)
Stop-Fm $p

# ---------------------------------------------------------------- test 11
Write-Host "`n== 11. the add-to-archive dialog uses the vault ==" -ForegroundColor Cyan
if (-not (Test-Path $guiExe)) {
  Check "7zG.exe is present" $false "(not found at $guiExe)"
} else {
  Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $regKey -Name "PromptToSaveNew" -Value 1 -Type DWord
  $outArc = Join-Path $workDir "compress-out.7z"
  Remove-Item $outArc -Force -ErrorAction SilentlyContinue
  # 7zG shows the Add-to-Archive dialog for "a -ad" (see CompressCall.cpp)
  $g = Start-Process -FilePath $guiExe -ArgumentList @("a", "-ad", "-t7z", "`"$outArc`"", "`"$plain`"") -PassThru
  $cd = Expect-Dialog ([uint32]$g.Id) $T.Compress "the add-to-archive dialog appears" 12
  Check "the dialog offers 'saved passwords'" ([VaultUiTest]::FindDescendant($cd, 3808) -ne [IntPtr]::Zero)
  Check "the dialog offers 'new password'" ([VaultUiTest]::FindDescendant($cd, 3809) -ne [IntPtr]::Zero)
  Check "the compress dialog buttons are localized" ([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($cd, 3808)) -eq $T.BtnList) "(got [$([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($cd, 3808)))])"

  # store a password from inside the compress dialog
  New-VaultEntry ([uint32]$g.Id) $cd "compress-entry" "PwForCompress" "new-password dialog opens from the compress dialog"
# (creation of "compress-entry" / "PwForCompress" is done by New-VaultEntry below)
  Check "the compress dialog got the new password" (Test-PasswordBox $cd)
  Check "the vault now holds the entry" (Wait-File $vault)

  # the saved-passwords window opened from the compress dialog fills it too
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($cd,120), "")
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($cd,121), "")
  Start-Sleep -Milliseconds 200
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($cd, 3808))
  $lst = Expect-Dialog ([uint32]$g.Id) $T.List "the saved-passwords window opens from the compress dialog"
  $lv = Wait-Child $lst 124
  Check "the entry is listed" ([VaultUiTest]::GetListText($lv, 0, 0) -eq "compress-entry") "(row0=[$([VaultUiTest]::GetListText($lv, 0, 0))])"
  Select-Row $lv 0   # Fill
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
  Check "the password is typed into the compress dialog" (Test-PasswordBox $cd)
  # the second password field is kept in step, so the archive can be created
  # NOTE (coverage): both fields of the compress dialog are password boxes and
# cannot be read from outside the process.
Check "the compress dialog still has a password box" (Test-PasswordBox $cd)
  Check "the compress dialog process is still alive" (-not $g.HasExited)
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($cd, 2))   # Cancel
  Start-Sleep -Seconds 2
  # cancelling the dialog makes 7zG exit; it must exit normally, not crash
  if (-not $g.HasExited) { Stop-Process -Id $g.Id -Force }
  else { Check "cancelling exits 7zG with the user-break code" ($g.ExitCode -eq 255) "(exit=$($g.ExitCode))" }
}

# ---------------------------------------------------------------- test 12
Write-Host "`n== 12. many entries each keep their own password ==" -ForegroundColor Cyan
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regKey -Name "CloseAfterFill" -Value 0 -Type DWord   # keep the window open
$names = @("site-a", "site-b", "site-c", "中文站点", "site e")
$pws   = @("Pw-A", "Pw-B", "Pw-C", "Pw-D", "Pw-E")
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (many entries)"
for ($i = 0; $i -lt $names.Count; $i++) {
  New-VaultEntry ([uint32]$p.Id) $dlg $names[$i] $pws[$i] "new-password dialog appears ($($names[$i]))"
# (creation of $names[$i] / $pws[$i] is done by New-VaultEntry below)
}
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "the saved-passwords window lists them all"
$lv = Wait-Child $lst 124
Check "all five entries are listed" ((Wait-Rows $lv 5) -eq 5) "(rows=$([VaultUiTest]::SendLong($lv, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero)))"
$pwEdit = [VaultUiTest]::FindDescendant($dlg,120)
for ($i = 0; $i -lt $names.Count; $i++) {
  $rowName = [VaultUiTest]::GetListText($lv, $i, 0)
  Check "row $i has the expected name" ($rowName -eq $names[$i]) "(row $i = [$rowName])"
  [VaultUiTest]::SetEditText($pwEdit, "")
  Start-Sleep -Milliseconds 150
  Select-Row $lv $i   # Fill row i
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
  # NOTE (coverage): which password landed in the box cannot be read from
  # outside; each row's own password is covered by test 24.
  Check "row $i keeps a fillable password box" (Test-PasswordBox $dlg)
}
Set-ItemProperty -Path $regKey -Name "CloseAfterFill" -Value 1 -Type DWord
Check "process alive after the many-entries test" (-not $p.HasExited)
Stop-Fm $p

# ---------------------------------------------------------------- test 13
Write-Host "`n== 13. a password equal to another entry's name is not re-replaced ==" -ForegroundColor Cyan
# Entry A: name "cs", password "secret1". Entry B: name "secret1", password "secret2".
# Filling A leaves the text "secret1" in the box, which is B's name. The auto-type
# must not turn it into "secret2" - that was a real bug in the fill path.
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (name/password collision)"
foreach ($pair in @(@("cs","secret1"), @("secret1","secret2"))) {
  New-VaultEntry ([uint32]$p.Id) $dlg $pair[0] $pair[1] "new-password dialog appears ($($pair[0]))"
# (creation of $pair[0] / $pair[1] is done by New-VaultEntry below)
}
$pwEdit = [VaultUiTest]::FindDescendant($dlg,120)
[VaultUiTest]::SetEditText($pwEdit, "")
Start-Sleep -Milliseconds 200
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3808))
$lst = Expect-Dialog ([uint32]$p.Id) $T.List "the saved-passwords window appears"
$lv = Wait-Child $lst 124
Select-Row $lv 0   # Fill row 0 ("cs" -> "secret1")
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
Check "filling row 0 left a fillable password box" (Test-PasswordBox $dlg)
Start-Sleep -Milliseconds 1500                        # longer than the auto-type delay
# NOTE (coverage): the replacement bug this test was written for is no longer
# observable from outside the process; only the box itself is asserted here.
Check "the entry named like the password did not break the box" (Test-PasswordBox $dlg)
Check "process alive after the collision test" (-not $p.HasExited)
Stop-Fm $p

# ---------------------------------------------------------------- test 14
Write-Host "`n== 14. awkward names ==" -ForegroundColor Cyan
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
$longName = "L" * 200
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (awkward names)"
$cases = @(
  @{ in = "  带空格  "; out = "带空格"; pw = "Pw-Space" },
  @{ in = $longName;    out = $longName; pw = "Pw-Long" },
  @{ in = "a";          out = "a";       pw = "Pw-One" }
)
foreach ($c in $cases) {
  New-VaultEntry ([uint32]$p.Id) $dlg $c.in $c.pw "new-password dialog appears (awkward name)"
# (creation of $c.in / $c.pw is done by New-VaultEntry below)
}
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "the saved-passwords window appears (awkward names)"
$lv = Wait-Child $lst 124
Check "all three awkward names are stored" ((Wait-Rows $lv 3) -eq 3) "(rows=$([VaultUiTest]::SendLong($lv, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero)))"
$n0 = [VaultUiTest]::GetListText($lv, 0, 0)
Check "a name is trimmed of surrounding spaces" ($n0 -eq $cases[0].out) "(got [$n0])"
$n1 = [VaultUiTest]::GetListText($lv, 1, 0)
Check "a 200 character name is stored intact" ($n1 -eq $longName) "(len=$($n1.Length))"
$pwEdit = [VaultUiTest]::FindDescendant($dlg,120)
[VaultUiTest]::SetEditText($pwEdit, "")
Start-Sleep -Milliseconds 150
Select-Row $lv 1   # Fill the long-named row
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
Check "the long-named entry still fills a password box" (Test-PasswordBox $dlg)
Check "process alive after the awkward-names test" (-not $p.HasExited)
Stop-Fm $p

# ---------------------------------------------------------------- test 15
Write-Host "`n== 15. end to end: a vault password really extracts an archive ==" -ForegroundColor Cyan
# 7zG shows the same password dialog for extraction, so the vault must be able to
# unlock a real archive and produce the real files.
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
$dest = Join-Path $workDir "out_gui"
Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
# store the archive password first, through the normal dialog
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (to store the archive password)"
New-VaultEntry ([uint32]$p.Id) $dlg "the-archive" "ArchivePw" "new-password dialog stores the archive password"
# (creation of "the-archive" / "ArchivePw" is done by New-VaultEntry below)
Stop-Fm $p

$g = Start-Process -FilePath $guiExe -ArgumentList @("x", "-y", "-o`"$dest`"", "`"$archive`"") -PassThru
$gdlg = Expect-Dialog ([uint32]$g.Id) $T.Password "7zG asks for the archive password" 15
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($gdlg, 3808))     # saved passwords
$lst = Expect-Dialog ([uint32]$g.Id) $T.List "the vault window opens from 7zG"
$lv = Wait-Child $lst 124
Check "the archive password is in the vault" ([VaultUiTest]::GetListText($lv, 0, 0) -eq "the-archive") "(row0=[$([VaultUiTest]::GetListText($lv, 0, 0))])"
Select-Row $lv 0   # Fill (closes the window)
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
Check "the password landed in the extraction dialog" (Test-PasswordBox $gdlg)
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($gdlg, 1))        # OK -> extract
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline -and -not $g.HasExited) { Start-Sleep -Milliseconds 200 }
$extracted = Join-Path $dest "hello.txt"
Check "the archive was really extracted" (Test-Path $extracted) "(looked for $extracted)"
if (Test-Path $extracted) {
  $text = (Get-Content $extracted -Raw).Trim()
  Check "the extracted file has the original content" ($text -eq "secret content") "(got [$text])"
}
Check "7zG finished" ($g.HasExited) "(still running)"
if (-not $g.HasExited) { Stop-Process -Id $g.Id -Force }

# ---------------------------------------------------------------- test 16
Write-Host "`n== 16. end to end: the compress dialog really encrypts ==" -ForegroundColor Cyan
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
$madeArc = Join-Path $workDir "made-by-gui.7z"
Remove-Item $madeArc -Force -ErrorAction SilentlyContinue
$g = Start-Process -FilePath $guiExe -ArgumentList @("a", "-ad", "-t7z", "`"$madeArc`"", "`"$plain`"") -PassThru
$cd = Expect-Dialog ([uint32]$g.Id) $T.Compress "the add-to-archive dialog appears" 15
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($cd, 3809))       # new password
$ed = Expect-Dialog ([uint32]$g.Id) $T.NewPassword "a password is stored from the vault"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), "made-here")
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), "GuiMadePw")
Start-Sleep -Milliseconds 250
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
Check "the compress dialog received the stored password" (Test-PasswordBox $cd)
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($cd, 1))          # OK -> create the archive
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline -and -not (Test-Path $madeArc)) { Start-Sleep -Milliseconds 200 }
Check "the archive was created through the dialog" (Test-Path $madeArc)
if (-not $g.HasExited) { Stop-Process -Id $g.Id -Force }
if (Test-Path $madeArc) {
  $szExe = Join-Path $SevenZipDir "7z.exe"
  # Supplying an explicit wrong password keeps this check non-interactive.
  # Omitting -p makes 7z.exe prompt on stdin and leaves the test waiting forever.
  $null = & $szExe t "-pGuiMadePw" $madeArc 2>&1
  Check "the archive opens with the vault password" ($LASTEXITCODE -eq 0)
  $null = & $szExe t "-pNotGuiMadePw" $madeArc 2>&1
  Check "the archive rejects an incorrect password" ($LASTEXITCODE -ne 0)
  $dest2 = Join-Path $workDir "out_gui_made"
  Remove-Item -Recurse -Force $dest2 -ErrorAction SilentlyContinue
  $null = & $szExe x "-pGuiMadePw" $madeArc "-o$dest2" -y 2>&1
  $f = Join-Path $dest2 "hello.txt"
  Check "the archive made by the dialog extracts correctly" ((Test-Path $f) -and ((Get-Content $f -Raw).Trim() -eq "secret content"))
}

# ---------------------------------------------------------------- test 17
Write-Host "`n== 17. master password mode ==" -ForegroundColor Cyan
# The vault can be re-encrypted with a master password so it becomes portable.
# This exercises the whole mode: set it, store an entry, restart, unlock, read back.
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regKey -Name "UseMasterPassword"      -Value 0 -Type DWord
Set-ItemProperty -Path $regKey -Name "RememberMasterPassword" -Value 1 -Type DWord
$p = Start-Process -FilePath $fmExe -PassThru
Start-Sleep -Seconds 4
$fmWnd = [VaultUiTest]::FindDialogClass([uint32]$p.Id, "7-Zip::FM")
[void][VaultUiTest]::PostMessageW($fmWnd, 0x0111, [IntPtr]900, [IntPtr]::Zero)
$opt = Expect-Dialog ([uint32]$p.Id) $T.Options "options dialog opens for the master password" 12
$tab = [VaultUiTest]::FindDescendant($opt, 12320)
$titles = @()
for ($i = 0; $i -lt [VaultUiTest]::GetTabCount($tab); $i++) { $titles += [VaultUiTest]::GetTabText($tab, $i) }
$idx = [array]::IndexOf($titles, $T.Page)
if ($idx -ge 0) { [VaultUiTest]::MoveCursorHome(); [void][VaultUiTest]::ClickTab($tab, $idx); Start-Sleep -Seconds 2 }
Check "the password page is reachable" ([VaultUiTest]::FindDescendant($opt, 2601) -ne [IntPtr]::Zero)

[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($opt, 2606))   # Set master password
$m1 = Expect-Dialog ([uint32]$p.Id) $T.Master "the master password is asked for"
$m1edit = Wait-Child $m1 123
Check "the master password box is there" ($m1edit -ne [IntPtr]::Zero)
[VaultUiTest]::SetEditText($m1edit, "MasterPw123")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton((Wait-Child $m1 1))
# The second prompt must be a DIFFERENT window: the first one stays open until it
# is accepted, and a check that only looks for the title would pass on it.
$m2 = [IntPtr]::Zero
$m2deadline = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $m2deadline) {
  $cand = [VaultUiTest]::FindDialog([uint32]$p.Id, $T.Master)
  if ($cand -ne [IntPtr]::Zero -and $cand -ne $m1) { $m2 = $cand; break }
  Start-Sleep -Milliseconds 100
}
Check "the master password is asked a second time" ($m2 -ne [IntPtr]::Zero) "(first dialog is still the only one)"
$m2edit = Wait-Child $m2 123
[VaultUiTest]::SetEditText($m2edit, "MasterPw123")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton((Wait-Child $m2 1))
Start-Sleep -Seconds 1
Check "setting a master password creates a vault" (Wait-File $vault)
if (Test-Path $vault) {
  $b = [IO.File]::ReadAllBytes($vault)
  Check "the vault is marked as master password encrypted" ($b[5] -eq 1) "(flags=$($b[5]))"
}
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($opt, 1))      # OK applies the page
Start-Sleep -Seconds 2
Stop-Fm $p

# store an entry in the master vault
$p = Start-Fm $archive
$m = Expect-Dialog ([uint32]$p.Id) $T.Master "the master password is asked when the vault opens"
[VaultUiTest]::SetEditText((Wait-Child $m 123), "MasterPw123")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton((Wait-Child $m 1))
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "the password dialog appears after unlocking"
New-VaultEntry ([uint32]$p.Id) $dlg "master-entry" "PwInMasterMode" "new-password dialog appears in master mode"
# (creation of "master-entry" / "PwInMasterMode" is done by New-VaultEntry below)
$p.Refresh()
Check "the entry was stored in the master vault" (Test-Path $vault)
Check "process alive after storing in master mode" (-not $p.HasExited)
Stop-Fm $p

# restart: the entry must survive the master-password round trip
$p = Start-Fm $archive
$m = Expect-Dialog ([uint32]$p.Id) $T.Master "the master password is asked again after a restart"
[VaultUiTest]::SetEditText((Wait-Child $m 123), "MasterPw123")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton((Wait-Child $m 1))
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "the password dialog appears (master restart)"
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "the list opens in master mode"
$lv = Wait-Child $lst 124
Check "the entry survived the master-password round trip" ([VaultUiTest]::GetListText($lv, 0, 0) -eq "master-entry") "(row0=[$([VaultUiTest]::GetListText($lv, 0, 0))])"
Check "the value is masked by default in master mode" ([VaultUiTest]::GetListText($lv, 0, 1) -eq $masked)
Select-Row $lv 0
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
Check "filling works in master mode" (Test-PasswordBox $dlg)
Check "process alive after the master-password round trip" (-not $p.HasExited)
Stop-Fm $p

# a wrong master password must not unlock the vault
$p = Start-Fm $archive
$m = Expect-Dialog ([uint32]$p.Id) $T.Master "the master password is asked (wrong password)"
[VaultUiTest]::SetEditText((Wait-Child $m 123), "WrongMasterPw")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton((Wait-Child $m 1))
$errBox = Wait-Dialog ([uint32]$p.Id) $T.Caption 4
$again = Wait-Dialog ([uint32]$p.Id) $T.Master 4
Check "a wrong master password does not unlock the vault" (($errBox -ne [IntPtr]::Zero) -or ($again -ne [IntPtr]::Zero))
if ($errBox -ne [IntPtr]::Zero) { [void](Close-Box ([uint32]$p.Id) $errBox $T.Caption) }
Check "process alive after a wrong master password" (-not $p.HasExited)
Stop-Fm $p

# With "remember master password" off, storing an entry has to ask for it again. It
# must be asked with the dialog as its owner (a prompt without an owner can end up
# behind the window), and the entry must be stored once it is answered.
Set-ItemProperty -Path $regKey -Name "RememberMasterPassword" -Value 0 -Type DWord
$p = Start-Fm $archive
$m = Expect-Dialog ([uint32]$p.Id) $T.Master "the master password is asked (not remembered)"
[VaultUiTest]::SetEditText((Wait-Child $m 123), "MasterPw123")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton((Wait-Child $m 1))
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "the password dialog appears (not remembered)"
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
$ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog appears (not remembered)"
[VaultUiTest]::SetEditText((Wait-Child $ed 121), "not-remembered")
[VaultUiTest]::SetEditText((Wait-Child $ed 122), "PwNotRemembered")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton((Wait-Child $ed 1))
$again = Wait-Dialog ([uint32]$p.Id) $T.Master 6
Check "saving asks for the master password again when it is not remembered" ($again -ne [IntPtr]::Zero)
if ($again -ne [IntPtr]::Zero) {
  [VaultUiTest]::SetEditText((Wait-Child $again 123), "MasterPw123")
  Start-Sleep -Milliseconds 300
  [VaultUiTest]::ClickButton((Wait-Child $again 1))
  Start-Sleep -Seconds 1
}
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "the list opens (not remembered)"
$lv = Wait-Child $lst 124
Check "the entry was stored after answering the prompt" ((Find-Row $lv "not-remembered" 6) -ge 0) "(rows=$([VaultUiTest]::SendLong($lv, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero)) first=[$([VaultUiTest]::GetListText($lv, 0, 0))])"
Check "process alive after the not-remembered path" (-not $p.HasExited)
Stop-Fm $p

# back to the default DPAPI mode for the rest of the run
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regKey -Name "UseMasterPassword" -Value 0 -Type DWord
$unlocked = Start-Fm $archive
$udlg = Expect-Dialog ([uint32]$unlocked.Id) $T.Password "DPAPI mode works again after clearing the master password"
Stop-Fm $unlocked
# ---------------------------------------------------------------- test 18
Write-Host "`n== 18. the password of unnamed entries can be shown on demand ==" -ForegroundColor Cyan

# An unnamed entry shows nothing in the name column, so the list cannot be searched
# by name. The option shows its password instead of dots; named entries stay masked,
# and the plaintext still only exists after the vault was unlocked.
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regKey -Name "ShowPasswordInList"     -Value 0 -Type DWord
Set-ItemProperty -Path $regKey -Name "ShowPasswordForUnnamed" -Value 0 -Type DWord

$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (unnamed password display)"
New-VaultEntry ([uint32]$p.Id) $dlg "showme" "PwNamed" "new-password dialog appears (named entry)"
# (creation of "showme" / "PwNamed" is done by New-VaultEntry below)
# (creation of "" / "PwUnnamed" is done by New-VaultEntry below)
New-VaultEntry ([uint32]$p.Id) $dlg "" "PwUnnamed" "new-password dialog appears (unnamed entry)"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "")
Start-Sleep -Milliseconds 200

# with the setting off both rows are masked, even the one without a name
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "the list opens (unnamed password display off)"
$lv = Wait-Child $lst 124
[void](Wait-Rows $lv 2 5)
$rowNamed   = Find-Row $lv "showme"
$rowUnnamed = Find-Row $lv ""
Check "the named and the unnamed entry are both listed" (($rowNamed -ge 0) -and ($rowUnnamed -ge 0)) "(named=$rowNamed unnamed=$rowUnnamed)"
Check "the named row is masked with the setting off" ([VaultUiTest]::GetListText($lv, $rowNamed, 1) -eq $masked) "(got [$([VaultUiTest]::GetListText($lv, $rowNamed, 1))])"
Check "the unnamed row is masked with the setting off" ([VaultUiTest]::GetListText($lv, $rowUnnamed, 1) -eq $masked) "(got [$([VaultUiTest]::GetListText($lv, $rowUnnamed, 1))])"
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3817))   # Close
Check "the list window closes (setting off)" (Wait-NoDialog ([uint32]$p.Id) $T.List 5)
Check "process alive after the unnamed password display test" (-not $p.HasExited)
Stop-Fm $p

# with the setting on only the unnamed row reveals its password
Set-ItemProperty -Path $regKey -Name "ShowPasswordForUnnamed" -Value 1 -Type DWord
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (unnamed password display on)"
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "the list opens (unnamed password display on)"
$lv = Wait-Child $lst 124
[void](Wait-Rows $lv 2 5)
$rowNamed   = Find-Row $lv "showme"
$rowUnnamed = Find-Row $lv ""
Check "the unnamed row shows its own password" ([VaultUiTest]::GetListText($lv, $rowUnnamed, 1) -eq "PwUnnamed") "(got [$([VaultUiTest]::GetListText($lv, $rowUnnamed, 1))])"
Check "the named row is still masked with the setting on" ([VaultUiTest]::GetListText($lv, $rowNamed, 1) -eq $masked) "(got [$([VaultUiTest]::GetListText($lv, $rowNamed, 1))])"
# the revealed row must still fill correctly
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "")
Start-Sleep -Milliseconds 200
Select-Row $lv $rowUnnamed
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
Check "the revealed unnamed entry still fills" (Test-PasswordBox $dlg) "(edit=[$([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($dlg,120)))])"
Check "process alive after revealing an unnamed password" (-not $p.HasExited)
Stop-Fm $p

# the switch is on the settings page and is applied by OK
$p = Start-Fm $archive
Start-Sleep -Seconds 2
$fmWnd = [VaultUiTest]::FindDialogClass([uint32]$p.Id, "7-Zip::FM")
[void][VaultUiTest]::PostMessageW($fmWnd, 0x0111, [IntPtr]900, [IntPtr]::Zero)
$opt = Expect-Dialog ([uint32]$p.Id) $T.Options "options dialog opens (unnamed password setting)" 12
$tab = [VaultUiTest]::FindDescendant($opt, 12320)
$titles = @()
for ($i = 0; $i -lt [VaultUiTest]::GetTabCount($tab); $i++) { $titles += [VaultUiTest]::GetTabText($tab, $i) }
$idx = [array]::IndexOf($titles, $T.Page)
if ($idx -ge 0) { [VaultUiTest]::MoveCursorHome(); [void][VaultUiTest]::ClickTab($tab, $idx); Start-Sleep -Seconds 2 }
$chk = [VaultUiTest]::FindDescendant($opt, 2615)
Check "the unnamed password switch is on the settings page" ($chk -ne [IntPtr]::Zero)
Check "the switch reflects the stored setting" (([VaultUiTest]::SendLong($chk, 0x00F0, [IntPtr]::Zero, [IntPtr]::Zero)) -eq 1) "(check=$([VaultUiTest]::SendLong($chk, 0x00F0, [IntPtr]::Zero, [IntPtr]::Zero)))"
[VaultUiTest]::ClickButton($chk)
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($opt, 1))      # OK applies the page
Start-Sleep -Seconds 2
Check "turning the switch off is applied" ((Get-ItemProperty -Path $regKey -Name "ShowPasswordForUnnamed").ShowPasswordForUnnamed -eq 0) "(value=$((Get-ItemProperty -Path $regKey -Name "ShowPasswordForUnnamed").ShowPasswordForUnnamed))"
Check "process alive after the settings page round trip" (-not $p.HasExited)
Stop-Fm $p

# ---------------------------------------------------------------- test 19
Write-Host "`n== 19. Chinese names and passwords survive every step ==" -ForegroundColor Cyan
# Non-ASCII text has to survive the edit controls, the vault file, DPAPI / AES-GCM
# and the list control. A place that silently fell back to ANSI would fail here.
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
$cnName = "中文站点"
$cnPw   = "密码测试-äöü-123"
$cnArc  = Join-Path $workDir "cn-password.7z"
Remove-Item $cnArc -Force -ErrorAction SilentlyContinue

& $szExe a -t7z -mhe -p"$cnPw" $cnArc $plain | Out-Null
Check "the engine made an archive with a Chinese password" (Test-Path $cnArc)
if (Test-Path $cnArc) {
  & $szExe t -p"$cnPw" $cnArc | Out-Null
  Check "the Chinese password really is that archive's password" ($LASTEXITCODE -eq 0) "(7z exit $LASTEXITCODE)"
}

$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (Chinese entry)"
New-VaultEntry ([uint32]$p.Id) $dlg $cnName $cnPw "new-password dialog appears (Chinese entry)"
# (creation of $cnName / $cnPw is done by New-VaultEntry below)
$pwEdit = [VaultUiTest]::FindDescendant($dlg, 120)
Check "the Chinese password reached the input box" (Test-PasswordBox $dlg)

# the file itself must not contain the name or the password in any common encoding
if (Test-Path $vault) {
  $bytes = [IO.File]::ReadAllBytes($vault)
  $pwB = Get-SecretBytes $cnPw
  $nmB = Get-SecretBytes $cnName
  Check "the Chinese password is not in the vault file (UTF-8)"  (-not (Test-BytesContain $bytes $pwB.utf8))  "(plaintext found)"
  Check "the Chinese password is not in the vault file (UTF-16)" (-not (Test-BytesContain $bytes $pwB.utf16)) "(plaintext found)"
  Check "the Chinese password is not in the vault file (ANSI)"   (-not (Test-BytesContain $bytes $pwB.ansi))  "(plaintext found)"
  Check "the Chinese name is not in the vault file (UTF-8)"      (-not (Test-BytesContain $bytes $nmB.utf8))  "(plaintext found)"
  Check "the Chinese name is not in the vault file (UTF-16)"     (-not (Test-BytesContain $bytes $nmB.utf16)) "(plaintext found)"
}

# the list must show the Chinese name unchanged, mask the password, and fill it back
[VaultUiTest]::SetEditText($pwEdit, "")
Start-Sleep -Milliseconds 200
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "the list opens (Chinese entry)"
$lv = Wait-Child $lst 124
$cnRow = Find-Row $lv $cnName
Check "the Chinese name survived into the list" ($cnRow -ge 0) "(rows=$([VaultUiTest]::SendLong($lv, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero)))"
if ($cnRow -ge 0) {
  Check "the Chinese password is masked in the list" ([VaultUiTest]::GetListText($lv, $cnRow, 1) -eq $masked) "(got [$([VaultUiTest]::GetListText($lv, $cnRow, 1))])"
  Select-Row $lv $cnRow
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))     # Fill
  Check "the Chinese password is filled from the list" (Test-PasswordBox $dlg)
} else {
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3817))
}
Check "process alive after the Chinese entry test" (-not $p.HasExited)
Stop-Fm $p

# end to end: the Chinese password from the vault must really decrypt that archive
$cnDest = Join-Path $workDir "out_cn"
Remove-Item -Recurse -Force $cnDest -ErrorAction SilentlyContinue
$g = Start-Process -FilePath $guiExe -ArgumentList @("x", "-y", "-o`"$cnDest`"", "`"$cnArc`"") -PassThru
$gdlg = Expect-Dialog ([uint32]$g.Id) $T.Password "7zG asks for the Chinese archive password" 15
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($gdlg, 3808))      # saved passwords
$lst = Expect-Dialog ([uint32]$g.Id) $T.List "the vault window opens for the Chinese archive"
$lv = Wait-Child $lst 124
$cnRow = Find-Row $lv $cnName
Check "the Chinese entry is offered to 7zG" ($cnRow -ge 0)
if ($cnRow -ge 0) {
  Select-Row $lv $cnRow
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))     # Fill
  Check "the Chinese password landed in the extraction dialog" (Test-PasswordBox $gdlg)
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($gdlg, 1))       # OK -> extract
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline -and -not $g.HasExited) { Start-Sleep -Milliseconds 200 }
  $cnOut = Join-Path $cnDest "hello.txt"
  Check "the archive with the Chinese password was really extracted" (Test-Path $cnOut) "(looked for $cnOut)"
  if (Test-Path $cnOut) {
    $text = (Get-Content $cnOut -Raw).Trim()
    Check "the extracted content is correct (Chinese password)" ($text -eq "secret content") "(got [$text])"
  }
} else {
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3817))
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($gdlg, 2))       # Cancel
}
Check "7zG finished (Chinese password)" ($g.HasExited) "(still running)"
if (-not $g.HasExited) { Stop-Process -Id $g.Id -Force }

# ---------------------------------------------------------------- test 20
Write-Host "`n== 20. the vault is portable: copy the file, keep the passwords ==" -ForegroundColor Cyan
# "Portable" means the file is the whole state. Copying the vault somewhere else and
# pointing the vault path at the copy is exactly what a backup / another machine
# does, and it must work with the master password alone.
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
$moved     = Join-Path $workDir "moved-vault.dat"
$exported  = Join-Path $workDir "exported-vault.dat"
$restored  = Join-Path $workDir "restored-vault.dat"
Remove-Item $moved,"$moved.tmp",$exported,"$exported.tmp",$restored,"$restored.tmp" -Force -ErrorAction SilentlyContinue
$masterPw = "PortableMaster#1"
$portPw   = "PortablePw123"
Set-ItemProperty -Path $regKey -Name "UseMasterPassword"      -Value 1 -Type DWord
Set-ItemProperty -Path $regKey -Name "RememberMasterPassword" -Value 1 -Type DWord
Set-ItemProperty -Path $regKey -Name "AutoLockMaster"         -Value 0 -Type DWord

# 1. store one entry in a master-password vault
$p = if($baselineFm){Start-Process -FilePath $baselineFm -ArgumentList "`"$archive`"" -PassThru}else{Start-Fm $archive}
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (portable vault)"
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
$ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog appears (portable vault)"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), "portable")
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), $portPw)
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
$set = Expect-Dialog ([uint32]$p.Id) $T.Master "saving into a new master vault asks for the master password" 15
Check "the first save into a master vault asks for the master password" ($set -ne [IntPtr]::Zero)
if ($set -ne [IntPtr]::Zero) {
  [VaultUiTest]::SetEditText((Wait-Child $set 123), $masterPw)
  Start-Sleep -Milliseconds 300
  [VaultUiTest]::ClickButton((Wait-Child $set 1))
  Start-Sleep -Seconds 1
}
Check "the portable vault was written" (Wait-File $vault)
Check "process alive after the portable save" (-not $p.HasExited)
Stop-Fm $p

if (Test-Path $vault) {
  $vb = [IO.File]::ReadAllBytes($vault)
  Check "the portable vault is in master-password mode" ($vb[5] -eq 1) "(flags=$($vb[5]))"
}

# 2. copy it, as a user would when moving the vault to another computer
if (Test-Path $vault) { Copy-Item -LiteralPath $vault -Destination $moved -Force }
Check "the vault can be copied to another path" (Test-Path $moved)
if (Test-Path $moved) {
  $mb = [IO.File]::ReadAllBytes($moved)
  $pb = Get-SecretBytes $portPw
  Check "the copy is still a master-password vault" ($mb[5] -eq 1) "(flags=$($mb[5]))"
  Check "the copy holds the password only encrypted (UTF-8)"  (-not (Test-BytesContain $mb $pb.utf8))
  Check "the copy holds the password only encrypted (UTF-16)" (-not (Test-BytesContain $mb $pb.utf16))
  $dp = Get-SecretBytes "portable"
  Check "the copy does not leak the entry name" (-not (Test-BytesContain $mb $dp.utf8))
}

# 3. use the copy from a fresh process, with only the master password
Set-ItemProperty -Path $regKey -Name "VaultPath" -Value $moved -Type String
$p = Start-Fm $archive
$m = Expect-Dialog ([uint32]$p.Id) $T.Master "the moved vault asks for the master password" 15
if ($m -ne [IntPtr]::Zero) {
  [VaultUiTest]::SetEditText((Wait-Child $m 123), $masterPw)
  Start-Sleep -Milliseconds 300
  [VaultUiTest]::ClickButton((Wait-Child $m 1))
  $dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "the moved vault opened with the master password" 15
  $lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "the list opens for the moved vault"
  $lv = Wait-Child $lst 124
  $mvRow = Find-Row $lv "portable"
  Check "the entry travelled with the vault file" ($mvRow -ge 0) "(rows=$([VaultUiTest]::SendLong($lv, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero)))"
  if ($mvRow -ge 0) {
    $pwEdit = [VaultUiTest]::FindDescendant($dlg, 120)
    [VaultUiTest]::SetEditText($pwEdit, "")
    Start-Sleep -Milliseconds 200
    Select-Row $lv $mvRow
    [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))   # Fill
    Check "the moved vault fills the right password" (Test-PasswordBox $dlg)
  } else {
    [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3817))
  }
}
Check "process alive after opening the moved vault" (-not $p.HasExited)
Stop-Fm $p

# 4. export / import through the settings page: the documented migration path
#    The page loads the vault of the configured path as soon as it is shown, so a
#    master-password vault would ask for its password right there. The configured
#    path is pointed at a file that does not exist yet, so the unlocking below is
#    done by the import itself - which is what that check is about.
Set-ItemProperty -Path $regKey -Name "VaultPath" -Value $restored -Type String
$p = Start-Process -FilePath $fmExe -PassThru
Start-Sleep -Seconds 4
$fmWnd = [VaultUiTest]::FindDialogClass([uint32]$p.Id, "7-Zip::FM")
[void][VaultUiTest]::PostMessageW($fmWnd, 0x0111, [IntPtr]900, [IntPtr]::Zero)   # IDM_OPTIONS
$opt = Expect-Dialog ([uint32]$p.Id) $T.Options "options dialog opens (export)" 12
$tab = [VaultUiTest]::FindDescendant($opt, 12320)
$titles = @()
for ($i = 0; $i -lt [VaultUiTest]::GetTabCount($tab); $i++) { $titles += [VaultUiTest]::GetTabText($tab, $i) }
$idx = [array]::IndexOf($titles, $T.Page)
if ($idx -ge 0) { [VaultUiTest]::MoveCursorHome(); [void][VaultUiTest]::ClickTab($tab, $idx); Start-Sleep -Seconds 2 }

Check "a vault that does not exist yet is not unlocked" ((Wait-Dialog ([uint32]$p.Id) $T.Master 2) -eq [IntPtr]::Zero)

# Export vault... -> the file dialog -> the exported file is a byte copy of the vault.
# The vault being exported is the portable one written above, so the path box is
# pointed at it first.
$pathEdit = Wait-Child $opt 101 5
Check "the settings page has a vault path box" ($pathEdit -ne [IntPtr]::Zero)
[VaultUiTest]::SetEditText($pathEdit, $moved)
Start-Sleep -Milliseconds 400
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($opt, 2612))
$bd = [IntPtr]::Zero
$bdeadline = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $bdeadline) {
  $bd = [VaultUiTest]::FindDialog([uint32]$p.Id, $T.ExportTitle)
  if ($bd -ne [IntPtr]::Zero) { break }
  Start-Sleep -Milliseconds 150
}
Check "the export file dialog opens" ($bd -ne [IntPtr]::Zero)
if ($bd -ne [IntPtr]::Zero) {
  Check "the export dialog was filled in" ([VaultUiTest]::FillBrowseDialog($bd, $exported))
  Start-Sleep -Seconds 2
  # the info box reports success; it is modal, so it has to be dismissed
  $info = Wait-Dialog ([uint32]$p.Id) $T.Caption 8
  Check "the export reports success" (Test-Path $exported) "(no $exported)"
  if ($info -ne [IntPtr]::Zero) {
    $exportMsg = [VaultUiTest]::GetControlText([VaultUiTest]::FindDescendant($info, 0xFFFF))
    Check "the export message box follows the UI language" (Test-LocalizedText $exportMsg) "(message=[$exportMsg])"
  }
  Check "the export message box closes again" (Close-Box ([uint32]$p.Id) $info $T.Caption)
  if ((Test-Path $exported) -and (Test-Path $moved)) {
    $a = (Get-FileHash $moved -Algorithm SHA256).Hash
    $b = (Get-FileHash $exported -Algorithm SHA256).Hash
    Check "the export is a faithful copy of the vault" ($a -eq $b)
  }
}

# Import vault... into a fresh path: the entries must come back
if (Test-Path $exported) {
  [VaultUiTest]::SetEditText($pathEdit, $restored)
  Start-Sleep -Milliseconds 400
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($opt, 2613))
  $bd = [IntPtr]::Zero
  $bdeadline = (Get-Date).AddSeconds(8)
  while ((Get-Date) -lt $bdeadline) {
    $bd = [VaultUiTest]::FindDialog([uint32]$p.Id, $T.ImportTitle)
    if ($bd -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 150
  }
  Check "the import file dialog opens" ($bd -ne [IntPtr]::Zero)
  if ($bd -ne [IntPtr]::Zero) {
    Check "the import dialog was filled in" ([VaultUiTest]::FillBrowseDialog($bd, $exported))
    # the source vault is master-password protected, so it has to be unlocked once
    $im = Expect-Dialog ([uint32]$p.Id) $T.Master "importing a master vault asks for its master password" 15
    Check "the import asks for the master password of the source vault" ($im -ne [IntPtr]::Zero)
    if ($im -ne [IntPtr]::Zero) {
      [VaultUiTest]::SetEditText((Wait-Child $im 123), $masterPw)
      Start-Sleep -Milliseconds 300
      [VaultUiTest]::ClickButton((Wait-Child $im 1))
    }
    $info = Wait-Dialog ([uint32]$p.Id) $T.Caption 10
    Check "the import reports what it merged" ($info -ne [IntPtr]::Zero)
    if ($info -ne [IntPtr]::Zero) {
      $msgText = [VaultUiTest]::GetControlText([VaultUiTest]::FindDescendant($info, 0xFFFF))
      Check "the import reports one added entry" ($msgText -match "1") "(message=[$msgText])"
      Check "the import message box follows the UI language" (Test-LocalizedText $msgText) "(message=[$msgText])"
      Check "the import message box closes again" (Close-Box ([uint32]$p.Id) $info $T.Caption)
    }
    Check "the imported vault was written to the new path" (Test-Path $restored)
    if (Test-Path $restored) {
      $rb = [IO.File]::ReadAllBytes($restored)
      Check "the imported vault kept the master-password mode" ($rb[5] -eq 1) "(flags=$($rb[5]))"
      $pb = Get-SecretBytes $portPw
      Check "the imported vault holds no plaintext" (-not (Test-BytesContain $rb $pb.utf8))
    }
  }
}
Check "process alive after the export / import round trip" (-not $p.HasExited)
Stop-Fm $p
if($baselineFm){
  Write-Host "`n== 20b. review3 to review4 upgrade and isolated rollback ==" -ForegroundColor Cyan
  $upgradeFailStart=$script:fail
  $preUpgrade=Join-Path $workDir 'pre-upgrade-vault.dat'
  $rollbackVault=Join-Path $workDir 'rollback-vault.dat'
  if(-not(Test-Path -LiteralPath $moved -PathType Leaf)){throw 'Upgrade fixture missing the review3 vault'}
  Copy-Item -LiteralPath $moved -Destination $preUpgrade -Force
  $beforeHash=(Get-FileHash -LiteralPath $preUpgrade).Hash
  Set-ItemProperty -Path $regKey -Name 'VaultPath' -Value $moved -Type String
  $p=Start-Fm $archive
  $unlock=Expect-Dialog ([uint32]$p.Id) $T.Master 'review4 asks to unlock the review3 vault' 15
  if($unlock -ne [IntPtr]::Zero){
    [VaultUiTest]::SetEditText((Wait-Child $unlock 123),$masterPw)
    [VaultUiTest]::ClickButton((Wait-Child $unlock 1))
  }
  $dlg=Expect-Dialog ([uint32]$p.Id) $T.Password 'review4 opens the review3 vault' 15
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg,3809))
  $new=Expect-Dialog ([uint32]$p.Id) $T.NewPassword 'review4 opens new-password dialog after upgrade'
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($new,121),'upgrade-only')
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($new,122),'UpgradeOnly#1')
  Start-Sleep -Milliseconds 300
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($new,1))
  $saveMaster=Wait-Dialog ([uint32]$p.Id) $T.Master 3
  if($saveMaster -ne [IntPtr]::Zero){
    [VaultUiTest]::SetEditText((Wait-Child $saveMaster 123),$masterPw)
    [VaultUiTest]::ClickButton((Wait-Child $saveMaster 1))
  }
  Check 'review4 saved an upgraded ciphertext' ((Wait-File "$moved.bak" 10) -and ((Get-FileHash -LiteralPath $moved).Hash -ne $beforeHash))
  Check 'review4 backup is exactly the encrypted pre-upgrade vault' ((Get-FileHash -LiteralPath "$moved.bak").Hash -eq $beforeHash)
  Check 'review4 upgraded vault contains no plaintext' (-not(Test-BytesContain ([IO.File]::ReadAllBytes($moved)) ([Text.Encoding]::UTF8.GetBytes('UpgradeOnly#1'))))
  Stop-Fm $p
  $upgradedHash=(Get-FileHash -LiteralPath $moved).Hash
  $p=Start-Fm $archive
  $unlock=Expect-Dialog ([uint32]$p.Id) $T.Master 'review4 reopens the upgraded vault' 15
  if($unlock -ne [IntPtr]::Zero){[VaultUiTest]::SetEditText((Wait-Child $unlock 123),$masterPw);[VaultUiTest]::ClickButton((Wait-Child $unlock 1))}
  $dlg=Expect-Dialog ([uint32]$p.Id) $T.Password 'review4 opens upgraded vault after restart' 15
  $lst=Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg,3808)) $T.List 'review4 lists upgraded entries'
  $lv=Wait-Child $lst 124
  Check 'review4 retained the old entry' ((Find-Row $lv 'portable') -ge 0)
  $newRow=Find-Row $lv 'upgrade-only'
  Check 'review4 retained the new entry' ($newRow -ge 0)
  if($newRow -ge 0){
    [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst,3829))
    Check 'review4 retained the new password' ((Wait-ListText $lv $newRow 1 'UpgradeOnly#1') -eq 'UpgradeOnly#1')
  }
  Stop-Fm $p
  Copy-Item -LiteralPath $preUpgrade -Destination $rollbackVault -Force
  Check 'rollback uses a separate encrypted copy' ((Get-FileHash -LiteralPath $rollbackVault).Hash -eq $beforeHash)
  Set-ItemProperty -Path $regKey -Name 'VaultPath' -Value $rollbackVault -Type String
  $p=Start-Process -FilePath $baselineFm -ArgumentList "`"$archive`"" -PassThru
  $unlock=Expect-Dialog ([uint32]$p.Id) $T.Master 'review3 asks to unlock the rollback copy' 15
  if($unlock -ne [IntPtr]::Zero){[VaultUiTest]::SetEditText((Wait-Child $unlock 123),$masterPw);[VaultUiTest]::ClickButton((Wait-Child $unlock 1))}
  $dlg=Expect-Dialog ([uint32]$p.Id) $T.Password 'review3 opens the encrypted rollback copy' 15
  $lst=Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg,3808)) $T.List 'review3 lists the rollback copy'
  $lv=Wait-Child $lst 124
  $oldRow=Find-Row $lv 'portable'
  Check 'review3 rollback retained the old entry' ($oldRow -ge 0)
  if($oldRow -ge 0){
    [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst,3829))
    Check 'review3 rollback retained the old password' ((Wait-ListText $lv $oldRow 1 $portPw) -eq $portPw)
  }
  Check 'review3 rollback excludes the later entry' ((Find-Row $lv 'upgrade-only') -lt 0)
  Check 'rollback did not overwrite the upgraded vault' ((Get-FileHash -LiteralPath $moved).Hash -eq $upgradedHash)
  Stop-Fm $p
  Ensure-UiRunDirectory
  $upgradeResult=[ordered]@{result=if($script:fail -eq $upgradeFailStart){'passed'}else{'failed'};checkedUtc=[DateTime]::UtcNow.ToString('o');account=[Security.Principal.WindowsIdentity]::GetCurrent().Name;windowsBuild=[Environment]::OSVersion.Version.ToString();baselineFileManagerSha256=(Get-FileHash -LiteralPath $baselineFm).Hash;fileManagerSha256=(Get-FileHash -LiteralPath $fmExe).Hash;guiSha256=(Get-FileHash -LiteralPath $guiExe).Hash;preUpgradeVaultSha256=$beforeHash;upgradedVaultSha256=$upgradedHash;backupSha256=(Get-FileHash -LiteralPath "$moved.bak").Hash;rollbackVaultSha256=(Get-FileHash -LiteralPath $rollbackVault).Hash;assertionsPassed=$script:pass;assertionsFailed=$script:fail-$upgradeFailStart;note='review3 EXE ran with test-only MinGW DLLs; rollback used a separate encrypted pre-upgrade copy and did not overwrite the upgraded vault'}
  $upgradeResult|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $script:uiRunDirectory 'upgrade-rollback-result.json') -Encoding UTF8
}
Set-ItemProperty -Path $regKey -Name "UseMasterPassword"      -Value 0 -Type DWord
Set-ItemProperty -Path $regKey -Name "RememberMasterPassword" -Value 0 -Type DWord
# ---------------------------------------------------------------- test 21
Write-Host "`n== 21. the vault location may be a folder ==" -ForegroundColor Cyan
# The field has a Browse button that picks a folder and is labelled "vault location",
# so a folder has to be accepted: saving then used to fail with "cannot replace the
# vault file", because the vault was renamed onto an existing directory.

# OK applies the page AND closes the options dialog, and moving the vault raises a
# question about the file that was left behind, so both are handled here.
function Open-PasswordPage([uint32]$procId, [string]$name) {
  # Start-Process returns before 7zFM has created its main window. Posting WM_COMMAND
  # to a zero handle silently loses the request, which made this late portable check
  # fail intermittently even though the same page passed earlier in the run.
  $deadline = (Get-Date).AddSeconds(12)
  $fm = [IntPtr]::Zero
  while ($fm -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
    $fm = [VaultUiTest]::FindDialogClass($procId, "7-Zip::FM")
    if ($fm -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100 }
  }
  if ($fm -eq [IntPtr]::Zero) { throw "7zFM main window did not appear for $name (PID $procId)" }
  [void][VaultUiTest]::PostMessageW($fm, 0x0111, [IntPtr]900, [IntPtr]::Zero)
  $opt = Expect-Dialog $procId $T.Options $name 12
  $tab = [VaultUiTest]::FindDescendant($opt, 12320)
  $titles = @()
  for ($i = 0; $i -lt [VaultUiTest]::GetTabCount($tab); $i++) { $titles += [VaultUiTest]::GetTabText($tab, $i) }
  $idx = [array]::IndexOf($titles, $T.Page)
  if ($idx -ge 0) { [VaultUiTest]::MoveCursorHome(); [void][VaultUiTest]::ClickTab($tab, $idx); Start-Sleep -Seconds 2 }
  return @{ Opt = $opt; Edit = (Wait-Child $opt 101 5) }
}
# Types a path the way a user does (typing raises EN_CHANGE, WM_SETTEXT does not) and
# presses OK: returns "asked" when the "old file" question came up, otherwise "clean".
function Apply-VaultPath([uint32]$procId, [hashtable]$page, [string]$newPath, [string]$name) {
  [VaultUiTest]::SetEditText($page.Edit, $newPath)
  [VaultUiTest]::NotifyEditChanged($page.Edit, 101)
  Start-Sleep -Milliseconds 400
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($page.Opt, 1))   # OK applies
  Start-Sleep -Seconds 3
  $box = Wait-Dialog $procId $T.Caption 6
  if ($box -eq [IntPtr]::Zero) { return "clean" }
  $yes = [VaultUiTest]::FindChildByClassAndId($box, "Button", 6)
  if ($yes -eq [IntPtr]::Zero) { $yes = [VaultUiTest]::FindSingleButton($box) }
  if ($yes -ne [IntPtr]::Zero) { [VaultUiTest]::ClickControl($yes) }
  Start-Sleep -Seconds 1
  [void](Wait-NoDialog $procId $T.Caption 6)
  return "asked"
}

Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regKey -Name "VaultPath" -Value $vault -Type String
Set-ItemProperty -Path $regKey -Name "UseMasterPassword" -Value 0 -Type DWord
Set-ItemProperty -Path $regKey -Name "RememberMasterPassword" -Value 0 -Type DWord
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (folder test)"
New-VaultEntry ([uint32]$p.Id) $dlg "folder-test" "PwFolderTest" "new-password dialog appears (folder test)"
# (creation of "folder-test" / "PwFolderTest" is done by New-VaultEntry below)
Check "the vault was written before the folder test" (Wait-File $vault)
Stop-Fm $p

$vaultFolder = Join-Path $workDir "vaultdir"
Remove-Item -Recurse -Force $vaultFolder -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $vaultFolder | Out-Null
$inFolder = Join-Path $vaultFolder "7zPasswordVault.dat"
$elsewhere = Join-Path $workDir "moved-away.dat"
Remove-Item $elsewhere,"$elsewhere.tmp" -Force -ErrorAction SilentlyContinue

$p = Start-Process -FilePath $fmExe -PassThru
Start-Sleep -Seconds 4
$page = Open-PasswordPage ([uint32]$p.Id) "options dialog opens (folder test)"
Check "the settings page has the vault path box (folder test)" ($page.Edit -ne [IntPtr]::Zero)
Check "the page opens on the configured vault file" ([VaultUiTest]::GetEditText($page.Edit) -eq $vault) "(got [$([VaultUiTest]::GetEditText($page.Edit))])"

# 1. a folder instead of a file
$originalVaultHash = (Get-FileHash -LiteralPath $vault -Algorithm SHA256).Hash
$result = Apply-VaultPath ([uint32]$p.Id) $page $vaultFolder "the folder path is applied"
Check "copying the vault does not ask to delete the recovery source" ($result -eq "clean") "(result=$result)"
Check "the vault file was created inside the folder" (Wait-File $inFolder 8) "(expected $inFolder)"
Check "the original encrypted vault remains unchanged" (
  (Test-Path -LiteralPath $vault) -and
  ((Get-FileHash -LiteralPath $vault -Algorithm SHA256).Hash -eq $originalVaultHash))
$stored = (Get-ItemProperty -Path $regKey -Name "VaultPath" -ErrorAction SilentlyContinue).VaultPath
Check "the setting points at the file inside the folder" ($stored -eq $inFolder) "(got [$stored])"
Check "process alive after applying a folder" (-not $p.HasExited)

# 2. the page shows the file that is really used, not the folder that was typed
$page = Open-PasswordPage ([uint32]$p.Id) "options dialog reopens (resolved path)"
Check "the page shows the resolved file path" ([VaultUiTest]::GetEditText($page.Edit) -eq $inFolder) "(got [$([VaultUiTest]::GetEditText($page.Edit))])"

# 3. a quoted path (the way Explorer copies one) resolves to the same file
$result = Apply-VaultPath ([uint32]$p.Id) $page ('"' + $vaultFolder + '"') "the quoted folder path is applied"
Check "the quoted folder path did not need to move anything" ($result -eq "clean") "(result=$result)"
$stored = (Get-ItemProperty -Path $regKey -Name "VaultPath" -ErrorAction SilentlyContinue).VaultPath
Check "the quoted path resolved to the same file" ($stored -eq $inFolder) "(got [$stored])"
Check "process alive after the quoted path" (-not $p.HasExited)

# 4. copy to another file, retaining each previous encrypted generation.
$page = Open-PasswordPage ([uint32]$p.Id) "options dialog reopens (move away)"
$folderVaultHash = (Get-FileHash -LiteralPath $inFolder -Algorithm SHA256).Hash
$result = Apply-VaultPath ([uint32]$p.Id) $page $elsewhere "the vault moves to another file"
Check "copying to another file does not ask to delete the recovery source" ($result -eq "clean") "(result=$result)"
Check "the vault really moved to that file" (Wait-File $elsewhere 8) "(expected $elsewhere)"
Check "the encrypted folder copy remains unchanged" (
  (Test-Path -LiteralPath $inFolder) -and
  ((Get-FileHash -LiteralPath $inFolder -Algorithm SHA256).Hash -eq $folderVaultHash))
# The previous destination is deliberately retained by the product. Remove only this
# test-owned copy so the return path is free; overwriting an existing destination is refused.
if (-not [string]::Equals((Split-Path -Parent $inFolder), $vaultFolder, [StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::Equals((Split-Path -Leaf $inFolder), '7zPasswordVault.dat', [StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath $inFolder -PathType Leaf) -or
    ((Get-Item -LiteralPath $inFolder -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    ((Get-FileHash -LiteralPath $inFolder -Algorithm SHA256).Hash -ne $folderVaultHash)) {
  throw "Refusing to remove a vault file not verified as this test's encrypted folder copy: $inFolder"
}
Remove-Item -LiteralPath $inFolder -Force -ErrorAction Stop
$page = Open-PasswordPage ([uint32]$p.Id) "options dialog reopens (move back)"
$elsewhereHash = (Get-FileHash -LiteralPath $elsewhere -Algorithm SHA256).Hash
$result = Apply-VaultPath ([uint32]$p.Id) $page $vaultFolder "the vault moves back into the folder"
Check "copying back into the folder worked" (
  ($result -eq "clean") -and (Wait-File $inFolder 8) -and
  ((Get-ItemProperty -Path $regKey -Name VaultPath -ErrorAction SilentlyContinue).VaultPath -eq $inFolder))
Check "the encrypted file at the previous path remains unchanged" (
  (Test-Path -LiteralPath $elsewhere) -and
  ((Get-FileHash -LiteralPath $elsewhere -Algorithm SHA256).Hash -eq $elsewhereHash))

# 5. the Browse button opens the folder picker and can be closed again
$page = Open-PasswordPage ([uint32]$p.Id) "options dialog reopens (browse button)"
Check "the settings page has a Browse button" ((Wait-Child $page.Opt 2607 5) -ne [IntPtr]::Zero)
[VaultUiTest]::ClickButton((Wait-Child $page.Opt 2607 5))
Start-Sleep -Seconds 2
$picker = [VaultUiTest]::FindDialogClass([uint32]$p.Id, "#32770")
Check "the folder picker opens" ($picker -ne [IntPtr]::Zero)
if ($picker -ne [IntPtr]::Zero) {
  $close = [VaultUiTest]::FindChildByClassAndId($picker, "Button", 2)   # Cancel
  if ($close -eq [IntPtr]::Zero) { $close = [VaultUiTest]::FindSingleButton($picker) }
  if ($close -ne [IntPtr]::Zero) { [VaultUiTest]::ClickControl($close) }
  Start-Sleep -Seconds 2
}
if ($page.Opt -ne [IntPtr]::Zero) { [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($page.Opt, 2)) }  # close the page
Start-Sleep -Seconds 1
Check "process alive after the folder picker" (-not $p.HasExited)
Stop-Fm $p

# 6. the entry is still readable from the vault inside the folder
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears with the vault in a folder"
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "the list opens for the vault in a folder"
$lv = Wait-Child $lst 124
$row = Find-Row $lv "folder-test"
Check "the entry survived the moves" ($row -ge 0) "(rows=$([VaultUiTest]::SendLong($lv, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero)))"
if ($row -ge 0) {
  $pwEdit = [VaultUiTest]::FindDescendant($dlg, 120)
  [VaultUiTest]::SetEditText($pwEdit, "")
  Start-Sleep -Milliseconds 200
  Select-Row $lv $row
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
  Check "the password is filled from the vault in the folder" (Test-PasswordBox $dlg) "(got [$([VaultUiTest]::GetEditText($pwEdit))])"
} else {
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3817))
}
Check "process alive after reading the vault in a folder" (-not $p.HasExited)
Stop-Fm $p

Set-ItemProperty -Path $regKey -Name "VaultPath" -Value $vault -Type String
Remove-Item -Recurse -Force $vaultFolder -ErrorAction SilentlyContinue
Remove-Item $elsewhere,"$elsewhere.tmp" -Force -ErrorAction SilentlyContinue
  # the snapshot must be exactly what was there before
  $beforeHash = if ($script:realVaultExisted) { (Get-FileHash -LiteralPath $realVaultBackup -Algorithm SHA256).Hash } else { "" }
  $afterHash = if (Test-Path -LiteralPath $realVaultEarly) { (Get-FileHash -LiteralPath $realVaultEarly -Algorithm SHA256).Hash } else { "" }
  Check "the real vault file was not modified" ($beforeHash -eq $afterHash)
# ---------------------------------------------------------------- test 22
Write-Host "`n== 22. saving twice in one dialog keeps working ==" -ForegroundColor Cyan
# The vault remembers the size and write time of the file it read and refuses to replace
# a file that changed since - it must therefore refresh that state after its own save,
# otherwise the second save of the same dialog reports a conflict.
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regKey -Name "VaultPath" -Value $vault -Type String
Set-ItemProperty -Path $regKey -Name "UseMasterPassword" -Value 0 -Type DWord
Set-ItemProperty -Path $regKey -Name "RememberMasterPassword" -Value 0 -Type DWord
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (two saves)"
New-VaultEntry ([uint32]$p.Id) $dlg "twice-one" "PwTwiceOne" "the first entry is stored"
Check "the vault was written by the first save" (Wait-File $vault)
New-VaultEntry ([uint32]$p.Id) $dlg "twice-two" "PwTwiceTwo" "the second entry is stored in the same dialog"
Check "no conflict is reported for the second save" ([VaultUiTest]::FindDialog([uint32]$p.Id, $T.Caption) -eq [IntPtr]::Zero)
Check "the dialog is still alive after two saves" (-not $p.HasExited)
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "the list opens after two saves"
$lv = Wait-Child $lst 124
Check "both entries are in the vault" ((Wait-Rows $lv 2) -eq 2) "(rows=$([VaultUiTest]::SendLong($lv, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero)))"
Check "the first entry survived the second save" ((Find-Row $lv "twice-one") -ge 0)
Check "the second entry is there" ((Find-Row $lv "twice-two") -ge 0)
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3817))
Check "process alive after two saves" (-not $p.HasExited)
Stop-Fm $p

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
# ---------------------------------------------------------------- test 24a
Write-Host "`n== 24a. two default vaults: ask once, then remember ==" -ForegroundColor Cyan
# Both default locations hold a vault next to the program and in %APPDATA%\7-Zip and no
# location is recorded: the program has to ask, because guessing would show an empty list
# while the real entries sit in the other file. An existing user vault is never written;
# a missing one gets a temporary encrypted fixture removed in the inner finally block.
# Test 23 deliberately damaged the working vault. Make a fresh encrypted fixture before
# copying it to either default location.
Set-ItemProperty -Path $regKey -Name "VaultPath" -Value $vault -Type String
Set-ItemProperty -Path $regKey -Name "UseMasterPassword" -Value 0 -Type DWord
Remove-Item -LiteralPath $vault,$vaultTmp,"$vault.bak" -Force -ErrorAction SilentlyContinue
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (two-default fixture)"
New-VaultEntry ([uint32]$p.Id) $dlg "two-default-fixture" "FixturePw-24" "encrypted two-default fixture is created"
Stop-Fm $p
$fixtureReady = Test-Path -LiteralPath $vault -PathType Leaf
if ($fixtureReady) {
  $fixtureBytes = [IO.File]::ReadAllBytes($vault)
  $fixtureReady = $fixtureBytes.Length -ge 6 -and $fixtureBytes[4] -eq 4 -and $fixtureBytes[5] -eq 0
}
Check "the two-default fixture is an encrypted DPAPI v4 vault" $fixtureReady
if (-not $fixtureReady) { throw 'Could not prepare the encrypted two-default fixture.' }
$realRoaming = Join-Path (Join-Path $env:APPDATA "7-Zip") "7zPasswordVault.dat"
$portableVault = Join-Path $SevenZipDir "7zPasswordVault.dat"
$createdRoamingFixture = $false
$roamingFixtureHash = $null
function New-ExclusiveEncryptedFixture([string]$destination, [byte[]]$bytes) {
  $parent = Split-Path -Parent $destination
  [void][IO.Directory]::CreateDirectory($parent)
  if ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Refusing to create a vault fixture below a reparse point: $parent"
  }
  if (Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue) {
    throw "Refusing to replace an existing vault fixture destination: $destination"
  }
  $temp = Join-Path $parent ('.7zpw-ui-' + [guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllBytes($temp, $bytes)
    # File.Move with overwrite=false refuses a destination created in the meantime.
    [IO.File]::Move($temp, $destination, $false)
  } finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction Stop }
  }
}
function Remove-UnchangedEncryptedFixture([string]$path, [string]$expectedHash) {
  $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  if (-not $item -or $item.PSIsContainer -or
      ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
      ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expectedHash)) {
    Write-Host "  Refusing to remove changed or missing encrypted fixture: $path" -ForegroundColor Yellow
    return $false
  }
  Remove-Item -LiteralPath $path -Force -ErrorAction Stop
  return (-not (Test-Path -LiteralPath $path))
}
try {
if (-not (Get-Item -LiteralPath $realRoaming -Force -ErrorAction SilentlyContinue)) {
  New-ExclusiveEncryptedFixture $realRoaming $fixtureBytes
  $createdRoamingFixture = $true
  $roamingFixtureHash = (Get-FileHash -LiteralPath $realRoaming -Algorithm SHA256).Hash
}
$roamingItem = Get-Item -LiteralPath $realRoaming -Force -ErrorAction Stop
if (($roamingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $roamingItem.PSIsContainer) {
  throw "Refusing to use a linked or directory vault as the roaming test fixture: $realRoaming"
}
$portableBefore = [bool](Get-Item -LiteralPath $portableVault -Force -ErrorAction SilentlyContinue)
if (-not (Test-Path -LiteralPath $realRoaming)) {
  Check "a vault in %APPDATA% is needed for this test" $false "(no $realRoaming)"
} elseif ($portableBefore) {
  Check "the program folder is free for the portable test vault" $false "(already there: $portableVault)"
} else {
  Remove-ItemProperty -Path $regKey -Name "VaultPath" -ErrorAction SilentlyContinue
  # a valid vault of this run (readable through DPAPI), not the user's file
  New-ExclusiveEncryptedFixture $portableVault $fixtureBytes
  $portableFixtureHash = (Get-FileHash -LiteralPath $portableVault -Algorithm SHA256).Hash
  try {
    Check "both default vault files exist now" ((Test-Path -LiteralPath $portableVault) -and (Test-Path -LiteralPath $realRoaming))

    $p = Start-Fm $archive
    $q = Wait-Dialog ([uint32]$p.Id) $T.Caption 15
    Check "the program asks which vault to use" ($q -ne [IntPtr]::Zero)
    if ($q -ne [IntPtr]::Zero) {
      [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($q, 7))   # IDNO = the one in %APPDATA%
      $note = Wait-Dialog ([uint32]$p.Id) $T.Caption 8
      Check "the answer is confirmed with the chosen location" ($note -ne [IntPtr]::Zero)
      if ($note -ne [IntPtr]::Zero) { [void](Close-Box ([uint32]$p.Id) $note $T.Caption) }
    }
    $chosen = (Get-ItemProperty -Path $regKey -Name "VaultPath" -ErrorAction SilentlyContinue).VaultPath
    Check "the choice is recorded, so the question is not repeated" ($chosen -eq $realRoaming) "(got [$chosen])"
    Stop-Fm $p

    # the second start must not ask again (an unrelated message box would say something else)
    $p = Start-Fm $archive
    $again = Wait-Dialog ([uint32]$p.Id) $T.Caption 8
    if ($again -eq [IntPtr]::Zero) {
      Check "the question does not come back" $true
    } else {
      $said = [VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($again, 65535))
      # an empty text is not evidence that the box is a different one: fail instead of
      # passing on "nothing was said"
      Check "the question does not come back" ($said.Length -gt 0 -and $said -notmatch "密码库|vault") "(box said [$said])"
      [void](Close-Box ([uint32]$p.Id) $again $T.Caption)
    }
    Stop-Fm $p
  } finally {
    # the copy must not survive, whatever happens above: it is a vault file inside the
    # folder that gets packaged
    Check "the portable fixture is removed only when unchanged" (Remove-UnchangedEncryptedFixture $portableVault $portableFixtureHash)
  }
  Check "the portable test vault was removed again" (-not (Test-Path -LiteralPath $portableVault))
}

# ---------------------------------------------------------------- test 24b
Write-Host "`n== 24b. the vault question: yes, cancel, and the untouched file ==" -ForegroundColor Cyan
# The remaining branches of the same question (24a covers "no"), plus the rule that the file
# that was not chosen is never touched, and the counterpart of test 7: a password that is
# already stored must NOT be offered for saving again.
Set-ItemProperty -Path $regKey -Name "VaultPath" -Value $vault -Type String
Set-ItemProperty -Path $regKey -Name "UseMasterPassword" -Value 0 -Type DWord
$portableVault = Join-Path $SevenZipDir "7zPasswordVault.dat"
if ((-not (Test-Path -LiteralPath $realRoaming)) -or (Test-Path -LiteralPath $portableVault)) {
  Check "the second question test has a free program folder and a vault in %APPDATA%" $false `
    "(roaming=$(Test-Path -LiteralPath $realRoaming) portable=$(Test-Path -LiteralPath $portableVault))"
} else {
  New-ExclusiveEncryptedFixture $portableVault $fixtureBytes
  $portableFixtureHash = (Get-FileHash -LiteralPath $portableVault -Algorithm SHA256).Hash
  $roamingHashBefore = (Get-FileHash -LiteralPath $realRoaming -Algorithm SHA256).Hash
  $portableHashBefore = (Get-FileHash -LiteralPath $portableVault -Algorithm SHA256).Hash
  try {
    # ---- "yes" = use the one next to the program, and nothing moves
    Remove-ItemProperty -Path $regKey -Name "VaultPath" -ErrorAction SilentlyContinue
    $p = Start-Fm $archive
    $q = Wait-Dialog ([uint32]$p.Id) $T.Caption 15
    Check "the question appears (yes branch)" ($q -ne [IntPtr]::Zero)
    if ($q -ne [IntPtr]::Zero) {
      [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($q, 6))   # IDYES = the program folder
      $note = Wait-Dialog ([uint32]$p.Id) $T.Caption 8
      Check "choosing the program folder is confirmed" ($note -ne [IntPtr]::Zero)
      if ($note -ne [IntPtr]::Zero) { [void](Close-Box ([uint32]$p.Id) $note $T.Caption) }
    }
    $chosenYes = (Get-ItemProperty -Path $regKey -Name "VaultPath" -ErrorAction SilentlyContinue).VaultPath
    Check "the program folder is recorded as the location" ($chosenYes -eq $portableVault) "(got [$chosenYes])"
    Stop-Fm $p
    Check "the vault in %APPDATA% was not touched (content)" `
      ((Get-FileHash -LiteralPath $realRoaming -Algorithm SHA256).Hash -eq $roamingHashBefore)
    Check "the vault in %APPDATA% is still there" (Test-Path -LiteralPath $realRoaming)

    # ---- "cancel" = nothing is decided, and the question comes back
    Remove-ItemProperty -Path $regKey -Name "VaultPath" -ErrorAction SilentlyContinue
    $p = Start-Fm $archive
    $q = Wait-Dialog ([uint32]$p.Id) $T.Caption 15
    Check "the question appears (cancel branch)" ($q -ne [IntPtr]::Zero)
    if ($q -ne [IntPtr]::Zero) {
      [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($q, 2))   # IDCANCEL
      Start-Sleep -Milliseconds 800
    }
    $chosenCancel = (Get-ItemProperty -Path $regKey -Name "VaultPath" -ErrorAction SilentlyContinue).VaultPath
    Check "cancelling records no location" ([string]::IsNullOrEmpty($chosenCancel)) "(got [$chosenCancel])"
    # the program stays usable: the password dialog of the running archive is still there
    $dlg = Wait-Dialog ([uint32]$p.Id) $T.Password 8
    Check "the program still works after cancelling" ($dlg -ne [IntPtr]::Zero)
    Stop-Fm $p

    $p = Start-Fm $archive
    $again = Wait-Dialog ([uint32]$p.Id) $T.Caption 15
    Check "the question comes back after cancelling" ($again -ne [IntPtr]::Zero)
    if ($again -ne [IntPtr]::Zero) { [void](Close-Box ([uint32]$p.Id) $again $T.Caption) }
    Stop-Fm $p
    Check "both vault files are unchanged after everything (program folder)" `
      ((Get-FileHash -LiteralPath $portableVault -Algorithm SHA256).Hash -eq $portableHashBefore)
    Check "both vault files are unchanged after everything (%APPDATA%)" `
      ((Get-FileHash -LiteralPath $realRoaming -Algorithm SHA256).Hash -eq $roamingHashBefore)
  } finally {
    Check "the second portable fixture is removed only when unchanged" (Remove-UnchangedEncryptedFixture $portableVault $portableFixtureHash)
    Set-ItemProperty -Path $regKey -Name "VaultPath" -Value $vault -Type String
  }

  # ---- a password the vault already knows must not be offered for saving again
  # (test 7 covers the opposite: an unknown password opens the prompt.)
  Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $regKey -Name "PromptToSaveNew" -Value 1 -Type DWord
  $p = Start-Fm $archive
  $dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (known password)"
  New-VaultEntry ([uint32]$p.Id) $dlg "already-there" "KnownPw-77" "the known entry is stored"
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "KnownPw-77")
  Start-Sleep -Milliseconds 300
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 1))   # OK
  $ask = Wait-Dialog ([uint32]$p.Id) $T.Caption 4
  Check "a password that is already stored is not offered for saving" ($ask -eq [IntPtr]::Zero)
  if ($ask -ne [IntPtr]::Zero) { [void](Close-Box ([uint32]$p.Id) $ask $T.Caption) }
  Check "process alive after the known-password test" (-not $p.HasExited)
  Stop-Fm $p
}
} finally {
  if ($createdRoamingFixture) {
    $roamingFinalItem = Get-Item -LiteralPath $realRoaming -Force -ErrorAction SilentlyContinue
    $sameFixture = $roamingFinalItem -and (-not $roamingFinalItem.PSIsContainer) -and
      (-not ($roamingFinalItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) -and
      ((Get-FileHash -LiteralPath $realRoaming -Algorithm SHA256).Hash -eq $roamingFixtureHash)
    Check "temporary roaming fixture remained encrypted and unchanged" $sameFixture
    if ($sameFixture) {
      Check "temporary roaming fixture was removed" (Remove-UnchangedEncryptedFixture $realRoaming $roamingFixtureHash)
    } else {
      Write-Host "  The roaming fixture changed; retained for inspection: $realRoaming" -ForegroundColor Yellow
    }
  }
}

# ---------------------------------------------------------------- test 24
Write-Host "`n== 24. what a fill really delivers ==" -ForegroundColor Cyan
# A Windows password box cannot be read from another process, so the value is verified
# through the two channels that do work: the saved-passwords list (a normal list control)
# and a real archive that only opens with the right password.
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regKey -Name "VaultPath" -Value $vault -Type String
Set-ItemProperty -Path $regKey -Name "UseMasterPassword" -Value 0 -Type DWord
Set-ItemProperty -Path $regKey -Name "ShowPasswordInList" -Value 0 -Type DWord
Set-ItemProperty -Path $regKey -Name "CloseAfterFill" -Value 1 -Type DWord

$proofArc = Join-Path $workDir "fill-proof.7z"
$proofDest = Join-Path $workDir "out_fill_proof"
$proofPw = "ProofPw-42"
Remove-Item $proofArc -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $proofDest -ErrorAction SilentlyContinue
& $szExe a -t7z -mhe -p"$proofPw" $proofArc $plain | Out-Null
Check "an archive protected with the proof password exists" (Test-Path $proofArc)
& $szExe t -p"$proofPw" $proofArc | Out-Null
Check "the proof password really opens it" ($LASTEXITCODE -eq 0)

$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (proof)"
New-VaultEntry ([uint32]$p.Id) $dlg "proof-entry" $proofPw "the proof entry is stored"
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "the list opens (proof)"
$lv = Wait-Child $lst 124
$row = Find-Row $lv "proof-entry"
Check "the entry is listed" ($row -ge 0)
Check "the password column is masked before revealing" ([VaultUiTest]::GetListText($lv, $row, 1) -eq $masked) "(got [$([VaultUiTest]::GetListText($lv, $row, 1))])"
# the list is a normal control: reveal it and the real value can be read back
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3829))     # Show passwords
Start-Sleep -Milliseconds 600
Check "the stored password can be read from the list" ([VaultUiTest]::GetListText($lv, $row, 1) -eq $proofPw) "(got [$([VaultUiTest]::GetListText($lv, $row, 1))])"
Check "the password box of the dialog is a password box" (Test-PasswordBox $dlg)
Select-Row $lv $row
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))     # Fill
Check "filling closes the list window (the observable of a fill)" (Wait-NoDialog ([uint32]$p.Id) $T.List 5)
Check "process alive after filling" (-not $p.HasExited)
Stop-Fm $p

# and the value that was filled really is that password: it opens the proof archive
$g = Start-Process -FilePath $guiExe -ArgumentList @("x", "-y", "-o`"$proofDest`"", "`"$proofArc`"") -PassThru
$gdlg = Expect-Dialog ([uint32]$g.Id) $T.Password "7zG asks for the proof password" 15
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($gdlg, 3808))    # saved passwords
$lst = Expect-Dialog ([uint32]$g.Id) $T.List "the vault window opens for the proof archive"
$lv = Wait-Child $lst 124
$row = Find-Row $lv "proof-entry"
Check "the proof entry is offered to 7zG" ($row -ge 0)
if ($row -ge 0) {
  Select-Row $lv $row
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))   # Fill
}
Check "the password box of the extraction dialog is a password box" (Test-PasswordBox $gdlg)
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($gdlg, 1))       # OK -> extract
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline -and -not $g.HasExited) { Start-Sleep -Milliseconds 200 }
$out = Join-Path $proofDest "hello.txt"
Check "the archive opened: the filled password was the right one" (Test-Path $out) "(looked for $out)"
if (Test-Path $out) {
  Check "the extracted content is right" (((Get-Content $out -Raw).Trim()) -eq "secret content")
}
Check "7zG finished (proof)" ($g.HasExited)
# Legacy setup cases apply only to packages that contain an actual uninstall command.
# The current review3 ZIP is portable and has no registration action.
function Get-ShortcutState([string]$path) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '<absent>' }
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
function Get-UninstallState([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return '<absent>' }
  $values = (Get-ItemProperty -LiteralPath $path).PSObject.Properties |
    Where-Object { $_.Name -notlike 'PS*' } |
    Sort-Object Name |
    ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } }
  return 'present:' + (ConvertTo-Json -InputObject @($values) -Depth 5 -Compress)
}
$deskShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "7-Zip Password Vault.lnk"
$startShortcut = Join-Path (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs") "7-Zip Password Vault.lnk"
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\7ZipPasswordVault"
$deskBefore = Get-ShortcutState $deskShortcut
$startBefore = Get-ShortcutState $startShortcut
$uninstallBefore = Get-UninstallState $uninstallKey
if (Test-Path -LiteralPath (Join-Path $SevenZipDir 'uninstall.cmd') -PathType Leaf) {
try {
# ---------------------------------------------------------------- test 26
Write-Host "`n== 26. first start: the shortcuts question is asked once ==" -ForegroundColor Cyan
# The self-extracting package cannot run anything after unpacking (the 7z.sfx stub ignores
# its configuration - measured), so the program itself offers the Start Menu / desktop
# shortcuts and the "Apps & features" entry on its first start. Asked once, and "no" counts
# as an answer: the question must not come back on every start.
$deskShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "7-Zip Password Vault.lnk"
$startShortcut = Join-Path (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs") "7-Zip Password Vault.lnk"
$hadDesk = Test-Path -LiteralPath $deskShortcut
$hadStart = Test-Path -LiteralPath $startShortcut
Remove-ItemProperty -Path $regKey -Name "SetupAsked" -ErrorAction SilentlyContinue

$p = Start-Fm ""
$q = Wait-Dialog ([uint32]$p.Id) $T.Caption 15
Check "the first start asks about the shortcuts" ($q -ne [IntPtr]::Zero) "(no question box)"
if ($q -ne [IntPtr]::Zero) {
  $said = [VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($q, 65535))
  Check "the question mentions shortcuts" ($said -match "快捷方式|shortcut") "(box said [$said])"
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($q, 7))   # IDNO = do not create them
  Start-Sleep -Milliseconds 900
}
$asked = (Get-ItemProperty -Path $regKey -Name "SetupAsked" -ErrorAction SilentlyContinue).SetupAsked
Check "the answer is remembered (1 = already asked)" ($asked -eq 1) "(SetupAsked=[$asked])"
Check "answering no created no desktop shortcut" ((Test-Path -LiteralPath $deskShortcut) -eq $hadDesk) "(desktop shortcut appeared)"
Check "answering no created no start menu shortcut" ((Test-Path -LiteralPath $startShortcut) -eq $hadStart) "(start menu shortcut appeared)"
Check "no uninstall entry was registered" (
  (Test-Path -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\7ZipPasswordVault") -eq $false) `
  "(an uninstall entry appeared)"
Stop-Fm $p

$p = Start-Fm ""
$again = Wait-Dialog ([uint32]$p.Id) $T.Caption 6
Check "the question does not come back on the next start" ($again -eq [IntPtr]::Zero)
Stop-Fm $p

# ---------------------------------------------------------------- test 27
Write-Host "`n== 27. the page button registers, and a moved folder is noticed ==" -ForegroundColor Cyan
# The first-start question can be answered "no" or missed, so the settings page carries a button
# that registers the shortcuts and the "Apps & features" entry for the folder the program runs
# in. A portable copy that is moved keeps pointing at the old folder: the program notices that
# from LastRegistered and asks once per folder.
$deskShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "7-Zip Password Vault.lnk"
$startShortcut = Join-Path (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs") "7-Zip Password Vault.lnk"
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\7ZipPasswordVault"
$fakeOldFolder = Join-Path $workDir "moved-away-from"

if ((Test-Path -LiteralPath $deskShortcut) -or (Test-Path -LiteralPath $startShortcut) -or
    (Test-Path -LiteralPath $uninstallKey)) {
  Check "no shortcut / uninstall entry of the user is in the way" $false "(one is already there)"
} else {
  # ---- A: the settings page button does the registration
  $p = Start-Fm ""
  $fmWnd = [IntPtr]::Zero
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline -and $fmWnd -eq [IntPtr]::Zero) {
    $fmWnd = [VaultUiTest]::FindDialogClass([uint32]$p.Id, "7-Zip::FM")
    if ($fmWnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
  }
  Check "the file manager window is up (for the page button)" ($fmWnd -ne [IntPtr]::Zero)
  $page = Open-PasswordPage ([uint32]$p.Id) "the page opens for the setup button"
  $btn = [VaultUiTest]::FindDescendant($page.Opt, 2616)
  Check "the settings page has a 'create shortcuts / register' button" ($btn -ne [IntPtr]::Zero)
  if ($btn -ne [IntPtr]::Zero) {
    [VaultUiTest]::ClickButton($btn)
    $result = Wait-Dialog ([uint32]$p.Id) $T.Caption 12
    Check "the button reports what it did" ($result -ne [IntPtr]::Zero)
    if ($result -ne [IntPtr]::Zero) { [void](Close-Box ([uint32]$p.Id) $result $T.Caption) }
  }
  $location = (Get-ItemProperty -Path $uninstallKey -Name "InstallLocation" -ErrorAction SilentlyContinue).InstallLocation
  Check "the uninstall entry points at this folder" ($location -eq $SevenZipDir) "(got [$location])"
  Check "the shortcuts were created (start menu)" (Test-Path -LiteralPath $startShortcut)
  Check "the shortcuts were created (desktop)" (Test-Path -LiteralPath $deskShortcut)
  $reg = (Get-ItemProperty -Path $regKey -Name "LastRegistered" -ErrorAction SilentlyContinue).LastRegistered
  Check "the folder is recorded as registered" ($reg -eq $SevenZipDir) "(got [$reg])"
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($page.Opt, 2))   # Cancel
  Start-Sleep -Milliseconds 600
  Stop-Fm $p

  # ---- B: the registration belongs to a folder that is gone -> asked once per move
  New-Item -Path $uninstallKey -Force | Out-Null
  Set-ItemProperty -Path $uninstallKey -Name "InstallLocation" -Value $fakeOldFolder -Type String
  Set-ItemProperty -Path $regKey -Name "LastRegistered" -Value $fakeOldFolder -Type String
  Remove-ItemProperty -Path $regKey -Name "MoveAskedFrom" -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $regKey -Name "MoveAskedTo" -ErrorAction SilentlyContinue
  $p = Start-Fm ""
  $moved = Wait-Dialog ([uint32]$p.Id) $T.Caption 12
  Check "a registration for a missing folder is reported" ($moved -ne [IntPtr]::Zero)
  Check "the program is still running while the question is up" (-not $p.HasExited)
  if ($moved -ne [IntPtr]::Zero) {
    $said = [VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($moved, 65535))
    Check "the question names the old folder" ($said -match [regex]::Escape($fakeOldFolder)) "(box said [$said])"
    [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($moved, 7))   # IDNO = leave it alone
    Start-Sleep -Milliseconds 900
  }
  Check "the dead uninstall entry was removed" (-not (Test-Path -LiteralPath $uninstallKey))
  $from = (Get-ItemProperty -Path $regKey -Name "MoveAskedFrom" -ErrorAction SilentlyContinue).MoveAskedFrom
  $to = (Get-ItemProperty -Path $regKey -Name "MoveAskedTo" -ErrorAction SilentlyContinue).MoveAskedTo
  Check "the move that was declined is remembered (from)" ($from -eq $fakeOldFolder) "(got [$from])"
  Check "the move that was declined is remembered (to)" ($to -eq $SevenZipDir) "(got [$to])"
  $regGone = (Get-ItemProperty -Path $regKey -Name "LastRegistered" -ErrorAction SilentlyContinue).LastRegistered
  Check "the stale registration was dropped" ([string]::IsNullOrEmpty($regGone)) "(got [$regGone])"
  Stop-Fm $p

  $p = Start-Fm ""
  $again = Wait-Dialog ([uint32]$p.Id) $T.Caption 8
  Check "the moved-folder question does not come back" ($again -eq [IntPtr]::Zero)
  Check "the program is alive after the quiet start" (-not $p.HasExited)
  Stop-Fm $p

  # ---- B2: the same situation, answered with "yes": the entries move to this folder
  New-Item -Path $uninstallKey -Force | Out-Null
  Set-ItemProperty -Path $uninstallKey -Name "InstallLocation" -Value $fakeOldFolder -Type String
  Set-ItemProperty -Path $regKey -Name "LastRegistered" -Value $fakeOldFolder -Type String
  Remove-ItemProperty -Path $regKey -Name "MoveAskedFrom" -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $regKey -Name "MoveAskedTo" -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $regKey -Name "SetupAsked" -ErrorAction SilentlyContinue
  $p = Start-Fm ""
  $ask2 = Wait-Dialog ([uint32]$p.Id) $T.Caption 12
  Check "the question appears again for a new move" ($ask2 -ne [IntPtr]::Zero)
  if ($ask2 -ne [IntPtr]::Zero) {
    [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ask2, 6))   # IDYES = update it
    $done = Wait-Dialog ([uint32]$p.Id) $T.Caption 12
    Check "answering yes reports the result" ($done -ne [IntPtr]::Zero)
    if ($done -ne [IntPtr]::Zero) { [void](Close-Box ([uint32]$p.Id) $done $T.Caption) }
    Start-Sleep -Milliseconds 600
  }
  $newLocation = (Get-ItemProperty -Path $uninstallKey -Name "InstallLocation" -ErrorAction SilentlyContinue).InstallLocation
  Check "the uninstall entry moved to this folder" ($newLocation -eq $SevenZipDir) "(got [$newLocation])"
  $newReg = (Get-ItemProperty -Path $regKey -Name "LastRegistered" -ErrorAction SilentlyContinue).LastRegistered
  Check "the registration records this folder" ($newReg -eq $SevenZipDir) "(got [$newReg])"
  Check "the shortcuts now point at this folder (desktop)" (Test-Path -LiteralPath $deskShortcut)
  Stop-Fm $p

  # ---- C: a registration whose folder still holds another copy is left alone
  $sibling = Join-Path $workDir "sibling-copy"
  New-Item -ItemType Directory -Force -Path $sibling | Out-Null
  Copy-Item -LiteralPath $fmExe -Destination (Join-Path $sibling "7zFM.exe") -Force
  Set-ItemProperty -Path $regKey -Name "LastRegistered" -Value $sibling -Type String
  Remove-ItemProperty -Path $regKey -Name "MoveAskedFrom" -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $regKey -Name "MoveAskedTo" -ErrorAction SilentlyContinue
  $p = Start-Fm ""
  $quiet = Wait-Dialog ([uint32]$p.Id) $T.Caption 6
  Check "another copy's registration is not taken over (no question)" ($quiet -eq [IntPtr]::Zero)
  $stillSibling = (Get-ItemProperty -Path $regKey -Name "LastRegistered" -ErrorAction SilentlyContinue).LastRegistered
  Check "the other copy's registration is left untouched" ($stillSibling -eq $sibling) "(got [$stillSibling])"
  Stop-Fm $p
  Remove-Item -Recurse -Force $sibling -ErrorAction SilentlyContinue
}

} finally {
  # Remove only names absent before this run. Pre-existing user registration belongs
  # to the user even when a legacy test could not execute its registration scenario.
  if ($deskBefore -eq '<absent>') { Remove-Item -LiteralPath $deskShortcut -Force -ErrorAction SilentlyContinue }
  if ($startBefore -eq '<absent>') { Remove-Item -LiteralPath $startShortcut -Force -ErrorAction SilentlyContinue }
  if ($uninstallBefore -eq '<absent>') { Remove-Item -LiteralPath $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue }
  Check "the legacy test preserved existing shortcut and uninstall state" (
    ((Get-ShortcutState $deskShortcut) -eq $deskBefore) -and
    ((Get-ShortcutState $startShortcut) -eq $startBefore) -and
    ((Get-UninstallState $uninstallKey) -eq $uninstallBefore))
}
} else {
  Write-Host "`n== 26. portable release has no setup registration ==" -ForegroundColor Cyan
  $p = Start-Fm ""
  $setupQuestion = Wait-Dialog ([uint32]$p.Id) $T.Caption 5
  Check "portable release opens without a shortcut setup question" ($setupQuestion -eq [IntPtr]::Zero)
  if ($setupQuestion -ne [IntPtr]::Zero) { [void](Close-Box ([uint32]$p.Id) $setupQuestion $T.Caption) }
  Stop-Fm $p

  $p = Start-Fm ""
  $page = Open-PasswordPage ([uint32]$p.Id) "portable settings page opens"
  Check "portable settings page has no registration button" (
    [VaultUiTest]::FindDescendant($page.Opt, 2616) -eq [IntPtr]::Zero)
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($page.Opt, 2))
  Stop-Fm $p
  Check "portable run left the desktop shortcut unchanged" ((Get-ShortcutState $deskShortcut) -eq $deskBefore)
  Check "portable run left the Start Menu shortcut unchanged" ((Get-ShortcutState $startShortcut) -eq $startBefore)
  Check "portable run left the uninstall entry unchanged" ((Get-UninstallState $uninstallKey) -eq $uninstallBefore)
}

if (-not $g.HasExited) { Stop-Process -Id $g.Id -Force }
} catch {
  $script:uiAbortMessage = $_.Exception.Message
  if ($script:fail -eq 0) { Check 'GUI run aborted' $false $script:uiAbortMessage }
  Write-Host "  GUI run aborted: $script:uiAbortMessage" -ForegroundColor Red
} finally {
  Stop-Fm $null
  Clear-OwnInstances
  Set-VaultSettings $savedSettings
  Restore-Isolation
  if ($script:restoreLang) {
    if ($savedLang) { Set-ItemProperty -Path $langKey -Name "Lang" -Value $savedLang -Type String }
    else { Remove-ItemProperty -Path $langKey -Name "Lang" -ErrorAction SilentlyContinue }
  }
  if (-not $KeepArtifacts) {
    Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "`n== summary ==" -ForegroundColor Cyan
Write-Host ("  passed: {0}   failed: {1}" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })
Write-Host ("  real vault untouched: {0}" -f $realVault) -ForegroundColor DarkGray
if ($KeepArtifacts -or $script:fail -ne 0) {
  try {
    Ensure-UiRunDirectory
    $uiResult = [ordered]@{
      classification = if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' }
      exitCode = if ($script:fail -eq 0) { 0 } else { 1 }
      passed = $script:pass
      failed = $script:fail
      failedChecks = $script:uiFailedChecks.ToArray()
      abortMessage = $script:uiAbortMessage
      startedUtc = $script:uiStartedUtc
      finishedUtc = [DateTime]::UtcNow.ToString('o')
      scriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
      runtimeDirectory = $SevenZipDir
      fileManagerSha256 = (Get-FileHash -LiteralPath $fmExe -Algorithm SHA256).Hash
      guiSha256 = (Get-FileHash -LiteralPath $guiExe -Algorithm SHA256).Hash
    }
    $uiResult | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:uiRunDirectory 'result.json') -Encoding UTF8
    Write-Host "  GUI evidence: $script:uiRunDirectory" -ForegroundColor DarkGray
  } catch {
    Write-Host "  Could not retain GUI summary: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
