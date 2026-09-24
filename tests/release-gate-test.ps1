$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'release-policy.ps1')
$work=Join-Path $PSScriptRoot ('b\release-fixture-'+[guid]::NewGuid().ToString('N'))
$passed=0
function Must-Fail([string]$Name,[scriptblock]$Action){
  $failed=$false;try{& $Action | Out-Null}catch{$failed=$true}
  if(-not $failed){throw "Expected rejection: $Name"}
  $script:passed++;Write-Host "PASS: $Name"
}
function Fixture([string]$Name){
  $dir=Join-Path $work $Name;New-Item -ItemType Directory -Path (Join-Path $dir 'Lang') -Force | Out-Null
  foreach($rel in $script:ReleaseRequiredFiles){[IO.File]::WriteAllText((Join-Path $dir $rel),$rel)}
  Write-ReleaseManifest $dir
  return $dir
}
try{
  $clean=Fixture 'clean';Assert-ReleaseTree $clean -RequireManifest;[void](Test-ReleaseManifest $clean);$passed++
  foreach($rel in @('vault.dat','Lang\vault.dat','Lang\dump.dmp','Lang\private.pfx','Lang\unknown.txt','.env','uninstall.cmd','uninstall.ps1','7z.sfx')){
    $dir=Fixture ('bait-'+$passed);$path=Join-Path $dir $rel;[IO.File]::WriteAllText($path,'bait')
    Must-Fail $rel {Assert-ReleaseTree $dir -RequireManifest}
  }
  $dir=Fixture 'deep';New-Item -ItemType Directory -Path (Join-Path $dir 'Lang\deep') | Out-Null
  [IO.File]::WriteAllText((Join-Path $dir 'Lang\deep\secret.dat'),'bait');Must-Fail 'unknown nested directory' {Assert-ReleaseTree $dir}
  $dir=Fixture 'hidden';$path=Join-Path $dir 'Lang\hidden.txt';[IO.File]::WriteAllText($path,'bait');[IO.File]::SetAttributes($path,[IO.FileAttributes]::Hidden)
  Must-Fail 'hidden file' {Assert-ReleaseTree $dir}
  $dir=Fixture 'junction';New-Item -ItemType Junction -Path (Join-Path $dir 'Lang\linked') -Target $clean | Out-Null
  Must-Fail 'junction' {Assert-ReleaseTree $dir}
  Remove-Item -LiteralPath (Join-Path $dir 'Lang\linked') -Force
  $dir=Fixture 'tamper';[IO.File]::AppendAllText((Join-Path $dir '7zFM.exe'),'changed');Must-Fail 'hash mismatch' {Test-ReleaseManifest $dir}
  $dir=Fixture 'traversal';Add-Content -LiteralPath (Join-Path $dir 'SHA256SUMS.txt') -Value (('0'*64)+'  ..\outside.txt');Must-Fail 'manifest traversal' {Test-ReleaseManifest $dir}
  $dir=Fixture 'duplicate';$line=Get-Content (Join-Path $dir 'SHA256SUMS.txt') | Select-Object -First 1;Add-Content (Join-Path $dir 'SHA256SUMS.txt') $line;Must-Fail 'duplicate manifest row' {Test-ReleaseManifest $dir}
  $dir=Fixture 'missing';Remove-Item -LiteralPath (Join-Path $dir 'Lang\en.txt');Must-Fail 'missing required file' {Test-ReleaseManifest $dir}
  Must-Fail 'SFX disabled' {& (Join-Path $root 'installer\build.ps1') -PackageDir $clean -OutDir (Join-Path $work 'out') -WithSetup}
  Must-Fail 'public release without evidence blocked' {& (Join-Path $root 'installer\build.ps1') -PackageDir $clean -OutDir (Join-Path $work 'out')}
  $insiderEvidence=[pscustomobject]@{upstreamVerified=$true;windows11InsiderStandardUser='passed';windows11InsiderBuild='10.0.26220.9492'}
  Assert-TargetOsEvidence $insiderEvidence;$passed++;Write-Host 'PASS: Windows 11 Insider target accepted without a Windows 10 result'
  Must-Fail 'legacy two-system fields do not satisfy Insider evidence' {Assert-TargetOsEvidence ([pscustomobject]@{upstreamVerified=$true;windows10StandardUser='passed';windows11StandardUser='passed'})}
  Must-Fail 'Insider evidence needs an OS build' {Assert-TargetOsEvidence ([pscustomobject]@{upstreamVerified=$true;windows11InsiderStandardUser='passed';windows11InsiderBuild=''})}
  Must-Fail 'unverified upstream source still blocked' {Assert-TargetOsEvidence ([pscustomobject]@{upstreamVerified=$false;windows11InsiderStandardUser='passed';windows11InsiderBuild='10.0.26220.9492'})}
  $lockPath=Join-Path $work 'verified-inputs.json'
  $sourceHash=(Get-FileHash -LiteralPath (Join-Path $root '7z2603-src.7z')).Hash
  $runtime=@(foreach($name in $script:ReleaseRuntimeFiles){@{file=$name;sha256=(Get-FileHash -LiteralPath (Join-Path $clean $name)).Hash}})
  [IO.File]::WriteAllText($lockPath,(@{upstreamVerified=$true;sourceArchive=@{file='7z2603-src.7z';sha256=$sourceHash};runtime=$runtime}|ConvertTo-Json -Depth 5))
  $fmHash=(Get-FileHash -LiteralPath (Join-Path $clean '7zFM.exe')).Hash
  $gHash=(Get-FileHash -LiteralPath (Join-Path $clean '7zG.exe')).Hash
  $guiProof=Join-Path $work 'gui-proof.json'
  $gui=[ordered]@{classification='PASS';exitCode=0;passed=393;failed=0;scriptSha256=(Get-FileHash -LiteralPath (Join-Path $root 'tests\ui-test.ps1')).Hash;fileManagerSha256=$fmHash;guiSha256=$gHash}
  [IO.File]::WriteAllText($guiProof,($gui|ConvertTo-Json));$gui.evidencePath=$guiProof;$gui.evidenceSha256=(Get-FileHash -LiteralPath $guiProof).Hash
  $proof=Join-Path $work 'rollback-proof.json';[IO.File]::WriteAllText($proof,(@{result='passed';account='TEST\cs';assertionsFailed=0;fileManagerSha256=$fmHash;guiSha256=$gHash;preUpgradeVaultSha256=('a'*64);upgradedVaultSha256=('b'*64);backupSha256=('a'*64);rollbackVaultSha256=('a'*64)}|ConvertTo-Json))
  $rollback=[ordered]@{result='passed';evidencePath=$proof;evidenceSha256=(Get-FileHash -LiteralPath $proof).Hash;fileManagerSha256=$fmHash;guiSha256=$gHash}
  $public=[ordered]@{upstreamVerified=$true;runtimeInputsVerified=$true;inputLockSha256=(Get-FileHash -LiteralPath $lockPath).Hash;sourceArchiveSha256=$sourceHash;windows11InsiderStandardUser='passed';windows11InsiderBuild='10.0.26220.9492';standardUserAccount='TEST\cs';standardUserGui=$gui;upgradeRollback=$rollback;securityScanStatus='not-reviewed'}
  Assert-PublicReleaseEvidence ([pscustomobject]$public) $clean $lockPath;$passed++;Write-Host 'PASS: unsigned policy accepts complete provenance and candidate-bound regression evidence'
  $public.securityScanStatus='detected';Must-Fail 'known detection cannot be released' {Assert-PublicReleaseEvidence ([pscustomobject]$public) $clean $lockPath};$public.securityScanStatus='not-reviewed'
  $gui.fileManagerSha256='0'*64;Must-Fail 'GUI result for another EXE is rejected' {Assert-PublicReleaseEvidence ([pscustomobject]$public) $clean $lockPath};$gui.fileManagerSha256=$fmHash
  $rollback.evidenceSha256='0'*64;Must-Fail 'changed rollback proof is rejected' {Assert-PublicReleaseEvidence ([pscustomobject]$public) $clean $lockPath};$rollback.evidenceSha256=(Get-FileHash -LiteralPath $proof).Hash
  $badProof=Get-Content -LiteralPath $proof -Raw | ConvertFrom-Json;$badProof.backupSha256='c'*64
  [IO.File]::WriteAllText($proof,($badProof|ConvertTo-Json));$rollback.evidenceSha256=(Get-FileHash -LiteralPath $proof).Hash
  Must-Fail 'backup differing from the pre-upgrade ciphertext is rejected' {Assert-PublicReleaseEvidence ([pscustomobject]$public) $clean $lockPath}
  $badProof.backupSha256='a'*64;[IO.File]::WriteAllText($proof,($badProof|ConvertTo-Json));$rollback.evidenceSha256=(Get-FileHash -LiteralPath $proof).Hash
  $public.inputLockSha256='0'*64;Must-Fail 'different input lock is rejected' {Assert-PublicReleaseEvidence ([pscustomobject]$public) $clean $lockPath};$public.inputLockSha256=(Get-FileHash -LiteralPath $lockPath).Hash
  [IO.File]::AppendAllText($guiProof,"`n")
  Must-Fail 'modified original GUI proof is rejected' {Assert-PublicReleaseEvidence ([pscustomobject]$public) $clean $lockPath}
  [IO.File]::WriteAllText($guiProof,(($gui | Select-Object classification,exitCode,passed,failed,scriptSha256,fileManagerSha256,guiSha256)|ConvertTo-Json));$gui.evidenceSha256=(Get-FileHash -LiteralPath $guiProof).Hash
  [IO.File]::AppendAllText((Join-Path $clean '7z.exe'),'changed')
  Must-Fail 'runtime input differing from verified lock is rejected' {Assert-PublicReleaseEvidence ([pscustomobject]$public) $clean $lockPath}
  [IO.File]::WriteAllText((Join-Path $clean '7z.exe'),'7z.exe')
  $public.securityScanStatus='clean';Must-Fail 'clean scan claim without exact-hash records is rejected' {Assert-PublicReleaseEvidence ([pscustomobject]$public) $clean $lockPath}
  & (Join-Path $root 'installer\build.ps1') -PackageDir $clean -OutDir (Join-Path $work 'internal') -InternalTest | Out-Null
  $passed++;Write-Host 'PASS: ZIP roundtrip, exact manifest, standalone checksum and internal label'
}finally{
  $resolved=[IO.Path]::GetFullPath($work);$testRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'b'))+'\'
  if(-not $resolved.StartsWith($testRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'unsafe fixture cleanup'}
  if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
Write-Host "Release regression: $passed checks passed."
