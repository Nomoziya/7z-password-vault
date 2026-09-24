# Scan only the two EXEs extracted from the frozen ZIP. Does not change Defender
# settings, remediate files, upload submissions, or claim nonzero exits are clean.
param([Parameter(Mandatory)][string]$Package,[Parameter(Mandatory)][string]$OutDir)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'release-policy.ps1')
$zip=(Resolve-Path -LiteralPath $Package).Path
$archiveHash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
$checksum=([IO.File]::ReadAllText($zip+'.sha256')).Trim()
if($checksum -ne ($archiveHash+'  '+[IO.Path]::GetFileName($zip))){throw 'Archive checksum does not match its sidecar.'}
$out=[IO.Path]::GetFullPath($OutDir)
if(Test-Path -LiteralPath $out){throw 'Evidence output must be new; previous evidence is preserved.'}
New-Item -ItemType Directory -Path $out | Out-Null
$scanRoot=Join-Path $out 'extracted-candidate'
Expand-Archive -LiteralPath $zip -DestinationPath $scanRoot
[void](Test-ReleaseManifest $scanRoot)
$status=$null;$statusError=$null
try{$status=Get-MpComputerStatus -ErrorAction Stop | Select-Object AMProductVersion,AMEngineVersion,AntivirusSignatureVersion,AntivirusSignatureLastUpdated,AMRunningMode,AMServiceEnabled,AntivirusEnabled}catch{$statusError=$_.Exception.Message}
$platform=Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
$engines=@(Get-ChildItem -LiteralPath $platform -Directory -ErrorAction SilentlyContinue | Sort-Object { [version]($_.Name -replace '-.*$','') } -Descending)
$scanner=$null
foreach($engine in $engines){$p=Join-Path $engine.FullName 'MpCmdRun.exe';if(Test-Path -LiteralPath $p){$scanner=$p;break}}
if(-not $scanner){$p=Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe';if(Test-Path -LiteralPath $p){$scanner=$p}}
$records=@()
foreach($name in '7zFM.exe','7zG.exe'){
  $path=Join-Path $scanRoot $name
  $hash=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
  $started=[DateTime]::UtcNow.ToString('o');$exitCode=$null;$text='Defender scanner executable not found.'
  if($scanner){
    try{
      $text=(& $scanner -Scan -ScanType 3 -File $path -DisableRemediation 2>&1 | Out-String)
      $exitCode=$LASTEXITCODE
    }catch{$text=$_.Exception.ToString()}
  }
  $after=if(Test-Path -LiteralPath $path){(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}else{$null}
  $validEnvironment=$status -and $status.AMServiceEnabled -and $status.AntivirusEnabled -and $status.AMEngineVersion -ne '0.0.0.0' -and $status.AntivirusSignatureVersion
  $result='scan-unavailable'
  if($validEnvironment -and $exitCode -eq 0 -and $after -eq $hash){$result='clean'}
  elseif($validEnvironment -and $null -ne $exitCode){$result='needs-review'}
  if($after -ne $hash){$result='candidate-changed-or-missing'}
  $log=$name+'.scan.log';[IO.File]::WriteAllText((Join-Path $out $log),$text)
  $records += [ordered]@{file=$name;sha256=$hash;sha256After=$after;signatureStatus=[string](Get-AuthenticodeSignature -LiteralPath $path).Status;scannedAt=$started;finishedAt=[DateTime]::UtcNow.ToString('o');result=$result;exitCode=$exitCode;defenderVersion=$status.AMProductVersion;engineVersion=$status.AMEngineVersion;signatureVersion=$status.AntivirusSignatureVersion;detectionName=$null;submissionId=$null;log=$log}
}
$report=[ordered]@{archive=[IO.Path]::GetFileName($zip);archiveSha256=$archiveHash;createdAt=[DateTime]::UtcNow.ToString('o');scanner=$scanner;commandOptions='-Scan -ScanType 3 -File <exact-extracted-file> -DisableRemediation';status=$status;statusError=$statusError;uploaded=$false;upstreamVerified=$false;windows11InsiderStandardUser='pending';windows11InsiderBuild='';files=$records;interpretation='Nonzero scan exit codes require inspection; they are not proof of detection or a false positive. Unavailable engine is not a clean verdict.'}
[IO.File]::WriteAllText((Join-Path $out 'defender-evidence.json'),($report|ConvertTo-Json -Depth 7))
if((Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant() -ne $archiveHash){throw 'Frozen archive changed during scan.'}
[void](Test-ReleaseManifest $scanRoot)
$records | ForEach-Object {Write-Host ($_.file+': '+$_.result+'; exit='+$_.exitCode+'; SHA256='+$_.sha256)}
Write-Output (Join-Path $out 'defender-evidence.json')
