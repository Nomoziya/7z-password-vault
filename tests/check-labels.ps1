# check-labels.ps1 - finds labels whose text does not fit into its control.
#
# This is how the clipped English labels in the "Add to archive" dialog were
# found: for every control of every dialog the program shows, the text width is
# measured with the control's own font and compared with the control's width.
# It is the cheap way to check a translation before shipping it.
#
# Usage:
#   pwsh -File tests\check-labels.ps1                     # English
#   pwsh -File tests\check-labels.ps1 -UiLang zh-cn
#   pwsh -File tests\check-labels.ps1 -SevenZipDir "D:\path\to\7-Zip"
#
# Exits non-zero when any label is clipped.

param(
  [string]$SevenZipDir = '',
  [ValidateSet("en", "zh-cn", "zh-tw")][string]$UiLang = "en"
)
# temporary: measure every control text of every dialog of a process (finds clipped labels)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'runtime-input.ps1')
$SevenZipDir=Resolve-TestRuntime -Directory $SevenZipDir
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
using System.Collections.Generic;
public class Meas2 {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
  [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
  [DllImport("gdi32.dll", CharSet=CharSet.Unicode)] public static extern bool GetTextExtentPoint32W(IntPtr dc, string s, int len, out SIZE sz);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr lp);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
  [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx, cy; }

