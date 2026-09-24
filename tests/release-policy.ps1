# Exact public package policy. No extension/directory wildcard can admit a file.
$script:ReleasePolicyRoot=Split-Path $PSScriptRoot -Parent
$script:ReleaseRuntimeFiles=@('7-zip.chm','7-zip.dll','7z.dll','7z.exe','descript.ion','History.txt','License.txt','readme.txt')
$script:ReleaseRequiredRootFiles=$script:ReleaseRuntimeFiles+@('7zFM.exe','7zG.exe','README.md','BUILD.md')
$script:ReleaseLanguageFiles=@('Lang\en.txt','Lang\zh-cn.txt','Lang\zh-tw.txt')
$script:ReleaseAllowedRootDirectories=@('Lang')
$script:ReleaseRequiredFiles=$script:ReleaseRequiredRootFiles+$script:ReleaseLanguageFiles
$script:ReleaseAllowedFiles=$script:ReleaseRequiredFiles+@('SHA256SUMS.txt')
$script:ReleaseForbiddenExtensions=@('.dat','.bak','.dmp','.pfx','.p12','.key','.pem','.ps1','.cmd','.sfx')
function Assert-TargetOsEvidence($Evidence) {
  if($Evidence.upstreamVerified -ne $true -or
     $Evidence.windows11InsiderStandardUser -ne 'passed' -or
     [string]::IsNullOrWhiteSpace([string]$Evidence.windows11InsiderBuild)) {
    throw 'Upstream verification and Windows 11 Insider standard-user regression with a recorded OS build must pass.'
  }
}
function Assert-PublicReleaseEvidence($Evidence,[string]$Candidate,[string]$InputLockPath) {
  Assert-TargetOsEvidence $Evidence
  $lock=Get-Content -LiteralPath $InputLockPath -Raw | ConvertFrom-Json
  if($lock.upstreamVerified -ne $true -or $Evidence.runtimeInputsVerified -ne $true){
    throw 'Upstream source and every frozen runtime input must be independently verified.'
  }
  $lockHash=(Get-FileHash -LiteralPath $InputLockPath -Algorithm SHA256).Hash
  if($Evidence.inputLockSha256 -ne $lockHash -or
     $Evidence.sourceArchiveSha256 -ne $lock.sourceArchive.sha256){
    throw 'Provenance evidence does not match the current input lock.'
  }
  if([string]::IsNullOrWhiteSpace([string]$lock.sourceArchive.file) -or
     $lock.sourceArchive.file -ne [IO.Path]::GetFileName([string]$lock.sourceArchive.file)){
    throw 'Source archive lock must name a file in the repository root.'
  }
  $sourceArchive=Join-Path $script:ReleasePolicyRoot $lock.sourceArchive.file
  if(-not(Test-Path -LiteralPath $sourceArchive -PathType Leaf) -or
     (Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash -ne $lock.sourceArchive.sha256){
    throw 'Frozen upstream source archive is missing or differs from the verified lock.'
  }
  foreach($name in $script:ReleaseRuntimeFiles){
    $records=@($lock.runtime | Where-Object {$_.file -eq $name})
    if($records.Count -ne 1 -or
       (Get-FileHash -LiteralPath (Join-Path $Candidate $name) -Algorithm SHA256).Hash -ne $records[0].sha256){
      throw "Frozen runtime input differs from the verified lock: $name"
    }
  }
  $gui=$Evidence.standardUserGui
  if($null -eq $gui -or $gui.classification -ne 'PASS' -or
     $gui.exitCode -ne 0 -or $gui.failed -ne 0 -or $gui.passed -le 0 -or
     [string]::IsNullOrWhiteSpace([string]$gui.scriptSha256)){
    throw 'Current Windows 11 Insider standard-user GUI PASS evidence is required.'
  }
  $currentGuiScript=Join-Path $script:ReleasePolicyRoot 'tests\ui-test.ps1'
  if($gui.scriptSha256 -ne (Get-FileHash -LiteralPath $currentGuiScript -Algorithm SHA256).Hash){
    throw 'Standard-user GUI evidence was produced by a different test script.'
  }
  if(-not(Test-Path -LiteralPath $gui.evidencePath -PathType Leaf) -or
     $gui.evidenceSha256 -ne (Get-FileHash -LiteralPath $gui.evidencePath -Algorithm SHA256).Hash){
    throw 'Original standard-user GUI result file is missing or changed.'
  }
  $guiResult=Get-Content -LiteralPath $gui.evidencePath -Raw | ConvertFrom-Json
  foreach($field in 'classification','exitCode','passed','failed','scriptSha256','fileManagerSha256','guiSha256'){
    if($guiResult.$field -ne $gui.$field){throw "Standard-user GUI result differs from release evidence: $field"}
  }
  $rollback=$Evidence.upgradeRollback
  if($null -eq $rollback -or $rollback.result -ne 'passed' -or
     [string]::IsNullOrWhiteSpace([string]$rollback.evidencePath) -or
     -not(Test-Path -LiteralPath $rollback.evidencePath -PathType Leaf) -or
     $rollback.evidenceSha256 -ne (Get-FileHash -LiteralPath $rollback.evidencePath -Algorithm SHA256).Hash){
    throw 'Current candidate upgrade and rollback PASS evidence is required.'
  }
  $rollbackResult=Get-Content -LiteralPath $rollback.evidencePath -Raw | ConvertFrom-Json
  if($rollbackResult.result -ne 'passed' -or
     $rollbackResult.fileManagerSha256 -ne $rollback.fileManagerSha256 -or
     $rollbackResult.guiSha256 -ne $rollback.guiSha256 -or
     $rollbackResult.account -ne $Evidence.standardUserAccount -or
     $rollbackResult.assertionsFailed -ne 0 -or
     $rollbackResult.preUpgradeVaultSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
     $rollbackResult.upgradedVaultSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
     $rollbackResult.backupSha256 -ne $rollbackResult.preUpgradeVaultSha256 -or
     $rollbackResult.rollbackVaultSha256 -ne $rollbackResult.preUpgradeVaultSha256 -or
     $rollbackResult.upgradedVaultSha256 -eq $rollbackResult.preUpgradeVaultSha256){
    throw 'Original upgrade/rollback result differs from release evidence.'
  }
  foreach($exe in '7zFM.exe','7zG.exe'){
    $hash=(Get-FileHash -LiteralPath (Join-Path $Candidate $exe) -Algorithm SHA256).Hash
    $field=if($exe -eq '7zFM.exe'){'fileManagerSha256'}else{'guiSha256'}
    if($gui.$field -ne $hash -or $rollback.$field -ne $hash){
      throw "GUI and upgrade/rollback evidence must match the candidate: $exe"
    }
  }
  if($Evidence.securityScanStatus -notin @('not-reviewed','scan-unavailable','clean','microsoft-cleared')){
    throw 'Record an explicit current-candidate security scan status; a detection is not releasable.'
  }
  if($Evidence.securityScanStatus -in @('clean','microsoft-cleared')){
    foreach($exe in '7zFM.exe','7zG.exe'){
      $hash=(Get-FileHash -LiteralPath (Join-Path $Candidate $exe) -Algorithm SHA256).Hash
      $matches=@($Evidence.files | Where-Object {$_.file -eq $exe -and $_.sha256 -eq $hash -and $_.result -eq $Evidence.securityScanStatus})
      if($matches.Count -ne 1 -or -not $matches[0].scannedAt -or
         -not $matches[0].defenderVersion -or -not $matches[0].signatureVersion -or
         ($Evidence.securityScanStatus -eq 'microsoft-cleared' -and -not $matches[0].submissionId)){
        throw "Positive scan/review claim lacks unique current-hash evidence: $exe"
      }
    }
  }
}
function Get-ReleaseRelativePath([string]$Root,[string]$FullName) {
  $FullName.Substring($Root.TrimEnd('\').Length+1).Replace('/','\')
}
function Get-ReleaseFiles([string]$Root) {
  $base=(Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path.TrimEnd('\')
  $rootItem=Get-Item -LiteralPath $base -Force
  if($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'release root is a reparse point'}
  $pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue($base)
  while($pending.Count){
    foreach($item in Get-ChildItem -LiteralPath $pending.Dequeue() -Force -ErrorAction Stop){
      $rel=Get-ReleaseRelativePath $base $item.FullName
      if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "reparse point in release tree: $rel"}
      if($item.PSIsContainer){
        if($rel -ne 'Lang'){throw "directory outside release allowlist: $rel"}
        $pending.Enqueue($item.FullName)
      }else{$item}
    }
  }
}
function Assert-ReleaseTree([string]$Root,[switch]$RequireManifest){
  $base=(Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path.TrimEnd('\')
  $files=@(Get-ReleaseFiles $base)
  foreach($f in $files){
    $rel=Get-ReleaseRelativePath $base $f.FullName
    if($script:ReleaseForbiddenExtensions -contains $f.Extension){throw "forbidden file in release tree: $rel"}
    if($script:ReleaseAllowedFiles -notcontains $rel){throw "file outside release allowlist: $rel"}
  }
  foreach($rel in $script:ReleaseRequiredFiles){
    if(-not(Test-Path -LiteralPath (Join-Path $base $rel) -PathType Leaf)){throw "required release file missing: $rel"}
  }
  if($RequireManifest -and -not(Test-Path -LiteralPath (Join-Path $base 'SHA256SUMS.txt'))){throw 'SHA256SUMS.txt is required'}
}
function Write-ReleaseManifest([string]$Root){
  Assert-ReleaseTree $Root
  $base=(Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
  $lines=@(foreach($f in Get-ReleaseFiles $base | Sort-Object FullName){
    $rel=Get-ReleaseRelativePath $base $f.FullName
    if($rel -ne 'SHA256SUMS.txt'){'{0}  {1}' -f (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant(),$rel}
  })
  [IO.File]::WriteAllLines((Join-Path $base 'SHA256SUMS.txt'),$lines,[Text.UTF8Encoding]::new($false))
}
function Test-ReleaseManifest([string]$Root){
  Assert-ReleaseTree $Root -RequireManifest
  $base=(Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
  $listed=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($line in Get-Content -LiteralPath (Join-Path $base 'SHA256SUMS.txt')){
    if($line -notmatch '^([0-9a-fA-F]{64})  (.+)$'){throw 'invalid manifest line'}
    $hash=$Matches[1];$rel=$Matches[2]
    if($script:ReleaseRequiredFiles -notcontains $rel){throw "manifest path outside allowlist: $rel"}
    if(-not $listed.Add($rel)){throw "duplicate manifest path: $rel"}
    if((Get-FileHash -LiteralPath (Join-Path $base $rel) -Algorithm SHA256).Hash -ne $hash){throw "manifest hash mismatch: $rel"}
  }
  if($listed.Count -ne $script:ReleaseRequiredFiles.Count){throw 'manifest file set does not exactly match release tree'}
  return $true
}
