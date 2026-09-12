# ui-test.ps1 - UI smoke test for the 7-Zip password vault integration.
#
# It drives the real dialogs of 7zFM.exe through Win32 messages / notifications,
# so it does not need any test framework.
#
# Usage:
#   pwsh -File tests\ui-test.ps1
#   pwsh -File tests\ui-test.ps1 -SevenZipDir "D:\path\to\7-Zip"
#
# The default target is the packaged build in ..\7-Zip-密码管家版 .

param(
  [string]$SevenZipDir = (Join-Path (Split-Path $PSScriptRoot -Parent) "7-Zip-密码管家版"),
  [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$fmExe = Join-Path $SevenZipDir "7zFM.exe"
$szExe = Join-Path $SevenZipDir "7z.exe"
if (!(Test-Path $fmExe) -or !(Test-Path $szExe)) {
  Write-Host "ERROR: 7zFM.exe / 7z.exe not found in '$SevenZipDir'" -ForegroundColor Red
  exit 2
}

$vault     = Join-Path $env:APPDATA "7-Zip\7zPasswordVault.dat"
$workDir   = Join-Path $env:TEMP "7zpw_test"
$archive   = Join-Path $workDir "enc.7z"
$regKey    = "HKCU:\Software\7-Zip\PasswordVault"

$script:pass = 0
$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$extra = "") {
  if ($ok) { $script:pass++; Write-Host ("  [PASS] " + $name) -ForegroundColor Green }
  else     { $script:fail++; Write-Host ("  [FAIL] " + $name + " " + $extra) -ForegroundColor Red }
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

  /* Writing the NMITEMACTIVATE into the TARGET process is required: WM_NOTIFY
     carries a pointer, which is not marshalled across processes. */
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr addr, IntPtr size, uint type, uint protect);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool VirtualFreeEx(IntPtr h, IntPtr addr, IntPtr size, uint type);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, IntPtr buf, IntPtr size, out IntPtr written);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

  [StructLayout(LayoutKind.Sequential)] public struct NMHDR { public IntPtr hwndFrom; public IntPtr idFrom; public uint code; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  [StructLayout(LayoutKind.Sequential)] public struct NMITEMACTIVATE {
    public NMHDR hdr; public int iItem; public int iSubItem;
    public uint uNewState; public uint uOldState; public uint uChanged;
    public POINT ptAction; public IntPtr lParam; public uint uKeyFlags; }

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

  /* --- real mouse input (a WM_NOTIFY cannot be faked across processes) --- */
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, IntPtr extra);

  /* The app is per-monitor DPI aware. A DPI-unaware test process would report the
     dialog in virtualized (scaled-down) coordinates while SetCursorPos works in
     physical pixels, so at 150% scaling every click would land 1.5x too far right
     and hit the next column. Becoming DPI aware makes both spaces identical. */
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);

  /* Clicks the centre of cell (row 0, column `col`) of a report-mode list view.
     Column centres come from the real column widths, never from constants.
     A first click on the (non-sortable) header activates the window: the click
     that activates a background window is consumed by Windows, so without it the
     real click would be swallowed. */
  public static void ClickListCell(IntPtr listHwnd, int col, bool doubleClick) {
    ClickListCell(listHwnd, col, doubleClick, false);
  }
  public static void ClickListCell(IntPtr listHwnd, int col, bool doubleClick, bool rightButton) {
    RECT lr, hr;
    GetWindowRect(listHwnd, out lr);
    IntPtr header = Send(listHwnd, 0x101F /*LVM_GETHEADER*/, IntPtr.Zero, IntPtr.Zero);
    if (header == IntPtr.Zero) return;
    GetWindowRect(header, out hr);

    /* sum the widths of the preceding columns to reach column `col` */
    int offset = 0;
    for (int c = 0; c < col; c++)
      offset += (int)Send(listHwnd, 0x101D /*LVM_GETCOLUMNWIDTH*/, (IntPtr)c, IntPtr.Zero);
    int width = (int)Send(listHwnd, 0x101D, (IntPtr)col, IntPtr.Zero);
    if (width <= 0) width = 50;

    int x = lr.left + 1 + offset + width / 2;
    int y = hr.bottom + 8;

    SetForegroundWindow(listHwnd);
    System.Threading.Thread.Sleep(200);

    /* activation click on the header (no action is bound to it) */
    SetCursorPos(lr.left + 100, hr.top + 5);
    System.Threading.Thread.Sleep(80);
    mouse_event(0x0002, 0, 0, 0, IntPtr.Zero);
    mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
    System.Threading.Thread.Sleep(250);

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
}
"@

