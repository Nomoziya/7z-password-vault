param([Parameter(Mandatory)][string]$CandidateDir)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'release-policy.ps1')
$candidate=(Resolve-Path -LiteralPath $CandidateDir).Path
[void](Test-ReleaseManifest $candidate)
if (& git -C $root status --porcelain) { throw 'Clean build requires a clean committed source tree.' }
$commit=(& git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE) { throw 'Cannot read source commit.' }
$run=Join-Path $PSScriptRoot ('b/clean-build-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$archive=Join-Path $run 'source.zip'
$checkout=Join-Path $run 'source'
$record=[ordered]@{classification='BUILD_FAILURE';sourceCommit=$commit;startedUtc=[DateTime]::UtcNow.ToString('o');files=@()}
try {
  & git -C $root archive --format=zip --output=$archive $commit
  if ($LASTEXITCODE) { throw 'Source archive creation failed.' }
  $record.sourceArchiveSha256=(Get-FileHash -LiteralPath $archive).Hash
  Expand-Archive -LiteralPath $archive -DestinationPath $checkout
  $compiler=(Get-Command g++ -ErrorAction Stop).Source
  $record.compiler=$compiler
  $record.compilerSha256=(Get-FileHash -LiteralPath $compiler).Hash
  foreach ($target in @(@{folder='FileManager';exe='7zFM.exe'},@{folder='GUI';exe='7zG.exe'})) {
    $directory=Join-Path $checkout ('CPP/7zip/UI/'+$target.folder)
    New-Item -ItemType Directory -Path (Join-Path $directory 'b/g') -Force | Out-Null
    $log=Join-Path $run ($target.folder+'.log')
    Push-Location $directory
    try {
      & make -f ../../cmpl_gcc.mak -j4 > $log 2>&1
      $code=$LASTEXITCODE
    } finally { Pop-Location }
    if ($code) { throw "Clean $($target.folder) build failed: $code; log=$log" }
    $actual=(Get-FileHash -LiteralPath (Join-Path $directory ('b/g/'+$target.exe))).Hash
    $expected=(Get-FileHash -LiteralPath (Join-Path $candidate $target.exe)).Hash
    $record.files+=@{file=$target.exe;sha256=$actual;candidateSha256=$expected;buildLogSha256=(Get-FileHash -LiteralPath $log).Hash}
    if ($actual -ne $expected) { $record.classification='HASH_MISMATCH'; throw "Clean output differs from candidate: $($target.exe)" }
    Write-Host "PASS: clean committed source reproduces $($target.exe): $actual"
  }
  if ((& git -C $root rev-parse HEAD).Trim() -ne $commit -or (& git -C $root status --porcelain)) {
    throw 'Source changed during clean build.'
  }
  $record.classification='PASS'
} finally {
  $record.finishedUtc=[DateTime]::UtcNow.ToString('o')
  $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding utf8
  Write-Host "Clean build evidence: $run"
}
