param([switch]$KeepArtifacts,[switch]$RunRealDiskTest)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$build=Join-Path $PSScriptRoot 'b'
New-Item -ItemType Directory -Force -Path $build | Out-Null
$run=Join-Path $build ('native-run-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run -ErrorAction Stop | Out-Null
$buildLog=Join-Path $run 'build.log'
$exe=Join-Path $run 'vault-native-test.exe'
$started=[DateTime]::UtcNow.ToString('o')
$record=[ordered]@{startedUtc=$started;runDirectory=$run;scriptSha256=(Get-FileHash $PSCommandPath).Hash;buildExitCode=$null;aclExitCode=$null;aclClassification='NOT_RUN';diskFailureExitCode=$null;diskFailureClassification='NOT_RUN';realDiskExitCode=$null;realDiskClassification='NOT_RUN';suiteExitCode=$null;exitCode=$null;classification='BUILD_FAILURE'}
Push-Location $root
try{
  $sources=@('tests/vault-native-test.cpp','CPP/Common/MyString.cpp','CPP/Common/MyVector.cpp','CPP/Common/StringConvert.cpp','CPP/Common/IntToString.cpp','CPP/Windows/FileIO.cpp','CPP/Windows/FileName.cpp','CPP/Windows/FileDir.cpp','CPP/Windows/FileFind.cpp','CPP/Windows/TimeUtils.cpp','CPP/Windows/ErrorMsg.cpp','CPP/Windows/Window.cpp')
  $compiler=(Get-Command g++ -ErrorAction Stop).Source
  $record.compiler=$compiler;$record.compilerSha256=(Get-FileHash $compiler).Hash
  $inputPaths=@(& git ls-files --cached --others --exclude-standard -- C CPP tests/vault-native-test.cpp tests/password-vault-security-test.ps1 | Sort-Object -Unique)
  $inputHashes=@(foreach($path in $inputPaths){if(Test-Path -LiteralPath $path -PathType Leaf){[ordered]@{path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash}}})
  $inputHashes | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $run 'inputs.json')
  $record.inputsSha256=(Get-FileHash (Join-Path $run 'inputs.json')).Hash
  $arguments=@('-std=c++17','-O2','-municode','-DUNICODE','-D_UNICODE','-ffunction-sections','-fdata-sections')+$sources+@('-Wl,--gc-sections','-Wl,--no-insert-timestamp','-static','-lcrypt32','-lbcrypt','-lshell32','-loleaut32','-ladvapi32','-luser32','-o',$exe)
  $record.arguments=$arguments
  # Always truncate/create the log before compilation, even when g++ is silent.
  "Started UTC: $started`nClean build directory: $run`nCompiler: $compiler" | Set-Content -LiteralPath $buildLog
  & $compiler @arguments >> $buildLog 2>&1
  $buildExit=$LASTEXITCODE
  "Compiler exit code: $buildExit" | Add-Content -LiteralPath $buildLog
  Copy-Item -LiteralPath $buildLog -Destination (Join-Path $PSScriptRoot 'native-build.log') -Force
  $record.buildExitCode=$buildExit;$record.buildLogSha256=(Get-FileHash $buildLog).Hash
  if($buildExit -ne 0 -or -not(Test-Path -LiteralPath $exe)){Get-Content $buildLog;throw 'native test build failed'}
  $record.exeSha256=(Get-FileHash $exe).Hash
  $work=Join-Path $run 'fixture'
  New-Item -ItemType Directory -Path $work | Out-Null
  $aclLog=Join-Path $run 'acl-result.log'
  & $exe acl (Join-Path $work 'acl-vault.dat') 2>&1 | Tee-Object -FilePath $aclLog
  $aclResult=$LASTEXITCODE
  $record.aclExitCode=$aclResult
  $record.aclClassification=$(if($aclResult -eq 0){'PASS'}elseif($aclResult -eq 78){'ENVIRONMENT_BLOCKED'}else{'TEST_FAILURE'})
  $record.aclLog=$aclLog;$record.aclResultLogSha256=(Get-FileHash $aclLog).Hash
  $diskFailureLog=Join-Path $run 'disk-failure-result.log'
  & $exe fault-disk (Join-Path $work 'disk-fault-vault.dat') 2>&1 | Tee-Object -FilePath $diskFailureLog
  $diskFailureResult=$LASTEXITCODE
  $record.diskFailureExitCode=$diskFailureResult
  $record.diskFailureClassification=$(if($diskFailureResult -eq 0){'INJECTED_FAILURE_PASS'}elseif($diskFailureResult -eq 78){'ENVIRONMENT_BLOCKED'}else{'TEST_FAILURE'})
  $record.diskFailureLog=$diskFailureLog;$record.diskFailureResultLogSha256=(Get-FileHash $diskFailureLog).Hash
  $realDiskResult=0
  if($RunRealDiskTest){
    $realDiskLog=Join-Path $run 'real-disk-result.log'
    & (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -File (Join-Path $PSScriptRoot 'real-disk-failure-test.ps1') -NativeTestExe $exe 2>&1 | Tee-Object -FilePath $realDiskLog
    $realDiskResult=$LASTEXITCODE
    $record.realDiskExitCode=$realDiskResult
    $record.realDiskClassification=$(if($realDiskResult -eq 0){'PASS'}elseif($realDiskResult -eq 78){'ENVIRONMENT_BLOCKED'}else{'TEST_FAILURE'})
    $record.realDiskLog=$realDiskLog;$record.realDiskResultLogSha256=(Get-FileHash $realDiskLog).Hash
  }
  $log=Join-Path $run 'result.log'
  & $exe suite (Join-Path $work 'fixture.dat') 2>&1 | Tee-Object -FilePath $log
  $result=$LASTEXITCODE
  $record.exitCode=$result;$record.suiteExitCode=$result
  $subtestFailure=($aclResult -ne 0 -and $aclResult -ne 78) -or ($diskFailureResult -ne 0 -and $diskFailureResult -ne 78) -or ($RunRealDiskTest -and $realDiskResult -ne 0 -and $realDiskResult -ne 78)
  $record.classification=$(if($subtestFailure){'TEST_FAILURE'}elseif($result -eq 0 -and $aclResult -eq 0 -and $diskFailureResult -eq 0 -and (!$RunRealDiskTest -or $realDiskResult -eq 0)){'PASS'}elseif(($result -eq 78 -or $aclResult -eq 78 -or $diskFailureResult -eq 78 -or ($RunRealDiskTest -and $realDiskResult -eq 78))){'PARTIAL_ENVIRONMENT_BLOCKED'}else{'TEST_FAILURE'})
  $record.log=$log;$record.resultLogSha256=(Get-FileHash $log).Hash
  if((Get-FileHash $exe).Hash -ne $record.exeSha256){$record.classification='INTEGRITY_FAILURE';throw 'Native EXE changed during execution'}
  foreach($input in $inputHashes){if((Get-FileHash -LiteralPath $input.path).Hash -ne $input.sha256){$record.classification='INTEGRITY_FAILURE';throw "Build input changed during execution: $($input.path)"}}
  if($aclResult -ne 0 -and $aclResult -ne 78){throw "REAL_ACL_TEST_FAILED: exit=$aclResult; log=$aclLog"}
  if($diskFailureResult -ne 0 -and $diskFailureResult -ne 78){$record.classification='TEST_FAILURE';throw "INJECTED_DISK_FAILURE_TEST_FAILED: exit=$diskFailureResult; log=$diskFailureLog"}
  if($RunRealDiskTest -and $realDiskResult -ne 0 -and $realDiskResult -ne 78){$record.classification='TEST_FAILURE';throw "REAL_DISK_TEST_FAILED: exit=$realDiskResult; log=$realDiskLog"}
  if($result -eq 78 -or $aclResult -eq 78 -or $diskFailureResult -eq 78 -or ($RunRealDiskTest -and $realDiskResult -eq 78)){Write-Host "ENVIRONMENT_BLOCKED: complete native suite or a requested native subtest unavailable; see its precise diagnostic. Native suite exit=$result, real disk classification=$($record.realDiskClassification), real ACL=$($record.aclClassification), injected disk-full=$($record.diskFailureClassification)."; exit 78}
  if($result){throw "NATIVE_TEST_FAILED: exit=$result; log=$log"}
}finally{
  $record.finishedUtc=[DateTime]::UtcNow.ToString('o')
  $record | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $run 'result.json')
  Write-Host "Build and execution evidence: $run"
  Pop-Location
  if($work -and -not $KeepArtifacts){
    $resolved=[IO.Path]::GetFullPath($work)
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath($build)+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'unsafe test cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}