  public static IntPtr FindClass(uint pid, string cls) {
    IntPtr r = IntPtr.Zero;
    EnumWindows((h,l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid) return true;
      var c = new StringBuilder(64); GetClassNameW(h, c, 64);
      if (c.ToString() == cls) { r = h; return false; } return true; }, IntPtr.Zero);
    return r; }
  public static string[] DialogTitles(uint pid) {
    var list = new List<string>();
    EnumWindows((h,l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid) return true;
      var c = new StringBuilder(64); GetClassNameW(h, c, 64);
      if (c.ToString() != "#32770") return true;
      var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
      list.Add(h.ToString() + "|" + t.ToString());
      return true; }, IntPtr.Zero);
    return list.ToArray(); }
  public static IntPtr[] Dialogs(uint pid) {
    var list = new List<IntPtr>();
    EnumWindows((h,l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid) return true;
      var c = new StringBuilder(64); GetClassNameW(h, c, 64);
      if (c.ToString() == "#32770") list.Add(h);
      return true; }, IntPtr.Zero);
    return list.ToArray(); }
  public static IntPtr Desc(IntPtr parent, int id) {
    IntPtr r = IntPtr.Zero;
    EnumChildWindows(parent, (h,l) => { if (GetDlgCtrlID(h) == id) { r = h; return false; } return true; }, IntPtr.Zero);
    return r; }
  [DllImport("user32.dll", EntryPoint="SendMessageW", CharSet=CharSet.Unicode)] public static extern IntPtr SendStr(IntPtr h, uint m, string s);
  public static void Set(IntPtr h, string s) { SendStr(h, 0x000C, s); }
  public static void Click(IntPtr h) { PostMessageW(h, 0x00F5, IntPtr.Zero, IntPtr.Zero); }
  public static void Foreground(IntPtr h) {
    IntPtr root = GetAncestor(h, 2); if (root == IntPtr.Zero) root = h;
    for (int i = 0; i < 40 && GetForegroundWindow() != root; i++) { SetForegroundWindow(root); System.Threading.Thread.Sleep(50); } }
  public static string MouseClickTab(IntPtr tab, int index) {
    uint pid; GetWindowThreadProcessId(tab, out pid);
    IntPtr h = OpenProcess(0x38, false, (int)pid);
    if (h == IntPtr.Zero) return "no process";
    IntPtr remote = VirtualAllocEx(h, IntPtr.Zero, (IntPtr)16, 0x3000, 0x04);
    IntPtr local = Marshal_Alloc(16);
    IntPtr w; WriteProcessMemory(h, remote, local, (IntPtr)16, out w);
    SendMessageW(tab, 0x130A, (IntPtr)index, remote);   /* TCM_GETITEMRECT */
    byte[] buf = new byte[16]; IntPtr got;
    ReadProcessMemory(h, remote, buf, (IntPtr)16, out got);
    Marshal_Free(local); VirtualFreeEx(h, remote, IntPtr.Zero, 0x8000); CloseHandle(h);
    int l = BitConverter.ToInt32(buf,0), t = BitConverter.ToInt32(buf,4);
    int r = BitConverter.ToInt32(buf,8), b = BitConverter.ToInt32(buf,12);
    if (r <= l) return "empty rect";
    POINT pt; pt.x = (l+r)/2; pt.y = (t+b)/2; ClientToScreen(tab, ref pt);
    Foreground(tab);
    SetCursorPos(pt.x, pt.y); System.Threading.Thread.Sleep(150);
    mouse_event(0x0002,0,0,0,IntPtr.Zero); mouse_event(0x0004,0,0,0,IntPtr.Zero);
    return "clicked " + pt.x + "," + pt.y; }
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool i, int p);
  [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr a, IntPtr s, uint t, uint p);
  [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr h, IntPtr a, IntPtr b, IntPtr s, out IntPtr w);
  [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr a, byte[] b, IntPtr s, out IntPtr r);
  [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr h, IntPtr a, IntPtr s, uint t);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  static IntPtr Marshal_Alloc(int n) { return System.Runtime.InteropServices.Marshal.AllocHGlobal(n); }
  static void Marshal_Free(IntPtr p) { System.Runtime.InteropServices.Marshal.FreeHGlobal(p); }

  public static string[] Measure(IntPtr dlg) {
    var res = new List<string>();
    IntPtr screenDc = GetDC(IntPtr.Zero);
    IntPtr memDc = CreateCompatibleDC(screenDc);
    EnumChildWindows(dlg, (h,l) => {
      var cls = new StringBuilder(64); GetClassNameW(h, cls, 64);
      var txt = new StringBuilder(512); GetWindowTextW(h, txt, 512);
      string text = txt.ToString(); string klass = cls.ToString();
      if (text.Length == 0) return true;
      if (klass == "SysListView32" || klass == "SysHeader32" || klass == "ComboBox" || klass == "SysTabControl32") return true;
      RECT rc; if (!GetClientRect(h, out rc)) return true;
      int w = rc.right - rc.left;
      int hgt = rc.bottom - rc.top;
      IntPtr font = SendMessageW(h, 0x0031, IntPtr.Zero, IntPtr.Zero);
      IntPtr old = IntPtr.Zero;
      if (font != IntPtr.Zero) old = SelectObject(memDc, font);
      SIZE sz; GetTextExtentPoint32W(memDc, text, text.Length, out sz);
      SIZE line; GetTextExtentPoint32W(memDc, "Ag", 2, out line);
      int pad = (klass == "Button") ? 10 : 2;
      int avail = w - pad;
      if (avail < 1) avail = 1;
      int lineHeight = line.cy > 0 ? line.cy : 16;
      // A label that is too long for one line is only clipped when there is no room to
      // wrap it: the message boxes grow downwards, so a long path in a dialog is not a
      // defect. Measure per paragraph, because those texts contain line breaks.
      int linesNeeded = 0;
      foreach (string paragraph in text.Split('\n')) {
        string p = paragraph.TrimEnd('\r');
        SIZE ps; GetTextExtentPoint32W(memDc, p, p.Length, out ps);
        linesNeeded += (ps.cx <= avail) ? 1 : ((ps.cx + avail - 1) / avail);
      }
      if (font != IntPtr.Zero) SelectObject(memDc, old);
      int linesAvailable = hgt / lineHeight;
      if (linesAvailable < 1) linesAvailable = 1;
      if (linesNeeded > linesAvailable)
        res.Add(string.Format("id={0,-5} {1,-11} rect={2,-5} need={3,-5} lines={4}/{5} | {6}",
          GetDlgCtrlID(h), klass, w, sz.cx, linesNeeded, linesAvailable, text));
      return true;
    }, IntPtr.Zero);
    DeleteDC(memDc); ReleaseDC(IntPtr.Zero, screenDc);
    return res.ToArray(); }
}
"@
[void][Meas2]::SetProcessDPIAware()

