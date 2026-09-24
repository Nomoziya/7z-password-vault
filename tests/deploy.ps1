param([string]$PackageDir='', [string]$SeedDir='', [string]$FileManagerExe='', [string]$GuiExe='')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'release-policy.ps1')
. (Join-Path $PSScriptRoot 'runtime-input.ps1')
$SeedDir=Resolve-TestRuntime -Directory $SeedDir
if(-not $PackageDir){$PackageDir=Join-Path $root ('dist\candidate-'+[guid]::NewGuid().ToString('N'))}
$package=[IO.Path]::GetFullPath($PackageDir)
if(Test-Path -LiteralPath $package){throw 'Candidate destination must be new and empty; existing data is never replaced.'}
$seed=(Resolve-Path -LiteralPath $SeedDir).Path.TrimEnd('\')
$inputs=Get-Content (Join-Path $root 'installer\release-inputs.json') -Raw | ConvertFrom-Json
[void](Test-ReleaseManifest $seed)
foreach($inputFile in $inputs.runtime){
  if((Get-FileHash -LiteralPath (Join-Path $seed $inputFile.file)).Hash -ne $inputFile.sha256){throw "pinned input hash mismatch: $($inputFile.file)"}
}
if((Get-FileHash -LiteralPath (Join-Path $root $inputs.sourceArchive.file)).Hash -ne $inputs.sourceArchive.sha256){throw 'pinned upstream source archive hash mismatch'}
if(-not $FileManagerExe){$FileManagerExe=Join-Path $root 'CPP\7zip\UI\FileManager\b\g\7zFM.exe'}
if(-not $GuiExe){$GuiExe=Join-Path $root 'CPP\7zip\UI\GUI\b\g\7zG.exe'}
$FileManagerExe=(Resolve-Path -LiteralPath $FileManagerExe -ErrorAction Stop).Path
$GuiExe=(Resolve-Path -LiteralPath $GuiExe -ErrorAction Stop).Path
# The current portable policy carries no MinGW DLLs. Refuse binaries that would
# start only on machines with the compiler directory on PATH.
function Assert-NoMissingToolchainRuntime([string]$exe) {
  $objdump=(Get-Command objdump -ErrorAction Stop).Source
  $imports=@(& $objdump -p $exe | Select-String 'DLL Name:')
  if($LASTEXITCODE -ne 0 -or $imports.Count -eq 0){throw "Could not inspect PE imports: $exe"}
  if($imports -match 'DLL Name:\s*(libgcc_s_seh-1|libstdc\+\+-6|libwinpthread-1)\.dll'){
    throw "GUI executable requires unpackaged MinGW runtime DLLs: $exe"
  }
}
Assert-NoMissingToolchainRuntime $FileManagerExe
Assert-NoMissingToolchainRuntime $GuiExe
$copies=@{
 $FileManagerExe='7zFM.exe';$GuiExe='7zG.exe';
 'README.md'='README.md';'BUILD.md'='BUILD.md';'Lang\en.txt'='Lang\en.txt';'Lang\zh-cn.txt'='Lang\zh-cn.txt';'Lang\zh-tw.txt'='Lang\zh-tw.txt'
}
foreach($source in $copies.Keys){
  $path=if([IO.Path]::IsPathRooted($source)){$source}else{Join-Path $root $source}
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Required build input missing: $source. Build both executables before deployment."}
}
New-Item -ItemType Directory -Path (Join-Path $package 'Lang') -Force | Out-Null
foreach($inputFile in $inputs.runtime){Copy-Item -LiteralPath (Join-Path $seed $inputFile.file) -Destination (Join-Path $package $inputFile.file)}
foreach($source in $copies.Keys){
  $path=if([IO.Path]::IsPathRooted($source)){$source}else{Join-Path $root $source}
  Copy-Item -LiteralPath $path -Destination (Join-Path $package $copies[$source])
}
Assert-ReleaseTree $package
Write-ReleaseManifest $package
[void](Test-ReleaseManifest $package)
Write-Host "New candidate assembled and verified: $package"
Write-Output $package