# Must run before any coordinate is read or written (see ClickListCell).
[void][VaultUiTest]::SetProcessDPIAware()

$NM_CLICK  = [uint32]4294967294   # (UINT)-2
$NM_DBLCLK = [uint32]4294967293   # (UINT)-3

function Start-Fm([string]$arg) {
  if ($arg) { return Start-Process -FilePath $fmExe -ArgumentList "`"$arg`"" -PassThru }
  return Start-Process -FilePath $fmExe -PassThru
}
function Stop-Fm($p) {
  if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
  Get-Process 7zFM -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 400
}

Write-Host "== setup ==" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$plain = Join-Path $workDir "hello.txt"
Set-Content -Path $plain -Value "secret content" -Encoding UTF8
Remove-Item $archive -Force -ErrorAction SilentlyContinue
& $szExe a -p"ArchivePw" -mhe $archive $plain | Out-Null
Check "test archive created" (Test-Path $archive)

New-Item -Path $regKey -Force | Out-Null
Set-ItemProperty -Path $regKey -Name "UseMasterPassword"   -Value 0 -Type DWord
Set-ItemProperty -Path $regKey -Name "AutoTypeByName"      -Value 1 -Type DWord
Set-ItemProperty -Path $regKey -Name "PromptToSaveNew"     -Value 1 -Type DWord
Set-ItemProperty -Path $regKey -Name "EditByRightClick"    -Value 0 -Type DWord
Remove-Item $vault -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- test 1
Write-Host "`n== 1. save a named password ==" -ForegroundColor Cyan
$p = Start-Fm $archive
Start-Sleep -Seconds 5
$dlg = [VaultUiTest]::FindDialog([uint32]$p.Id, "输入密码")
Check "password dialog appears" ($dlg -ne [IntPtr]::Zero)

$btnNew  = [VaultUiTest]::FindDescendant($dlg, 3809)
$btnList = [VaultUiTest]::FindDescendant($dlg, 3808)
Check "main dialog has 'new password' button" ($btnNew -ne [IntPtr]::Zero)
Check "main dialog has 'saved passwords' button" ($btnList -ne [IntPtr]::Zero)

[VaultUiTest]::ClickButton($btnNew)
Start-Sleep -Seconds 2
$ed = [VaultUiTest]::FindDialog([uint32]$p.Id, "新建密码")
Check "new-password dialog appears" ($ed -ne [IntPtr]::Zero)
if ($ed -ne [IntPtr]::Zero) {
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), "我的密码")
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), "Secret123")
  Start-Sleep -Milliseconds 300
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
  Start-Sleep -Seconds 2
}
Check "vault file created" (Test-Path $vault)
if (Test-Path $vault) {
  $b = [IO.File]::ReadAllBytes($vault)
  Check "vault format version 3" ($b[4] -eq 3) "(got $($b[4]))"
  Check "DPAPI mode flag" ($b[5] -eq 0)
}
Check "password typed into input box" ([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($dlg,120)) -eq "Secret123")
Check "process still alive" (-not $p.HasExited)

