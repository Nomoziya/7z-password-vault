param(
  [Parameter(Mandatory = $true)][string]$NativeTestExe
)

$ErrorActionPreference = 'Stop'
$testRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'b')).TrimEnd('\')
$run = Join-Path $testRoot ('real-disk-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run -ErrorAction Stop | Out-Null
$vhd = Join-Path $run 'isolated-full-volume.vhd'
$diskpartScript = Join-Path $run 'diskpart-create.txt'
$diskpartCleanup = Join-Path $run 'diskpart-detach.txt'
$diskpartLog = Join-Path $run 'diskpart.log'
$record = [ordered]@{
  startedUtc = [DateTime]::UtcNow.ToString('o')
  classification = 'NOT_RUN'
  nativeTestExe = $null
  nativeTestExeSha256 = $null
  isolatedVhd = $vhd
  fixedMaximumMiB = 96
  driveLetter = $null
  availableBytesBeforeFill = $null
  fillerBytesWritten = 0
  minimumWriteBlockBytesTried = $null
  fillWin32Error = $null
  fillFailurePhase = $null
  fillErrorMessage = $null
  seedExitCode = $null
  seedVaultBytes = $null
  diskFailureExitCode = $null
  diskFailureLog = (Join-Path $run 'disk-failure.log')
  cleanup = 'NOT_RUN'
}
$volumeMounted = $false
$phase = 'prerequisite'

try {
  if (-not ('VaultNativeDiskFill' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class VaultDiskFillResult {
  public long BytesWritten;
  public int SmallestBlockBytesTried;
  public int Win32Error;
  public string Phase;
}

public static class VaultNativeDiskFill {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
      IntPtr security, uint creation, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool WriteFile(SafeFileHandle file, byte[] buffer, uint count,
      out uint written, IntPtr overlapped);
  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool FlushFileBuffers(SafeFileHandle file);

  public static VaultDiskFillResult FillUntilFull(string path) {
    VaultDiskFillResult result = new VaultDiskFillResult();
    using (SafeFileHandle file = CreateFileW(path, 0x40000000, 0, IntPtr.Zero, 1, 0x80, IntPtr.Zero)) {
      if (file.IsInvalid) {
        result.Phase = "CreateFileW";
        result.Win32Error = Marshal.GetLastWin32Error();
        return result;
      }
      int[] blockSizes = new int[] { 1024 * 1024, 64 * 1024, 4096, 512 };
      long nextFlush = 16L * 1024 * 1024;
      for (int sizeIndex = 0; sizeIndex < blockSizes.Length; sizeIndex++) {
        byte[] buffer = new byte[blockSizes[sizeIndex]];
        result.SmallestBlockBytesTried = blockSizes[sizeIndex];
        while (true) {
          uint written;
          bool ok = WriteFile(file, buffer, (uint)buffer.Length, out written, IntPtr.Zero);
          result.BytesWritten += written;
          if (!ok) {
            int error = Marshal.GetLastWin32Error();
            if ((error == 39 || error == 112) && sizeIndex + 1 < blockSizes.Length)
              break; // Retry with smaller writes to consume the final allocatable clusters.
            result.Phase = "WriteFile";
            result.Win32Error = error;
            if (!FlushFileBuffers(file)) {
              int flushError = Marshal.GetLastWin32Error();
              if (flushError != 0) {
                result.Phase = "FlushFileBuffers";
                result.Win32Error = flushError;
              }
            }
            return result;
          }
          if (written == 0) {
            result.Phase = "WriteFileNoProgress";
            return result;
          }
          if (result.BytesWritten >= nextFlush) {
            if (!FlushFileBuffers(file)) {
              result.Phase = "FlushFileBuffers";
              result.Win32Error = Marshal.GetLastWin32Error();
              return result;
            }
            nextFlush = result.BytesWritten + 16L * 1024 * 1024;
          }
        }
      }
      result.Phase = "WriteFileUnexpectedEnd";
      return result;
    }
  }
}
'@ -ErrorAction Stop
  }

  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $record.classification = 'ENVIRONMENT_BLOCKED'
    throw 'An elevated administrator session is required to create and attach a disposable VHD. No volume was modified.'
  }
  $diskpart = (Get-Command diskpart.exe -ErrorAction Stop).Source
  $native = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $NativeTestExe -ErrorAction Stop).Path)
  $nativeBase = $testRoot.TrimEnd('\') + '\'
  if (-not $native.StartsWith($nativeBase, [StringComparison]::OrdinalIgnoreCase) -or
      [IO.Path]::GetFileName($native) -ne 'vault-native-test.exe' -or
      [IO.Path]::GetFileName((Split-Path $native -Parent)) -notmatch '^native-run-[a-f0-9]{32}$') {
    throw 'Native test EXE must be the freshly built executable under tests\b\native-run-<GUID>.'
  }
  $result = Get-Item -LiteralPath $native -Force
  if ($result.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Native test EXE is a reparse point.' }
  $record.nativeTestExe = $native
  $record.nativeTestExeSha256 = (Get-FileHash -LiteralPath $native -Algorithm SHA256).Hash

  $occupied = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
    if ($drive.Name -match '^[A-Z]$') { [void]$occupied.Add($drive.Name) }
  }
  $letter = $null
  foreach ($candidate in @('Z','Y','X','W','V','U','T','S','R','Q','P','O','N','M','L','K','J','I','H','G','F','E')) {
    if (-not $occupied.Contains($candidate) -and -not (Test-Path -LiteralPath ($candidate + ':\'))) { $letter = $candidate; break }
  }
  if (-not $letter) { throw 'No unused drive letter is available for the isolated VHD.' }
  $record.driveLetter = $letter

  $phase = 'vhd-provision'
  @(
    "create vdisk file=`"$vhd`" maximum=$($record.fixedMaximumMiB) type=fixed"
    "select vdisk file=`"$vhd`""
    'attach vdisk'
    'create partition primary'
    'format fs=ntfs quick label=VaultFaultTest'
    "assign letter=$letter"
    'exit'
  ) | Set-Content -LiteralPath $diskpartScript -Encoding ASCII
  $dpOutput = & $diskpart /s $diskpartScript 2>&1
  $dpExit = $LASTEXITCODE
  $dpOutput | Set-Content -LiteralPath $diskpartLog -Encoding UTF8
  if ($dpExit -ne 0 -or -not (Test-Path -LiteralPath ($letter + ':\'))) {
    $record.classification = 'PROVISION_FAILURE'
    throw "DiskPart could not create, format, and attach the disposable test VHD (exit=$dpExit). See $diskpartLog."
  }
  $volumeMounted = $true

  $phase = 'seed-vault'
  $vaultPath = "$letter`:\7zPasswordVault.dat"
  & $native disk-seed $vaultPath 2>&1 | Tee-Object -FilePath (Join-Path $run 'seed.log')
  $seedExit = $LASTEXITCODE
  $record.seedExitCode = $seedExit
  if ($seedExit -ne 0) { throw "Could not seed the encrypted vault on the isolated volume (exit=$seedExit)." }
  $record.seedVaultBytes = (Get-Item -LiteralPath $vaultPath -Force).Length
  if ($record.seedVaultBytes -lt 65536) {
    throw "Encrypted seed is only $($record.seedVaultBytes) bytes; it must exceed the NTFS resident-data range before filling the test volume."
  }

  $drive = [IO.DriveInfo]::new("$letter`:\")
  $record.availableBytesBeforeFill = $drive.AvailableFreeSpace
  $fillPath = "$letter`:\controlled-filler.bin"
  $fillResult = [VaultNativeDiskFill]::FillUntilFull($fillPath)
  $record.fillerBytesWritten = $fillResult.BytesWritten
  $record.minimumWriteBlockBytesTried = $fillResult.SmallestBlockBytesTried
  $record.fillWin32Error = $fillResult.Win32Error
  $record.fillFailurePhase = $fillResult.Phase
  if ($fillResult.Win32Error) {
    $record.fillErrorMessage = [ComponentModel.Win32Exception]::new($fillResult.Win32Error).Message
  }
  # Windows may report ERROR_DISK_FULL (112) or ERROR_HANDLE_DISK_FULL (39).
  # Read the native result directly; a managed exception HRESULT's low word is
  # not a Win32 error code.
  $fullCode = $fillResult.Win32Error -in @(39, 112)
  $writeExhausted = $fillResult.Phase -eq 'WriteFile' -and $fillResult.SmallestBlockBytesTried -eq 512
  $flushExhausted = $fillResult.Phase -eq 'FlushFileBuffers'
  if (-not $fullCode -or (-not $writeExhausted -and -not $flushExhausted)) {
    throw "Filling the isolated volume failed at $($fillResult.Phase), block=$($fillResult.SmallestBlockBytesTried), native Win32=$($fillResult.Win32Error) ($($record.fillErrorMessage)); expected ERROR_DISK_FULL (112) or ERROR_HANDLE_DISK_FULL (39)."
  }
  $record.availableBytesAfterFill = [IO.DriveInfo]::new("$letter`:\").AvailableFreeSpace

  $phase = 'vault-save-on-full-volume'
  & $native disk-full $vaultPath 2>&1 | Tee-Object -FilePath $record.diskFailureLog
  $diskExit = $LASTEXITCODE
  $record.diskFailureExitCode = $diskExit
  if ($diskExit -ne 0) { throw "Vault save failure invariants failed on the full isolated volume (exit=$diskExit)." }
  $record.classification = 'PASS'
  Write-Host "PASS: the isolated $letter`: VHD exhausted writes (phase=$($fillResult.Phase), block=$($fillResult.SmallestBlockBytesTried), Win32=$($fillResult.Win32Error), reportedFree=$($record.availableBytesAfterFill)); the real vault save preserved primary, backup, memory, and password-cache invariants."
} catch {
  if ($record.classification -eq 'NOT_RUN') {
    $record.classification = if ($phase -eq 'vhd-provision') { 'PROVISION_FAILURE' } else { 'TEST_FAILURE' }
  }
  $record.diagnostic = $_.Exception.Message
  Write-Host ("{0}: {1}" -f $record.classification, $record.diagnostic)
} finally {
  if (Test-Path -LiteralPath $vhd -PathType Leaf) {
    try {
      @("select vdisk file=`"$vhd`"", 'detach vdisk', 'exit') |
        Set-Content -LiteralPath $diskpartCleanup -Encoding ASCII
      $detachOutput = & diskpart.exe /s $diskpartCleanup 2>&1
      $detachExit = $LASTEXITCODE
      $detachOutput | Add-Content -LiteralPath $diskpartLog -Encoding UTF8
      if ($detachExit -ne 0) { throw "DiskPart detach exit=$detachExit" }
      $volumeMounted = $false
      $absoluteVhd = [IO.Path]::GetFullPath($vhd)
      $safePrefix = $testRoot.TrimEnd('\') + '\real-disk-'
      if (-not $absoluteVhd.StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase) -or
          [IO.Path]::GetFileName((Split-Path $absoluteVhd -Parent)) -notmatch '^real-disk-[a-f0-9]{32}$' -or
          [IO.Path]::GetFileName($absoluteVhd) -ne 'isolated-full-volume.vhd') {
        throw 'Unsafe VHD cleanup target.'
      }
      $ancestor = Get-Item -LiteralPath (Split-Path $absoluteVhd -Parent) -Force
      while ($ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'VHD cleanup refused reparse ancestor.' }
        $ancestor = $ancestor.Parent
      }
      Remove-Item -LiteralPath $absoluteVhd -Force -ErrorAction Stop
      $record.cleanup = 'DETACHED_AND_DELETED'
    } catch {
      $record.cleanup = 'FAILED'
      $record.cleanupDiagnostic = $_.Exception.Message
      Write-Warning "Isolated VHD cleanup failed; inspect only this run's artifact at '$vhd': $_"
    }
  } else {
    $record.cleanup = 'NO_VHD_CREATED'
  }
  $record.finishedUtc = [DateTime]::UtcNow.ToString('o')
  $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding UTF8
  Write-Host "Disk failure evidence: $run"
}

if ($record.classification -eq 'PASS' -and $record.cleanup -eq 'DETACHED_AND_DELETED') { exit 0 }
if ($record.classification -eq 'ENVIRONMENT_BLOCKED') { exit 78 }
exit 1
