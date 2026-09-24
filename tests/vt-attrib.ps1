# vt-attrib.ps1 - attribution: which part of the installer makes the engines flag it?
#
# The plan is to lower the VirusTotal detections of the release, and the first step is to
# measure instead of guessing. Four probes are built from the deployed package and
# submitted; the official files that ship inside it are read by hash only (they are
# already on VirusTotal, so no request quota is spent on uploading them):
#
#   A0  official 7z.sfx + the current sfx-config text + a tiny payload
#       -> does the plaintext config (RunProgram / InstallPath) matter at all?
#   A1  the payload exactly as installer\build.ps1 packs it
#       -> how much comes from the archive itself?
#   A2  the same payload without install/uninstall scripts and the hash list
#       -> how much comes from the scripts that change the system?
#   A3  setup.exe with the two rebuilt executables swapped for an unflagged one
#       -> how much comes from the two executables?
#
# The probes are built in %TEMP% and never published: submitting a file to VirusTotal
# makes it public on the site, and a probe must not be mistakeable for a release.
#
# Usage:
#   pwsh -NoProfile -File tests\vt-attrib.ps1
#   pwsh -NoProfile -File tests\vt-attrib.ps1 -SkipUpload     # read existing reports only

param(
  [string]$KeyFile = (Join-Path $env:USERPROFILE ".vt-key"),
  [int]$PauseSeconds = 25,
  [switch]$SkipUpload,
  [string]$OutFile = (Join-Path $env:TEMP "vt-attrib.json")
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'runtime-input.ps1')
$pkg = Resolve-TestRuntime
throw 'Historical SFX attribution is not applicable to portable ZIP releases. Use current binary hashes with vt-report.ps1.'
$sevenZip = Join-Path $pkg "7z.exe"
$stub = Join-Path $pkg "7z.sfx"

$key = $env:VT_API_KEY
if (-not $key -and (Test-Path $KeyFile)) { $key = (Get-Content -LiteralPath $KeyFile -Raw).Trim() }
if (-not $key) { Write-Host "no API key (put it in $KeyFile)" -ForegroundColor Red; exit 2 }
$headers = @{ "x-apikey" = $key; accept = "application/json" }

$work = Join-Path $env:TEMP "7zpw-attrib"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force -Path $work | Out-Null

function New-Payload([string]$name, [string[]]$skip) {
  $stage = Join-Path $work $name
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Get-ChildItem -LiteralPath $pkg -Force | Where-Object { $skip -notcontains $_.Name } |
    Copy-Item -Destination $stage -Recurse -Force
  $out = Join-Path $work "$name.7z"
  & $sevenZip a -t7z -mx=9 -bso0 -bsp0 $out (Join-Path $stage "*") | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "7z failed for $name" }
  return $out
}

Write-Host "building probes in $work" -ForegroundColor Cyan
$tiny = Join-Path $work "tiny.txt"
Set-Content -LiteralPath $tiny -Value "probe" -Encoding ASCII
$tinyArc = Join-Path $work "tiny.7z"
& $sevenZip a -t7z -bso0 -bsp0 $tinyArc $tiny | Out-Null

# A0: stub + the exact config text this project ships + a tiny payload
$config = Get-Content -LiteralPath (Join-Path $root "installer\sfx-config.txt") -Raw
$probeA0 = Join-Path $work "probe-a0-stub-config.exe"
[IO.File]::WriteAllBytes($probeA0,
  [IO.File]::ReadAllBytes($stub) + [Text.Encoding]::UTF8.GetBytes($config) + [IO.File]::ReadAllBytes($tinyArc))

# A1 / A2: payloads as the build script packs them, and without the scripts
$payloadFull = New-Payload "payload-full" @()
$noScripts = @("install.cmd", "install.ps1", "uninstall.cmd", "uninstall.ps1", "SHA256SUMS.txt")
$payloadNoScripts = New-Payload "payload-noscripts" $noScripts
$probeA1 = Join-Path $work "probe-a1-payload.7z"
Copy-Item -LiteralPath $payloadFull -Destination $probeA1 -Force
$probeA2 = Join-Path $work "probe-a2-payload-noscripts.7z"
Copy-Item -LiteralPath $payloadNoScripts -Destination $probeA2 -Force

# A3: the real setup.exe shape with the two executables replaced by an unflagged one
$swap = Join-Path $work "payload-swap"
New-Item -ItemType Directory -Force -Path $swap | Out-Null
Get-ChildItem -LiteralPath $pkg -Force | Copy-Item -Destination $swap -Recurse -Force
Copy-Item -LiteralPath (Join-Path $root "installer\install.cmd") -Destination $swap -Force
Copy-Item -LiteralPath (Join-Path $root "installer\install.ps1") -Destination $swap -Force
# the official command line binary stands in for the two rebuilt GUI binaries: same size
# class, same toolchain family, but not rebuilt by this project
Copy-Item -LiteralPath (Join-Path $pkg "7z.exe") -Destination (Join-Path $swap "7zFM.exe") -Force
Copy-Item -LiteralPath (Join-Path $pkg "7z.exe") -Destination (Join-Path $swap "7zG.exe") -Force
$swapArc = Join-Path $work "payload-swap.7z"
& $sevenZip a -t7z -mx=9 -bso0 -bsp0 $swapArc (Join-Path $swap "*") | Out-Null
$probeA3 = Join-Path $work "probe-a3-setup-swapped.exe"
[IO.File]::WriteAllBytes($probeA3,
  [IO.File]::ReadAllBytes($stub) + [Text.Encoding]::UTF8.GetBytes($config) + [IO.File]::ReadAllBytes($swapArc))