# ---------------------------------------------------------------- test 2
Write-Host "`n== 2. list window: pick / double-click edit ==" -ForegroundColor Cyan
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "")
Start-Sleep -Milliseconds 200
[VaultUiTest]::ClickButton($btnList)
Start-Sleep -Seconds 2
$lst = [VaultUiTest]::FindDialog([uint32]$p.Id, "已保存的密码")
Check "saved passwords window appears" ($lst -ne [IntPtr]::Zero)
if ($lst -ne [IntPtr]::Zero) {
  $lv = [VaultUiTest]::FindDescendant($lst, 124)
  Check "list has 1 row" ([VaultUiTest]::SendLong($lv, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero) -eq 1)

  [VaultUiTest]::ClickListCell($lv, 1, $false)          # click the Password cell
  Start-Sleep -Milliseconds 800
  Check "single click fills the input box" ([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($dlg,120)) -eq "Secret123")

  [VaultUiTest]::ClickListCell($lv, 0, $true)           # double click the Name cell
  Start-Sleep -Seconds 2
  $ed2 = [VaultUiTest]::FindDialog([uint32]$p.Id, "编辑密码")
  Check "double click opens the edit dialog" ($ed2 -ne [IntPtr]::Zero)
  if ($ed2 -ne [IntPtr]::Zero) {
    Check "edit dialog prefilled with the name" ([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($ed2,121)) -eq "我的密码")
    # The password field is an ES_PASSWORD edit and Windows refuses to read it
    # from another process, so the prefill is verified by behaviour instead:
    # rename the entry, leave the password field untouched and press OK. A
    # missing prefill would save an empty password, which the check below
    # (single click must still fill "Secret123") then detects.
    [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed2,121), "改过名的")
    Start-Sleep -Milliseconds 300
    [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed2, 1))   # OK
    Start-Sleep -Seconds 2
    $lst2 = [VaultUiTest]::FindDialog([uint32]$p.Id, "已保存的密码")
    $lv = [VaultUiTest]::FindDescendant($lst2, 124)
    $hint = [VaultUiTest]::FindDescendant($lst2, 3816)
    [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "")
    Start-Sleep -Milliseconds 200
    [VaultUiTest]::ClickListCell($lv, 1, $false)          # click the Password cell again
    Start-Sleep -Milliseconds 800
    Check "edited entry kept its password (prefill worked)" ([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($dlg,120)) -eq "Secret123")
    Check "edit dialog saved the new name" ([VaultUiTest]::GetEditText($hint) -eq "已填入：改过名的") "(hint=[$([VaultUiTest]::GetEditText($hint))])"
  }
  Check "process alive after list interactions" (-not $p.HasExited)
}

# ---------------------------------------------------------------- test 3
Write-Host "`n== 3. delete from the Delete column ==" -ForegroundColor Cyan
if ($lst -ne [IntPtr]::Zero) {
  $sizeBefore = if (Test-Path $vault) { (Get-Item $vault).Length } else { 0 }
  [VaultUiTest]::ClickListCell($lv, 2, $false)          # click the Delete cell
  Start-Sleep -Seconds 2
  $cf = [VaultUiTest]::FindDialog([uint32]$p.Id, "7-Zip 密码管家")
  Check "delete asks for confirmation" ($cf -ne [IntPtr]::Zero)
  if ($cf -ne [IntPtr]::Zero) {
    [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($cf, 6))  # IDYES
    Start-Sleep -Seconds 2
  }
  $lv = [VaultUiTest]::FindDescendant($lst, 124)
  Check "row removed from the list" ([VaultUiTest]::SendLong($lv, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero) -eq 0)
  if (Test-Path $vault) {
    Check "vault file shrank after delete" ((Get-Item $vault).Length -lt $sizeBefore) "(was $sizeBefore)"
  }
  Check "process alive after delete" (-not $p.HasExited)
}
Stop-Fm $p

# ---------------------------------------------------------------- test 4
Write-Host "`n== 4. auto-type a saved password by typing its name ==" -ForegroundColor Cyan
Remove-Item $vault -Force -ErrorAction SilentlyContinue
$p = Start-Fm $archive
Start-Sleep -Seconds 5
$dlg = [VaultUiTest]::FindDialog([uint32]$p.Id, "输入密码")
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
Start-Sleep -Seconds 2
$ed = [VaultUiTest]::FindDialog([uint32]$p.Id, "新建密码")
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
$cases = @{
  "random garbage"   = [byte[]](1..64)
  "unsupported ver"  = [byte[]](0x37,0x5A,0x50,0x56,99,0)
  "truncated"        = [byte[]](0x37,0x5A,0x50,0x56,3,0,1,0,0,0)
}
foreach ($k in $cases.Keys) {
  Remove-Item $vault -Force -ErrorAction SilentlyContinue
  [IO.File]::WriteAllBytes($vault, $cases[$k])
  $p = Start-Fm $archive
  Start-Sleep -Seconds 5
  $err = [VaultUiTest]::FindDialog([uint32]$p.Id, "7-Zip 密码管家")
  if ($err -ne [IntPtr]::Zero) { [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($err,1)); Start-Sleep -Seconds 1 }
  $pw = [VaultUiTest]::FindDialog([uint32]$p.Id, "输入密码")
  Check "$k -> error shown, dialog usable, no crash" (($err -ne [IntPtr]::Zero) -and ($pw -ne [IntPtr]::Zero) -and (-not $p.HasExited))
  Stop-Fm $p
}

