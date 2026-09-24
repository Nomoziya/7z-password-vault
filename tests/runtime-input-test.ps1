param([switch]$KeepArtifacts)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'runtime-input.ps1')
$work=Join-Path $PSScriptRoot ('b\runtime-cases-'+[guid]::NewGuid().ToString('N'))
$dist=Join-Path $work 'dist';$seed=Join-Path $work 'seed'
try {
New-Item -ItemType Directory -Path $dist,(Join-Path $seed 'Lang') -Force | Out-Null
$script:checks=0
function Check([bool]$ok,[string]$name){if(-not $ok){throw "FAIL: $name"};$script:checks++;Write-Host "PASS: $name"}
function Reject([scriptblock]$action,[string]$pattern,[string]$name){
  $message=''; try{& $action | Out-Null}catch{$message=$_.Exception.Message}
  Check ($message -like $pattern) $name
}
function Seal([string]$zip){
  $hash=(Get-FileHash -LiteralPath $zip).Hash
  [IO.File]::WriteAllText($zip+'.sha256',($hash+'  '+[IO.Path]::GetFileName($zip)))
  $repo=Split-Path $PSScriptRoot -Parent
  $lock=Join-Path $repo 'installer/release-inputs.json';$lockHash=(Get-FileHash $lock).Hash
  [IO.File]::WriteAllText($zip+'.source.sha256',($lockHash+'  installer/release-inputs.json'))
  @{archive=[IO.Path]::GetFileName($zip);sha256=$hash;internalTest=$true;sourceCommit=('a'*40);compiler='test fixture, never executed';compilerSha256=('b'*64);
    sourceManifestSha256=(Get-FileHash ($zip+'.source.sha256')).Hash;inputLockSha256=$lockHash;
    manifestSha256=(Get-FileHash (Join-Path $seed 'SHA256SUMS.txt')).Hash} | ConvertTo-Json | Set-Content ($zip+'.build.json')
}
Reject {Resolve-TestRuntime -DistDir $dist} '*No internal-test ZIP*' 'missing seed fails clearly'
foreach($name in $script:ReleaseRequiredFiles){[IO.File]::WriteAllText((Join-Path $seed $name),'fixture only: '+$name)}
Write-ReleaseManifest $seed
$older=Join-Path $dist 'old-internal-test.zip'
Compress-Archive -Path (Join-Path $seed '*') -DestinationPath $older;Seal $older
(Get-Item $older).LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-1)
[IO.File]::WriteAllText((Join-Path $seed 'README.md'),'new generation');Write-ReleaseManifest $seed
$latest=Join-Path $dist 'new-internal-test.zip'
Compress-Archive -Path (Join-Path $seed '*') -DestinationPath $latest;Seal $latest
$resolved=Resolve-TestRuntime -DistDir $dist -ExtractionRoot $work
Check ((Get-Content (Join-Path $resolved 'README.md') -Raw) -eq 'new generation') 'latest ZIP selected and extracted'
Check ((Resolve-TestRuntime -Directory $resolved) -eq $resolved) 'explicit verified directory accepted'
$record=Get-Content ($latest+'.build.json') -Raw | ConvertFrom-Json
$record.sha256='0'*64;$record | ConvertTo-Json | Set-Content ($latest+'.build.json')
Reject {Resolve-TestRuntime -DistDir $dist -ExtractionRoot $work} '*build record mismatch*' 'build archive hash mismatch rejected'
Seal $latest
[IO.File]::AppendAllText($latest+'.source.sha256','tamper')
Reject {Resolve-TestRuntime -DistDir $dist -ExtractionRoot $work} '*source manifest hash mismatch*' 'source record corruption rejected'
Seal $latest
$record=Get-Content ($latest+'.build.json') -Raw | ConvertFrom-Json
$record.manifestSha256='0'*64;$record | ConvertTo-Json | Set-Content ($latest+'.build.json')
Reject {Resolve-TestRuntime -DistDir $dist -ExtractionRoot $work} '*build/package manifest mismatch*' 'build record bound to package manifest'
Seal $latest
[IO.File]::AppendAllText($latest,'tamper')
Reject {Resolve-TestRuntime -DistDir $dist -ExtractionRoot $work} '*hash mismatch*' 'bad newest ZIP does not silently fall back'
[IO.File]::WriteAllText((Join-Path $resolved 'README.md'),'modified')
Reject {Resolve-TestRuntime -Directory $resolved} '*manifest hash mismatch*' 'modified extracted package rejected'
$malicious=Join-Path $dist 'unsafe-internal-test.zip'
$archive=[IO.Compression.ZipFile]::Open($malicious,[IO.Compression.ZipArchiveMode]::Create)
try{[void]$archive.CreateEntry('../escape.txt')}finally{$archive.Dispose()}
Seal $malicious;(Get-Item $malicious).LastWriteTimeUtc=[DateTime]::UtcNow.AddMinutes(1)
Reject {Resolve-TestRuntime -DistDir $dist -ExtractionRoot $work} '*Unsafe or duplicate ZIP entry*' 'path traversal rejected before extraction'
Check (-not(Test-Path (Join-Path $work 'escape.txt'))) 'no outside file written'
Write-Host "Runtime input tests: $script:checks passed."
} finally {
  if($KeepArtifacts){Write-Host "Fixtures retained: $work"}
  elseif(Test-Path -LiteralPath $work){
    try {
      $base=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'b')).TrimEnd('\')+'\'
      $owned=[IO.Path]::GetFullPath($work)
      if(-not $owned.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or
          [IO.Path]::GetFileName($owned) -notmatch '^runtime-cases-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup path'}
      $cursor=Get-Item -LiteralPath $owned -Force
      while($cursor){if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Cleanup ancestor is a reparse point'};$cursor=$cursor.Parent}
      if(@(Get-ChildItem -LiteralPath $owned -Recurse -Force | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Fixture cleanup refused reparse point'}
      Remove-Item -LiteralPath $owned -Recurse -Force -ErrorAction Stop
      Write-Host "Removed only this run's fixtures: $owned"
    } catch {Write-Warning "Fixture cleanup failed; retained $work : $_"; throw}
  }
}
