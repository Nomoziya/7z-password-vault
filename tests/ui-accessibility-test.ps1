param(
  [string]$SevenZipDir = '',
  [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runtime-input.ps1')
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);' -Name UiMessages -Namespace PasswordVaultUiTest

$ownedRuntime = $null
$run = Join-Path (Join-Path $PSScriptRoot 'b') ('ui-accessibility-' + [guid]::NewGuid().ToString('N'))
$process = $null
$result = [ordered]@{
  startedUtc = [DateTime]::UtcNow.ToString('o')
  scriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath).Hash
  classification = 'FAIL'
  osVersion = [Environment]::OSVersion.VersionString
  runtimeDirectory = $null
  mainWindowFound = $false
  optionsOpened = $false
  passwordPageSelected = $false
  controlIdsFound = @()
  cancelInvoked = $false
  registryWrittenByHarness = $false
}

function Get-ProcessWindows([int]$processId) {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children,
      [System.Windows.Automation.Condition]::TrueCondition)) {
    try { if ($window.Current.ProcessId -eq $processId) { $window } } catch { }
  }
}

function Find-DescendantById($root, [string]$automationId) {
  $condition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $automationId)
  return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Find-OptionsDialog([int]$processId, $mainWindow) {
  foreach ($window in Get-ProcessWindows $processId) {
    $candidates = @($window) + @($window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition))
    foreach ($candidate in $candidates) {
      try {
        if ($candidate.Current.ProcessId -eq $processId -and $candidate.Current.ClassName -eq '#32770' -and $candidate.Current.Name) {
          return $candidate
        }
      } catch { }
    }
  }
  return $null
}