# ---------------------------------------------------------------- test 6
Write-Host "`n== 6. unnamed entry / right-click edit mode ==" -ForegroundColor Cyan
Remove-Item $vault -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regKey -Name "EditByRightClick" -Value 1 -Type DWord
$p = Start-Fm $archive
Start-Sleep -Seconds 5
$dlg = [VaultUiTest]::FindDialog([uint32]$p.Id, "输入密码")

# "New password" with an empty name: a name must be generated for the user
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3809))
Start-Sleep -Seconds 2
$ed = [VaultUiTest]::FindDialog([uint32]$p.Id, "新建密码")
Check "new-password dialog appears without a name" ($ed -ne [IntPtr]::Zero)
if ($ed -ne [IntPtr]::Zero) {
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 122), "AutoNamed")
  Start-Sleep -Milliseconds 300
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
  Start-Sleep -Seconds 2
}
Check "unnamed entry still fills the input box" ([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($dlg,120)) -eq "AutoNamed")

[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "")
Start-Sleep -Milliseconds 200
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 3808))
Start-Sleep -Seconds 2
$lst = [VaultUiTest]::FindDialog([uint32]$p.Id, "已保存的密码")
$lv = [VaultUiTest]::FindDescendant($lst, 124)
if ($lv -ne [IntPtr]::Zero) {
  $name0 = [VaultUiTest]::GetListText($lv, 0, 0)
  Check "unnamed entry got a generated name" ($name0 -eq "未命名 1") "(got [$name0])"

  # with EditByRightClick=1 a right click must edit ...
  [VaultUiTest]::ClickListCell($lv, 0, $false, $true)
  Start-Sleep -Seconds 2
  $ed3 = [VaultUiTest]::FindDialog([uint32]$p.Id, "编辑密码")
  Check "right click opens the edit dialog (setting on)" ($ed3 -ne [IntPtr]::Zero)
  if ($ed3 -ne [IntPtr]::Zero) {
    [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed3, 2))   # Cancel
    Start-Sleep -Seconds 1
  }
  # ... and a double click must not
  [VaultUiTest]::ClickListCell($lv, 1, $true)
  Start-Sleep -Seconds 2
  Check "double click does not edit when the setting is on" ([VaultUiTest]::FindDialog([uint32]$p.Id, "编辑密码") -eq [IntPtr]::Zero)
  # ... but it still types the password into the input box
  Check "double click still fills the input box" ([VaultUiTest]::GetEditText([VaultUiTest]::FindDescendant($dlg,120)) -eq "AutoNamed")
  Check "process alive after right-click mode" (-not $p.HasExited)
}
Stop-Fm $p

# ---------------------------------------------------------------- test 7
Write-Host "`n== 7. unknown password is offered for saving ==" -ForegroundColor Cyan
Remove-Item $vault -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regKey -Name "EditByRightClick"    -Value 0 -Type DWord
Set-ItemProperty -Path $regKey -Name "PromptToSaveNew"     -Value 1 -Type DWord
$p = Start-Fm $archive
Start-Sleep -Seconds 5
$dlg = [VaultUiTest]::FindDialog([uint32]$p.Id, "输入密码")
# a password the vault does not know: pressing OK must offer to store it
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "BrandNewPw")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 1))   # OK
Start-Sleep -Seconds 2
$ask = [VaultUiTest]::FindDialog([uint32]$p.Id, "7-Zip 密码管家")
Check "unknown password asks whether to save it" ($ask -ne [IntPtr]::Zero)
if ($ask -ne [IntPtr]::Zero) {
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ask, 6))   # IDYES
  Start-Sleep -Seconds 2
}
$ed = [VaultUiTest]::FindDialog([uint32]$p.Id, "新建密码")
Check "saving an unknown password opens the name dialog" ($ed -ne [IntPtr]::Zero)
if ($ed -ne [IntPtr]::Zero) {
  [VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($ed, 121), "from-prompt")
  Start-Sleep -Milliseconds 300
  [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($ed, 1))
  Start-Sleep -Seconds 2
}
$b = if (Test-Path $vault) { [IO.File]::ReadAllBytes($vault) } else { @() }
Check "vault holds the newly saved password" ($b.Length -gt 0)
Check "process alive" (-not $p.HasExited)
Stop-Fm $p

