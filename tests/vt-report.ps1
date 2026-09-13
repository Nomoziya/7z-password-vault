# vt-report.ps1 - read the VirusTotal report of the release binaries.
#
# The API key is never printed and never written to the repository: put it in a
# file outside the checkout (one line) and pass the path, or set $env:VT_API_KEY.
#
# Usage:
#   pwsh -NoProfile -File tests\vt-report.ps1
#   pwsh -NoProfile -File tests\vt-report.ps1 -KeyFile "C:\Users\me\.vt-key"
#   pwsh -NoProfile -File tests\vt-report.ps1 -Hashes <sha256>,<sha256>

param(
  [string]$KeyFile = (Join-Path $env:USERPROFILE ".vt-key"),
  [string[]]$Hashes
)

$ErrorActionPreference = "Stop"

$key = $env:VT_API_KEY
if (-not $key -and (Test-Path $KeyFile)) { $key = (Get-Content -LiteralPath $KeyFile -Raw).Trim() }
if (-not $key) {
  Write-Host "no API key: put it in $KeyFile (one line) or set `$env:VT_API_KEY" -ForegroundColor Red
  Write-Host "free key: https://www.virustotal.com/gui/my-apikey"
  exit 2
}

if (-not $Hashes -or $Hashes.Count -eq 0) {
  $dir = Join-Path (Split-Path $PSScriptRoot -Parent) "7-Zip-密码管家版"
  $files = @(
    (Join-Path $dir "7zFM.exe"),
    (Join-Path $dir "7zG.exe"),
    (Join-Path (Split-Path $PSScriptRoot -Parent) "7z-password-vault-26.03-win64.zip")
  ) | Where-Object { Test-Path $_ }
  $Hashes = $files | ForEach-Object { (Get-FileHash $_ -Algorithm SHA256).Hash.ToLower() }
}

$headers = @{ "x-apikey" = $key; accept = "application/json" }
$interesting = @("malicious", "suspicious")

function Get-Report([string]$hash) {
  $label = $hash.Substring(0, 12)
  Write-Host ("`n=== {0}... ===" -f $label) -ForegroundColor Cyan
  try {
    $r = Invoke-RestMethod -Uri "https://www.virustotal.com/api/v3/files/$hash" -Headers $headers -TimeoutSec 60
  } catch {
    Write-Host ("  file report failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    return
  }
  $a = $r.data.attributes
  Write-Host ("  name   : {0}" -f $a.meaningful_name)
  Write-Host ("  type   : {0}   size: {1} bytes" -f $a.type_description, $a.size)
  Write-Host ("  seen   : first {0}  last {1}  times_submitted {2}" -f $a.first_submission_date, $a.last_analysis_date, $a.times_submitted)
  if ($a.signature_info) { Write-Host ("  signed : {0}" -f $a.signature_info.product_name) }
  $s = $a.last_analysis_stats
  Write-Host ("  stats  : malicious={0} suspicious={1} undetected={2} harmless={3} type-unsupported={4} failure={5}" -f `
      $s.malicious, $s.suspicious, $s.undetected, $s.harmless, $s.'type-unsupported', $s.failure) `
    -ForegroundColor $(if ($s.malicious -gt 0 -or $s.suspicious -gt 0) { "Yellow" } else { "Green" })

  $hits = @()
  foreach ($p in $a.last_analysis_results.PSObject.Properties) {
    $v = $p.Value
    if ($v.category -in $interesting) { $hits += ("{0} -> {1} [{2}]" -f $p.Name, $v.result, $v.category) }
  }
  if ($hits.Count -eq 0) { Write-Host "  no engine flagged this file" -ForegroundColor Green }
  else { Write-Host ("  flagged by {0} engine(s):" -f $hits.Count) -ForegroundColor Yellow; $hits | ForEach-Object { "    $_" } }

  try {
    $b = Invoke-RestMethod -Uri "https://www.virustotal.com/api/v3/files/$hash/behaviour_summary" -Headers $headers -TimeoutSec 60
    $d = $b.data
    Write-Host "  behaviour:" -ForegroundColor DarkGray
    foreach ($section in @(
        @{ k = "network";           label = "network" },
        @{ k = "dns_lookups";       label = "dns" },
        @{ k = "ip_traffic";        label = "ip traffic" },
        @{ k = "http_conversations";label = "http" },
        @{ k = "files_written";     label = "files written" },
        @{ k = "files_dropped";     label = "files dropped" },
        @{ k = "files_deleted";     label = "files deleted" },
        @{ k = "registry_keys_set"; label = "registry set" },
        @{ k = "processes_created"; label = "processes" },
        @{ k = "command_executions";label = "commands" },
        @{ k = "modules_loaded";    label = "modules" },
        @{ k = "services_created";  label = "services" },
        @{ k = "mitre_attack_techniques"; label = "mitre" }
      )) {
      $val = $d.($section.k)
      if ($null -eq $val) { continue }
      if ($val -is [System.Array]) { $count = $val.Count } else { $count = 1 }
      if ($count -eq 0) { continue }
      Write-Host ("    {0,-14}: {1}" -f $section.label, $count)
      if ($section.k -in @("network", "dns_lookups", "ip_traffic", "http_conversations", "files_written", "files_dropped", "registry_keys_set", "processes_created", "command_executions", "services_created")) {
        $val | Select-Object -First 12 | ForEach-Object { "        $_" }
      }
    }
  } catch {
    Write-Host ("  no behaviour report ({0})" -f $_.Exception.Message.Split(":")[0]) -ForegroundColor DarkGray
  }
}

foreach ($h in $Hashes) {
  Get-Report $h
  Start-Sleep -Seconds 16   # free keys allow 4 requests per minute
}
