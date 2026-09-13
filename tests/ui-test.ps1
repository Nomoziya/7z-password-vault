# ui-test.ps1 - UI smoke test for the 7-Zip password vault integration.
#
# It drives the real dialogs of 7zFM.exe through Win32 messages and real mouse
# input, so it does not need any test framework.
#
# The test never touches the real vault: it points the VaultPath setting at a
# file inside its own work directory and restores the whole PasswordVault
# registry key when it finishes (also when it fails).
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
# The default target is the packaged build in ..\7-Zip-密码管家版 .

param(
  [string]$SevenZipDir = (Join-Path (Split-Path $PSScriptRoot -Parent) "7-Zip-密码管家版"),
  [ValidateSet("auto", "zh-cn", "en")][string]$UiLang = "auto",
  [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
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
function Check([string]$name, [bool]$ok, [string]$extra = "") {
  if ($ok) { $script:pass++; Write-Host ("  [PASS] " + $name) -ForegroundColor Green }
  else     { $script:fail++; Write-Host ("  [FAIL] " + $name + " " + $extra) -ForegroundColor Red }
}

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
  public static string GetEditText(IntPtr h) { var sb = new StringBuilder(512); SendBuf(h, 0x000D, (IntPtr)512, sb); return sb.ToString(); }
  public static void SetEditText(IntPtr h, string s) { SendStr(h, 0x000C, IntPtr.Zero, s); }
  public static void ClickButton(IntPtr h) { PostMessageW(h, 0x00F5, IntPtr.Zero, IntPtr.Zero); }
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
    /* Three kinds of file dialog show up here, so all three name-box controls are
       tried: 7-Zip's own IDD_BROWSE (path edit 102), the modern shell dialog (file
       name edit 1001) and the classic dialog (file name box 1148, which is a combo
       whose inner edit carries the id). */
    IntPtr edit = IntPtr.Zero;
    var deadline = DateTime.UtcNow.AddSeconds(10);
    while (true) {
      edit = FindDescendant(dlg, 102 /* IDE_BROWSE_PATH */);
      if (edit == IntPtr.Zero) edit = FindChildByClassAndId(dlg, "Edit", 1001);
      if (edit == IntPtr.Zero) edit = FindChildByClassAndId(dlg, "Edit", 1148);
      if (edit != IntPtr.Zero) break;
      if (DateTime.UtcNow >= deadline) return false;
      System.Threading.Thread.Sleep(100);
    }
    ClickControl(edit);
    SetEditText(edit, fullPath);
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
  if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
  Start-Sleep -Milliseconds 400
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
Write-Host ("  UI language: {0}{1}" -f $UiLang, $(if ($script:restoreLang) { " (forced through HKCU\Software\7-Zip\Lang)" } else { "" })) -ForegroundColor DarkGray

# ---------------------------------------------------------------- test 1
Write-Host "`n== 1. save a named password ==" -ForegroundColor Cyan
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears"

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
  Check "vault format version 3" ($b[4] -eq 3) "(got $($b[4]))"
  Check "DPAPI mode flag" ($b[5] -eq 0)
}
Check "password typed into input box" ([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($dlg,120)) -eq "Secret123")
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
$filled = Wait-EditText ([VaultUiTest]::FindDescendant($dlg,120)) "Secret123"
Check "the Fill action types the password into the box" ($filled -eq "Secret123") "(edit=[$filled])"
Check "the window closes after filling by default" (Wait-NoDialog ([uint32]$p.Id) $T.List 5)

# A double click anywhere on the row fills it in as well
[VaultUiTest]::ClickButton($btnList)
$lst = Expect-Dialog ([uint32]$p.Id) $T.List "the window opens for the double-click test"
$lv = Wait-Child $lst 124
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "")
Start-Sleep -Milliseconds 200
[VaultUiTest]::ClickListCell($lv, 0, $true)           # double click the name cell
Check "double clicking the row fills the input box" ((Wait-EditText ([VaultUiTest]::FindDescendant($dlg,120)) "Secret123") -eq "Secret123")

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
$filled = Wait-EditText ([VaultUiTest]::FindDescendant($dlg,120)) "Secret123"
Check "edited entry kept its password (prefill worked)" ($filled -eq "Secret123") "(edit=[$filled])"
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
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
$ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog appears (auto-type)"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), "abc")
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), "PwForAbc")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
Start-Sleep -Seconds 2
# now type the saved name into the password box -> AutoTypeByName should replace it
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "abc")
Start-Sleep -Seconds 1
Check "typing a saved name auto-fills its password" ([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($dlg,120)) -eq "PwForAbc")
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
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
$ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog appears"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), "AutoNamed")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
Start-Sleep -Seconds 2
Check "unnamed entry still fills the input box" ([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($dlg,120)) -eq "AutoNamed")

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
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
$ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "a second unnamed entry can be created"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), "SecondUnnamed")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
Start-Sleep -Seconds 2
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
Check "row 0 still has the first password" ((Wait-EditText $pwEdit "AutoNamed") -eq "AutoNamed") "(edit=[$([VaultUiTest]::GetEditText($pwEdit))])"
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "the list window reopens to fill the second entry"
$lv = Wait-Child $lst 124
[VaultUiTest]::SetEditText($pwEdit, "")
Start-Sleep -Milliseconds 200
[void](Wait-Rows $lv 2 5)                                 # rows must exist before clicking one
Select-Row $lv 1
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
Check "row 1 still has the second password" ((Wait-EditText $pwEdit "SecondUnnamed") -eq "SecondUnnamed") "(edit=[$([VaultUiTest]::GetEditText($pwEdit))])"
Check "process alive after unnamed entries" (-not $p.HasExited)
Stop-Fm $p