# ---------------------------------------------------------------- test 8
Write-Host "`n== 8. the offer can be switched off ==" -ForegroundColor Cyan
Remove-Item $vault -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regKey -Name "PromptToSaveNew" -Value 0 -Type DWord
$p = Start-Fm $archive
Start-Sleep -Seconds 5
$dlg = [VaultUiTest]::FindDialog([uint32]$p.Id, "输入密码")
[VaultUiTest]::SetEditText([VaultUiTest]::FindDescendant($dlg,120), "SilentPw")
Start-Sleep -Milliseconds 300
[VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($dlg, 1))
Start-Sleep -Seconds 2
Check "no offer when the setting is off" ([VaultUiTest]::FindDialog([uint32]$p.Id, "7-Zip 密码管家") -eq [IntPtr]::Zero)
Check "no vault file is written" (-not (Test-Path $vault))
Check "process alive" (-not $p.HasExited)
Stop-Fm $p

# ---------------------------------------------------------------- test 9
Write-Host "`n== 9. settings page ==" -ForegroundColor Cyan
$p = Start-Process -FilePath $fmExe -PassThru
Start-Sleep -Seconds 4
$fmWnd = [VaultUiTest]::FindDialogClass([uint32]$p.Id, "7-Zip::FM")
Check "file manager window found" ($fmWnd -ne [IntPtr]::Zero)
if ($fmWnd -ne [IntPtr]::Zero) {
  [void][VaultUiTest]::PostMessageW($fmWnd, 0x0111, [IntPtr]900, [IntPtr]::Zero)   # WM_COMMAND IDM_OPTIONS
  Start-Sleep -Seconds 3
  $opt = [VaultUiTest]::FindDialog([uint32]$p.Id, "选项")
  Check "options dialog opens" ($opt -ne [IntPtr]::Zero)
  if ($opt -ne [IntPtr]::Zero) {
    $tab = [VaultUiTest]::FindDescendant($opt, 12320)
    $count = if ($tab -ne [IntPtr]::Zero) { [VaultUiTest]::GetTabCount($tab) } else { 0 }
    $titles = @()
    for ($i = 0; $i -lt $count; $i++) { $titles += [VaultUiTest]::GetTabText($tab, $i) }
    Check "password page is registered" ($titles -contains "密码管理") "(tabs: $($titles -join ' | '))"
    $idx = [array]::IndexOf($titles, "密码管理")
    if ($idx -ge 0) {
      [VaultUiTest]::MoveCursorHome()
      [void][VaultUiTest]::ClickTab($tab, $idx)
      Start-Sleep -Seconds 2
      $ids = @(2602,2603,2604,2605,2606,2607,2608,2609,2610,2611,2612,2613)
      $missing = @()
      foreach ($id in $ids) {
        if ([VaultUiTest]::FindDescendant($opt, $id) -eq [IntPtr]::Zero) { $missing += $id }
      }
      $vis = [VaultUiTest]::FindDescendant($opt, 2601)
      if ($vis -eq [IntPtr]::Zero) { $missing += 2601 }
      Check "password page controls present" ($missing.Count -eq 0) "(missing: $($missing -join ','))"
      $lbl = if ($vis -ne [IntPtr]::Zero) { [VaultUiTest]::GetEditText($vis) } else { "" }
      Check "password page is localized" ($lbl -eq "密码库位置（留空使用默认）：") "(got [$lbl])"
      [VaultUiTest]::ClickButton([VaultUiTest]::FindDescendant($opt, 2))   # Cancel
      Start-Sleep -Seconds 1
    }
  }
  Check "process alive after settings" (-not $p.HasExited)
}
Stop-Fm $p

Write-Host "`n== summary ==" -ForegroundColor Cyan
Write-Host ("  passed: {0}   failed: {1}" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { "Green" } else { "Red" })

if (-not $KeepArtifacts) {
  Remove-Item $vault -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $env:APPDATA "7-Zip\7zPasswordVault.dat.tmp") -Force -ErrorAction SilentlyContinue
}
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