function Wait-For([scriptblock]$predicate, [int]$timeoutSeconds, [string]$description) {
  $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
  do {
    $value = & $predicate
    if ($value) { return $value }
    Start-Sleep -Milliseconds 150
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Timed out waiting for $description"
}

try {
  New-Item -ItemType Directory -Path $run -ErrorAction Stop | Out-Null
  if (-not $SevenZipDir) {
    $ownedRuntime = Join-Path (Join-Path $PSScriptRoot 'b') ('ui-runtime-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $ownedRuntime -ErrorAction Stop | Out-Null
    $SevenZipDir = Resolve-TestRuntime -ExtractionRoot $ownedRuntime
  } else {
    $SevenZipDir = Resolve-TestRuntime -Directory $SevenZipDir
  }
  $result.runtimeDirectory = $SevenZipDir
  $exe = Join-Path $SevenZipDir '7zFM.exe'
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "7zFM.exe missing: $exe" }
  $result.fileManagerSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
  $result.packageManifestSha256 = (Get-FileHash -LiteralPath (Join-Path $SevenZipDir 'SHA256SUMS.txt') -Algorithm SHA256).Hash

  $other = @(Get-Process -Name 7zFM -ErrorAction SilentlyContinue)
  if ($other.Count) { throw 'A 7zFM instance is already running; close it before GUI acceptance.' }

  $process = Start-Process -FilePath $exe -WorkingDirectory $SevenZipDir -PassThru
  $main = Wait-For {
    foreach ($window in Get-ProcessWindows $process.Id) {
      if ($window.Current.ClassName -eq '7-Zip::FM') { return $window }
    }
    return $null
  } 15 '7-Zip File Manager main window'
  $result.mainWindowFound = $true

  # Use the real menu command, then the documented property-sheet page selector.
  # This sends no text, reads no process memory, and does not press Apply.
  if (-not [PasswordVaultUiTest.UiMessages]::PostMessage(
      [IntPtr]$main.Current.NativeWindowHandle, 0x0111, [IntPtr]900, [IntPtr]::Zero)) {
    throw 'Could not open Options from the File Manager menu.'
  }
  $options = Wait-For { Find-OptionsDialog $process.Id $main } 10 'Options dialog'
  $result.optionsOpened = $true

  # PSM_SETCURSELID (WM_USER + 114) selects the password page resource (2600).
  if (-not [PasswordVaultUiTest.UiMessages]::PostMessage(
      [IntPtr]$options.Current.NativeWindowHandle, 0x0472, [IntPtr]::Zero, [IntPtr]2600)) {
    throw 'Could not select the password settings page.'
  }
  $passwordEdit = Wait-For { Find-DescendantById $options '101' } 10 'vault-path field on the password page'
  $result.passwordPageSelected = $true

  $requiredIds = @('2601', '2602', '2603', '2604', '2606', '2607', '2608', '2609',
    '2610', '2611', '2612', '2613', '2614', '2615', '2')
  foreach ($id in $requiredIds) {
    if (Find-DescendantById $options $id) { $result.controlIdsFound += $id }
  }
  $missing = @($requiredIds | Where-Object { $_ -notin $result.controlIdsFound })
  if ($missing.Count) { throw "Password settings controls not exposed: $($missing -join ', ')" }

  # Close through the actual Cancel button. No settings are applied or persisted.
  $cancel = Find-DescendantById $options '2'
  if (-not $cancel) { throw 'The Options Cancel button was not exposed by UI Automation.' }
  if (-not [PasswordVaultUiTest.UiMessages]::PostMessage(
      [IntPtr]$options.Current.NativeWindowHandle, 0x0111, [IntPtr]2, [IntPtr]::Zero)) {
    throw 'Could not activate the Options Cancel button.'
  }
  $result.cancelInvoked = $true
  Start-Sleep -Milliseconds 300
  $stillOpen = [bool](Find-OptionsDialog $process.Id $main)
  if ($stillOpen) { throw 'Options dialog remained open after Cancel.' }

  $result.classification = 'PASS'
  Write-Host ('PASS: GUI opened Options, selected the password page, found {0} controls, and cancelled without applying settings.' -f $result.controlIdsFound.Count)
  Write-Host 'NOTE: the harness did not write registry values, change the vault, or press Apply.'
} finally {
  if ($process -and -not $process.HasExited) {
    foreach ($window in Get-ProcessWindows $process.Id) {
      try { [void][PasswordVaultUiTest.UiMessages]::PostMessage([IntPtr]$window.Current.NativeWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) } catch { }
    }
    Start-Sleep -Milliseconds 500
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
  }

  $result.finishedUtc = [DateTime]::UtcNow.ToString('o')
  $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding UTF8
  if ($KeepArtifacts -or $result.classification -ne 'PASS') { Write-Host "GUI acceptance evidence: $run" }

  if (-not $KeepArtifacts -and $ownedRuntime -and (Test-Path -LiteralPath $ownedRuntime)) {
    $base = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'b')).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath($ownedRuntime)
    if (-not $target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($target) -notmatch '^ui-runtime-[a-f0-9]{32}$') { throw 'Unsafe GUI runtime cleanup path' }
    $ancestor = Get-Item -LiteralPath $target -Force
    while ($ancestor) {
      if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'GUI runtime cleanup refused reparse ancestor' }
      $ancestor = $ancestor.Parent
    }
    if (@(Get-ChildItem -LiteralPath $target -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
      throw 'GUI runtime cleanup refused reparse child'
    }
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
  } elseif ($KeepArtifacts -and $ownedRuntime) {
    Write-Host "Runtime retained: $ownedRuntime"
  }

  if (-not $KeepArtifacts -and $result.classification -eq 'PASS' -and (Test-Path -LiteralPath $run)) {
    $base = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'b')).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath($run)
    if (-not $target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($target) -notmatch '^ui-accessibility-[a-f0-9]{32}$') { throw 'Unsafe GUI evidence cleanup path' }
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
  } elseif ($KeepArtifacts -or $result.classification -ne 'PASS') {
    Write-Host "GUI artifacts retained: $run"
  }
}

if ($result.classification -ne 'PASS') { exit 1 }