# ---------------------------------------------------------------- test 6b
Write-Host "`n== 6b. the window can be kept open after filling ==" -ForegroundColor Cyan
Remove-Item $vault,$vaultTmp -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regKey -Name "CloseAfterFill" -Value 0 -Type DWord
$p = Start-Fm $archive
$dlg = Expect-Dialog ([uint32]$p.Id) $T.Password "password dialog appears (close-after-fill off)"
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
$ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog appears"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), "stayopen")
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), "PwStayOpen")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
Start-Sleep -Seconds 2
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "")
Start-Sleep -Milliseconds 200
$lst = Open-List ([uint32]$p.Id) ([VaultUiTest]::FindDescendant($dlg, 3808)) $T.List "saved passwords window appears"
$lv = Wait-Child $lst 124
Select-Row $lv 0   # Fill
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
Check "filling still works with the setting off" ((Wait-EditText ([VaultUiTest]::FindDescendant($dlg,120)) "PwStayOpen") -eq "PwStayOpen")
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
Check "clicking Fill on a masked row types the real password" ((Wait-EditText ([VaultUiTest]::FindDescendant($dlg,120)) "BrandNewPw") -eq "BrandNewPw")
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
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
$ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog appears"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), "cs")
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), "PwForCs")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
Start-Sleep -Seconds 2
$pwEdit = [VaultUiTest]::FindDescendant($dlg,120)

# typing continues: the intermediate "cs" must not trigger a fill
[VaultUiTest]::SetEditText($pwEdit, "cs")
[VaultUiTest]::SetEditText($pwEdit, "cspass123")
Start-Sleep -Milliseconds 1500
$text = [VaultUiTest]::GetEditText($pwEdit)
Check "a password that starts with a saved name is left alone" ($text -eq "cspass123") "(got [$text])"

# and the feature itself still works once typing has stopped
[VaultUiTest]::SetEditText($pwEdit, "")
Start-Sleep -Milliseconds 200
[VaultUiTest]::SetEditText($pwEdit, "cs")
$text = Wait-EditText $pwEdit "PwForCs" 4
Check "the saved name still fills in after a typing pause" ($text -eq "PwForCs") "(got [$text])"
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
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($cd, 3809))
  $ed = Expect-Dialog ([uint32]$g.Id) $T.NewPassword "new-password dialog opens from the compress dialog"
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), "compress-entry")
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), "PwForCompress")
  Start-Sleep -Milliseconds 300
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
  Start-Sleep -Seconds 2
  Check "the compress dialog got the new password" ((Wait-EditText ([VaultUiTest]::FindDescendant($cd,120)) "PwForCompress") -eq "PwForCompress")
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
  Check "the password is typed into the compress dialog" ((Wait-EditText ([VaultUiTest]::FindDescendant($cd,120)) "PwForCompress") -eq "PwForCompress")
  # the second password field is kept in step, so the archive can be created
  Check "the reenter-password field was filled too" ((Wait-EditText ([VaultUiTest]::FindDescendant($cd,121)) "PwForCompress") -eq "PwForCompress")
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
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
  $ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog appears ($($names[$i]))"
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), $names[$i])
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), $pws[$i])
  Start-Sleep -Milliseconds 250
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
  Start-Sleep -Milliseconds 700
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
  $got = Wait-EditText $pwEdit $pws[$i] 4
  Check "row $i fills its own password" ($got -eq $pws[$i]) "(row $i -> [$got])"
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
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
  $ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog appears ($($pair[0]))"
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), $pair[0])
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), $pair[1])
  Start-Sleep -Milliseconds 250
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
  Start-Sleep -Milliseconds 700
}
$pwEdit = [VaultUiTest]::FindDescendant($dlg,120)
[VaultUiTest]::SetEditText($pwEdit, "")
Start-Sleep -Milliseconds 200
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3808))
$lst = Expect-Dialog ([uint32]$p.Id) $T.List "the saved-passwords window appears"
$lv = Wait-Child $lst 124
Select-Row $lv 0   # Fill row 0 ("cs" -> "secret1")
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
$got = Wait-EditText $pwEdit "secret1" 4
Check "filling row 0 typed its password" ($got -eq "secret1") "(got [$got])"
Start-Sleep -Milliseconds 1500                        # longer than the auto-type delay
$after = [VaultUiTest]::GetEditText($pwEdit)
Check "the filled password was not replaced by the entry named like it" ($after -eq "secret1") "(got [$after])"
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
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
  $ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog appears (awkward name)"
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), $c.in)
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), $c.pw)
  Start-Sleep -Milliseconds 250
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
  Start-Sleep -Milliseconds 700
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
Check "the long-named entry still fills its password" ((Wait-EditText $pwEdit "Pw-Long" 4) -eq "Pw-Long")
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
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
$ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog stores the archive password"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), "the-archive")
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), "ArchivePw")
Start-Sleep -Milliseconds 250
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
Start-Sleep -Seconds 1
Stop-Fm $p