$uploads = @(
  @{ id = "A0 stub+config+tiny"; path = $probeA0 },
  @{ id = "A1 payload full";     path = $probeA1 },
  @{ id = "A2 payload no-scripts"; path = $probeA2 },
  @{ id = "A3 setup, swapped exes"; path = $probeA3 }
)
# controls: read by hash, never uploaded (they are official 7-Zip files)
$controls = @(
  @{ id = "control 7z.sfx (official)"; path = $stub },
  @{ id = "control 7z.exe (official)"; path = (Join-Path $pkg "7z.exe") },
  @{ id = "control 7z.dll (official)"; path = (Join-Path $pkg "7z.dll") },
  @{ id = "release setup.exe";         path = (Join-Path $root "dist\7z-password-vault-26.03-win64-setup.exe") },
  @{ id = "release portable.zip";      path = (Join-Path $root "dist\7z-password-vault-26.03-win64-portable.zip") }
)

$results = New-Object System.Collections.Generic.List[object]

function Get-Stats([string]$hash) {
  try {
    $r = Invoke-RestMethod -Uri "https://www.virustotal.com/api/v3/files/$hash" -Headers $headers -TimeoutSec 60
    $a = $r.data.attributes
    $hits = @()
    foreach ($p in $a.last_analysis_results.PSObject.Properties) {
      if ($p.Value.category -in @("malicious", "suspicious")) { $hits += ("{0}: {1}" -f $p.Name, $p.Value.result) }
    }
    return [pscustomobject]@{
      known = $true; name = $a.meaningful_name
      malicious = $a.last_analysis_stats.malicious; suspicious = $a.last_analysis_stats.suspicious
      undetected = $a.last_analysis_stats.undetected; engines = ($hits -join " | ")
    }
  } catch {
    return [pscustomobject]@{ known = $false; name = ""; malicious = -1; suspicious = -1; undetected = -1; engines = "" }
  }
}

foreach ($c in $controls) {
  if (-not (Test-Path -LiteralPath $c.path)) { continue }
  $hash = (Get-FileHash -LiteralPath $c.path -Algorithm SHA256).Hash.ToLower()
  $s = Get-Stats $hash
  Write-Host ("`n=== {0}" -f $c.id) -ForegroundColor Cyan
  Write-Host ("  {0}" -f $hash)
  if ($s.known) {
    Write-Host ("  {0}  malicious={1} suspicious={2} undetected={3}" -f $s.name, $s.malicious, $s.suspicious, $s.undetected) `
      -ForegroundColor $(if ($s.malicious + $s.suspicious -gt 0) { "Yellow" } else { "Green" })
    if ($s.engines) { Write-Host ("  {0}" -f $s.engines) }
  } else { Write-Host "  not on VirusTotal" -ForegroundColor DarkGray }
  $results.Add([pscustomobject]@{ probe = $c.id; hash = $hash; uploaded = $false
    malicious = $s.malicious; suspicious = $s.suspicious; undetected = $s.undetected; name = $s.name; engines = $s.engines })
}

foreach ($u in $uploads) {
  $hash = (Get-FileHash -LiteralPath $u.path -Algorithm SHA256).Hash.ToLower()
  Write-Host ("`n=== {0}" -f $u.id) -ForegroundColor Cyan
  Write-Host ("  {0}  ({1:N0} bytes)" -f $hash, (Get-Item -LiteralPath $u.path).Length)
  if (-not $SkipUpload) {
    $up = Invoke-RestMethod -Method Post -Uri "https://www.virustotal.com/api/v3/files" -Headers $headers `
      -Form @{ file = Get-Item -LiteralPath $u.path } -TimeoutSec 600
    $analysis = $up.data.id
    $deadline = (Get-Date).AddSeconds(300)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds $PauseSeconds
      $st = (Invoke-RestMethod -Uri "https://www.virustotal.com/api/v3/analyses/$analysis" -Headers $headers -TimeoutSec 60).data.attributes.status
      if ($st -eq "completed") { break }
      Write-Host "  analysis: $st"
    }
  }
  $s = Get-Stats $hash
  if ($s.known) {
    Write-Host ("  malicious={0} suspicious={1} undetected={2}" -f $s.malicious, $s.suspicious, $s.undetected) `
      -ForegroundColor $(if ($s.malicious + $s.suspicious -gt 0) { "Yellow" } else { "Green" })
    if ($s.engines) { Write-Host ("  {0}" -f $s.engines) }
  } else { Write-Host "  no report yet" -ForegroundColor DarkGray }
  $results.Add([pscustomobject]@{ probe = $u.id; hash = $hash; uploaded = (-not $SkipUpload)
    malicious = $s.malicious; suspicious = $s.suspicious; undetected = $s.undetected; name = $s.name; engines = $s.engines })
  if ($u -ne $uploads[-1]) { Start-Sleep -Seconds $PauseSeconds }
}

$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutFile -Encoding UTF8
Write-Host "`n== summary ==" -ForegroundColor Cyan
$results | Format-Table probe, malicious, suspicious, undetected, name -AutoSize | Out-String -Width 200
Write-Host ("written: {0}" -f $OutFile)
Write-Host ("probes kept in {0} (delete when done)" -f $work) -ForegroundColor DarkGray