$fm = Join-Path $SevenZipDir "7zFM.exe"
$gz = Join-Path $SevenZipDir "7zG.exe"
if (!(Test-Path $fm) -or !(Test-Path $gz)) {
  Write-Host "ERROR: 7zFM.exe / 7zG.exe not found in '$SevenZipDir'" -ForegroundColor Red
  exit 2
}
$work = Join-Path $env:TEMP "7zpw_meas"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$arch = Join-Path $env:TEMP "7zpw_test\enc.7z"
if (!(Test-Path $arch)) {
  Write-Host "ERROR: $arch is missing - run tests\ui-test.ps1 once to create the test archive" -ForegroundColor Red
  exit 2
}

# The dialogs are measured in the language the program will actually use, so the
# setting is applied first and restored afterwards, even on failure.
$langKey = "HKCU:\Software\7-Zip"
$savedLang = (Get-ItemProperty -Path $langKey -Name Lang -ErrorAction SilentlyContinue).Lang
Set-ItemProperty -Path $langKey -Name "Lang" -Value $UiLang -Type String

# A vault location has to be set as well: without one the program uses its default
# location and - because a vault still sits in %APPDATA%\7-Zip - MOVES that file next to
# the program. That is the program's documented behaviour, but a measuring tool must not
# touch the user's vault. The path points into %TEMP% and is restored afterwards.
$vaultKey = Join-Path $langKey "PasswordVault"
$savedVaultPath = $null
$haveVaultPath = $false
$savedSetupAsked = $null
if (Test-Path -LiteralPath $vaultKey) {
  $existing = (Get-ItemProperty -Path $vaultKey -Name VaultPath -ErrorAction SilentlyContinue).VaultPath
  if ($null -ne $existing) { $savedVaultPath = $existing; $haveVaultPath = $true }
  $savedSetupAsked = (Get-ItemProperty -Path $vaultKey -Name SetupAsked -ErrorAction SilentlyContinue).SetupAsked
}
try {
  New-Item -Path $vaultKey -Force | Out-Null
  Set-ItemProperty -Path $vaultKey -Name VaultPath -Value (Join-Path $work "measure-vault.dat") -Type String
  # the first-start question ("create shortcuts?") would sit in front of every dialog this
  # tool measures, so it is answered up front as well
  Set-ItemProperty -Path $vaultKey -Name SetupAsked -Value 1 -Type DWord
} catch {
  Write-Host ("  setting a temporary vault location failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
  Write-Host "  (the program may move the real vault - close other 7-Zip windows first)" -ForegroundColor Yellow
  exit 3
}
try {

$script:clipped = 0
function MeasureAll([string]$label, [uint32]$procId) {
  $found = $false
  foreach ($d in [Meas2]::Dialogs($procId)) {
    $t = New-Object System.Text.StringBuilder 512
    [void][Meas2]::GetWindowTextW($d, $t, 512)
    if ($t.Length -eq 0) { continue }
    $r = [Meas2]::Measure($d)
    if ($r.Count -gt 0) {
      $found = $true
      $script:clipped += $r.Count
      Write-Host "  [$($t.ToString())]" -ForegroundColor Yellow
      $r | ForEach-Object { Write-Host "    CLIPPED  $_" -ForegroundColor Red }
    }
  }
  if (-not $found) { Write-Host "  $label : nothing clipped" -ForegroundColor Green }
}

# --- 7zG: add-to-archive dialog (the two vault buttons) + extract password dialog
$cp = Start-Process $gz -ArgumentList @("a","-ad","-t7z","`"$work\c.7z`"","`"$env:TEMP\7zpw_test\hello.txt`"") -PassThru
Start-Sleep -Seconds 5
Write-Host "`n=== 7zG dialogs ===" -ForegroundColor Cyan
[Meas2]::DialogTitles([uint32]$cp.Id) | ForEach-Object { "  dialog: $_" }
MeasureAll "7zG" ([uint32]$cp.Id)

# also the extraction password dialog of 7zG (same vault buttons)
Get-Process 7zG -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600
$gp = Start-Process $gz -ArgumentList @("x","-y","-o`"$work\out`"","`"$arch`"") -PassThru
Start-Sleep -Seconds 6
MeasureAll "7zG extract" ([uint32]$gp.Id)
Get-Process 7zG -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600

# --- 7zFM: password dialog, list window, edit dialog, options page
$p = Start-Process $fm -ArgumentList "`"$arch`"" -PassThru
Start-Sleep -Seconds 6
$dlg = [Meas2]::FindClass([uint32]$p.Id, "#32770")
Write-Host "`n=== 7zFM dialogs ===" -ForegroundColor Cyan
[Meas2]::DialogTitles([uint32]$p.Id) | ForEach-Object { "  dialog: $_" }
# open the list window (button 3808)
$main = [IntPtr]::Zero
foreach ($d in [Meas2]::Dialogs([uint32]$p.Id)) { if ([Meas2]::Desc($d, 3808) -ne [IntPtr]::Zero) { $main = $d; break } }
if ($main -ne [IntPtr]::Zero) {
  [Meas2]::Foreground($main)
  [Meas2]::Click([Meas2]::Desc($main, 3808))
  Start-Sleep -Seconds 2
}
MeasureAll "7zFM" ([uint32]$p.Id)
Get-Process 7zFM -ErrorAction SilentlyContinue | Stop-Process -Force

# --- options page (password tab)
$p = Start-Process $fm -PassThru
Start-Sleep -Seconds 4
$fmw = [Meas2]::FindClass([uint32]$p.Id, "7-Zip::FM")
[void][Meas2]::PostMessageW($fmw, 0x0111, [IntPtr]900, [IntPtr]::Zero)
Start-Sleep -Seconds 3
$opt = [IntPtr]::Zero
foreach ($d in [Meas2]::Dialogs([uint32]$p.Id)) { if ([Meas2]::Desc($d, 12320) -ne [IntPtr]::Zero) { $opt = $d; break } }
if ($opt -ne [IntPtr]::Zero) {
  $tab = [Meas2]::Desc($opt, 12320)
  [Meas2]::Foreground($opt)
  $done = $false
  for ($i = 0; $i -lt 9 -and -not $done; $i++) {
    [void][Meas2]::MouseClickTab($tab, $i)
    Start-Sleep -Milliseconds 600
    if ([Meas2]::Desc($opt, 2601) -ne [IntPtr]::Zero) { $done = $true }
  }
  Write-Host "`n=== 7zFM options, password page (reached: $done) ===" -ForegroundColor Cyan
  # measure only the password page controls
  $r = [Meas2]::Measure($opt)
  $ids = @(2601,2602,2603,2604,2605,2606,2607,2608,2609,2610,2611,2612,2613,2614,2615,2616)
  $shown = 0
  foreach ($line in $r) {
    if ($line -match 'id=(\d+)') { if ($ids -contains [int]$Matches[1]) { Write-Host "    CLIPPED  $line" -ForegroundColor Red; $shown++ } }
  }
  if ($shown -eq 0) { Write-Host "  password page: nothing clipped" -ForegroundColor Green } else { $script:clipped += $shown }
} else { Write-Host "options dialog not found" }
Get-Process 7zFM -ErrorAction SilentlyContinue | Stop-Process -Force

} finally {
  Get-Process 7zFM,7zG -ErrorAction SilentlyContinue | Stop-Process -Force
  if ($savedLang) { Set-ItemProperty -Path $langKey -Name "Lang" -Value $savedLang -Type String }
  else { Remove-ItemProperty -Path $langKey -Name "Lang" -ErrorAction SilentlyContinue }
  if ($haveVaultPath) { Set-ItemProperty -Path $vaultKey -Name VaultPath -Value $savedVaultPath -Type String }
  else { Remove-ItemProperty -Path $vaultKey -Name VaultPath -ErrorAction SilentlyContinue }
  # the shortcut question must be left unanswered again for the user, or their first start
  # would silently skip it
  if ($savedSetupAsked) { Set-ItemProperty -Path $vaultKey -Name SetupAsked -Value $savedSetupAsked -Type DWord }
  else { Remove-ItemProperty -Path $vaultKey -Name SetupAsked -ErrorAction SilentlyContinue }
  Remove-Item -Force (Join-Path $work "measure-vault.dat") -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:clipped -eq 0) {
  Write-Host ("  no clipped labels in language '{0}'" -f $UiLang) -ForegroundColor Green
  exit 0
}
Write-Host ("  {0} clipped label(s) in language '{1}'" -f $script:clipped, $UiLang) -ForegroundColor Red
exit 1
