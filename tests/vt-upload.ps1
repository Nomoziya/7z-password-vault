# vt-upload.ps1 - submit the release files to VirusTotal and read the reports back.
#
# The API key is never printed and never written to the repository: it is read from
# %USERPROFILE%\.vt-key (or $env:VT_API_KEY). The free tier allows 4 requests per
# minute, so the files are submitted one at a time with a pause in between.
#
# Usage:
#   pwsh -NoProfile -File tests\vt-upload.ps1
#   pwsh -NoProfile -File tests\vt-upload.ps1 -SkipUpload    # only read the reports

param(
  [string]$KeyFile = (Join-Path $env:USERPROFILE ".vt-key"),
  [switch]$SkipUpload,
  [int]$PauseSeconds = 20
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

$key = $env:VT_API_KEY
if (-not $key -and (Test-Path $KeyFile)) { $key = (Get-Content -LiteralPath $KeyFile -Raw).Trim() }
if (-not $key) {
  Write-Host "no API key: put it in $KeyFile (one line) or set `$env:VT_API_KEY" -ForegroundColor Red
  Write-Host "free key: https://www.virustotal.com/gui/my-apikey"
  exit 2
}
$headers = @{ "x-apikey" = $key; accept = "application/json" }

$files = @(
  (Join-Path $root "7-Zip-密码管家版\7zFM.exe"),
  (Join-Path $root "7-Zip-密码管家版\7zG.exe"),
  (Join-Path $root "7z-password-vault-26.03-win64.zip")
) | Where-Object { Test-Path $_ }

function Show-Report([string]$hash) {
  $r = Invoke-RestMethod -Uri "https://www.virustotal.com/api/v3/files/$hash" -Headers $headers -TimeoutSec 60
  $a = $r.data.attributes
  $s = $a.last_analysis_stats
  Write-Host ("  name   : {0}   size: {1} bytes" -f $a.meaningful_name, $a.size)
  Write-Host ("  stats  : malicious={0} suspicious={1} undetected={2} harmless={3} failure={4}" -f `
      $s.malicious, $s.suspicious, $s.undetected, $s.harmless, $s.failure) `
    -ForegroundColor $(if ($s.malicious -gt 0 -or $s.suspicious -gt 0) { "Yellow" } else { "Green" })
  $hits = @()
  foreach ($p in $a.last_analysis_results.PSObject.Properties) {
    if ($p.Value.category -in @("malicious", "suspicious")) { $hits += ("{0} -> {1}" -f $p.Name, $p.Value.result) }
  }
  if ($hits.Count -eq 0) { Write-Host "  nothing flagged" -ForegroundColor Green } else { $hits | ForEach-Object { "    $_" } }
  try {
    $b = Invoke-RestMethod -Uri "https://www.virustotal.com/api/v3/files/$hash/behaviour_summary" -Headers $headers -TimeoutSec 60
    $d = $b.data
    foreach ($k in @("network", "dns_lookups", "ip_traffic", "http_conversations", "files_written", "files_dropped",
                     "registry_keys_set", "processes_created", "command_executions", "services_created", "mitre_attack_techniques")) {
      $v = $d.$k
      if ($null -eq $v) { continue }
      $n = if ($v -is [System.Array]) { $v.Count } else { 1 }
      if ($n -gt 0) { Write-Host ("  behaviour {0,-16}: {1}" -f $k, $n) }
    }
  } catch { Write-Host "  (no behaviour report)" -ForegroundColor DarkGray }
}

foreach ($f in $files) {
  $hash = (Get-FileHash $f -Algorithm SHA256).Hash.ToLower()
  Write-Host ("`n=== {0}  {1} ===" -f (Split-Path $f -Leaf), $hash) -ForegroundColor Cyan
  if (-not $SkipUpload) {
    # The first submission of a file returns an analysis id; the verdict appears a
    # few seconds later, so it is polled until it is completed.
    $up = Invoke-RestMethod -Method Post -Uri "https://www.virustotal.com/api/v3/files" -Headers $headers `
      -Form @{ file = Get-Item -LiteralPath $f } -TimeoutSec 300
    $analysis = $up.data.id
    Write-Host "  submitted (analysis $analysis)"
    $deadline = (Get-Date).AddSeconds(240)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds $PauseSeconds
      $st = (Invoke-RestMethod -Uri "https://www.virustotal.com/api/v3/analyses/$analysis" -Headers $headers -TimeoutSec 60).data.attributes.status
      if ($st -eq "completed") { break }
      Write-Host "  analysis: $st"
    }
  }
  Show-Report $hash
  if ($f -ne $files[-1]) { Start-Sleep -Seconds $PauseSeconds }
}