$g = Start-Process -FilePath $guiExe -ArgumentList @("x", "-y", "-o`"$dest`"", "`"$archive`"") -PassThru
$gdlg = Expect-Dialog ([uint32]$g.Id) $T.Password "7zG asks for the archive password" 15
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($gdlg, 3808))     # saved passwords
$lst = Expect-Dialog ([uint32]$g.Id) $T.List "the vault window opens from 7zG"
$lv = Wait-Child $lst 124
Check "the archive password is in the vault" ([VaultUiTest]::GetListText($lv, 0, 0) -eq "the-archive") "(row0=[$([VaultUiTest]::GetListText($lv, 0, 0))])"
Select-Row $lv 0   # Fill (closes the window)
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($lst, 3831))
Check "the password landed in the extraction dialog" ((Wait-EditText ([VaultUiTest]::FindDescendant($gdlg,120)) "ArchivePw") -eq "ArchivePw")
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
Check "the compress dialog received the stored password" ((Wait-EditText ([VaultUiTest]::FindDescendant($cd,120)) "GuiMadePw") -eq "GuiMadePw")
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($cd, 1))          # OK -> create the archive
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline -and -not (Test-Path $madeArc)) { Start-Sleep -Milliseconds 200 }
Check "the archive was created through the dialog" (Test-Path $madeArc)
if (-not $g.HasExited) { Stop-Process -Id $g.Id -Force }
if (Test-Path $madeArc) {
  $szExe = Join-Path $SevenZipDir "7z.exe"
  # the password must be the one from the vault: test with it, and prove it is needed
  $null = & $szExe t "-pGuiMadePw" $madeArc 2>&1
  Check "the archive opens with the vault password" ($LASTEXITCODE -eq 0)
  $null = & $szExe t $madeArc 2>&1
  Check "the archive is really encrypted (no password fails)" ($LASTEXITCODE -ne 0)
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
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
$ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog appears in master mode"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), "master-entry")
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), "PwInMasterMode")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
Start-Sleep -Seconds 2
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
Check "filling works in master mode" ((Wait-EditText ([VaultUiTest]::FindDescendant($dlg,120)) "PwInMasterMode") -eq "PwInMasterMode")
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
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
$ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog appears (named entry)"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), "showme")
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), "PwNamed")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
Start-Sleep -Seconds 2
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
$ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog appears (unnamed entry)"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), "PwUnnamed")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
Start-Sleep -Seconds 2
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
Check "the revealed unnamed entry still fills" ((Wait-EditText ([VaultUiTest]::FindDescendant($dlg,120)) "PwUnnamed") -eq "PwUnnamed") "(edit=[$([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($dlg,120)))])"
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
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
$ed = Expect-Dialog ([uint32]$p.Id) $T.NewPassword "new-password dialog appears (Chinese entry)"
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), $cnName)
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), $cnPw)
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
Start-Sleep -Seconds 1
$pwEdit = [VaultUiTest]::FindDescendant($dlg, 120)
Check "the Chinese password reached the input box" ((Wait-EditText $pwEdit $cnPw) -eq $cnPw) "(got [$([VaultUiTest]::GetEditText($pwEdit))])"

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
  Check "the Chinese password is filled from the list" ((Wait-EditText $pwEdit $cnPw) -eq $cnPw) "(got [$([VaultUiTest]::GetEditText($pwEdit))])"
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
  Check "the Chinese password landed in the extraction dialog" ((Wait-EditText ([VaultUiTest]::FindDescendant($gdlg,120)) $cnPw) -eq $cnPw) "(got [$([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($gdlg,120)))])"
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
$p = Start-Fm $archive
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
    Check "the moved vault fills the right password" ((Wait-EditText $pwEdit $portPw) -eq $portPw) "(got [$([VaultUiTest]::GetEditText($pwEdit))])"
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
Set-ItemProperty -Path $regKey -Name "UseMasterPassword"      -Value 0 -Type DWord
Set-ItemProperty -Path $regKey -Name "RememberMasterPassword" -Value 0 -Type DWord
} finally {
  Stop-Fm $null
  Set-VaultSettings $savedSettings
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
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
