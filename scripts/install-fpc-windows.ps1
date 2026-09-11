param(
    [Parameter(Mandatory = $true)][string]$Destination,
    [string]$Installer = ''
)
$ErrorActionPreference = 'Stop'
$expectedHash = 'F2780A81BFE3AB7F5FB4B6DD96DB0F71AF3F70FB8D1A01AE651D4FABBFB1BA5A'
# Official Lazarus 4.4 distribution includes FPC 3.2.2 x64. Use bounded mirror
# downloads: the automatic SourceForge route has stalled on hosted Windows.
if (-not $Installer) {
    $Installer = Join-Path ([IO.Path]::GetTempPath()) 'fiber-runtime-lazarus-4.4.exe'
    $base = 'https://downloads.sourceforge.net/project/lazarus/Lazarus%20Windows%2064%20bits/Lazarus%204.4/lazarus-4.4-fpc-3.2.2-win64.exe'
    $downloaded = $false
    foreach ($mirror in @('pilotfiber', 'netix')) {
        & curl.exe -fLsS --connect-timeout 15 --max-time 150 --output $Installer "$base`?use_mirror=$mirror"
        if ($LASTEXITCODE -eq 0) { $downloaded = $true; break }
    }
    if (-not $downloaded) { throw 'Official compiler download failed on both mirrors' }
}
if ((Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash -ne $expectedHash) {
    throw 'Lazarus installer SHA256 differs from the verified distribution'
}
$Destination = [IO.Path]::GetFullPath($Destination)
$installProcess = Start-Process -FilePath $Installer -ArgumentList @(
    '/VERYSILENT', '/SP-', '/SUPPRESSMSGBOXES', '/NORESTART',
    "/DIR=`"$Destination`""
) -PassThru -WindowStyle Hidden
if (-not $installProcess.WaitForExit(180000)) {
    # Kill only the process tree launched above; no installer may outlive failure.
    & taskkill.exe /PID $installProcess.Id /T /F | Out-Null
    if (-not $installProcess.WaitForExit(10000)) { throw 'Installer process tree did not terminate' }
    throw 'Lazarus installer did not exit within 180 seconds'
}
if ($installProcess.ExitCode -ne 0) { throw "Lazarus installer failed: $($installProcess.ExitCode)" }
$compilerDirectory = Join-Path $Destination 'fpc/3.2.2/bin/x86_64-win64'
$compiler = Join-Path $compilerDirectory 'fpc.exe'
$version = & $compiler -iV
if ($LASTEXITCODE -ne 0 -or "$version".Trim() -ne '3.2.2') { throw 'Expected FPC 3.2.2' }
$cpu = & $compiler -iTP
if ($LASTEXITCODE -ne 0 -or "$cpu".Trim() -ne 'x86_64') { throw 'Expected x86_64 compiler' }
if ($env:GITHUB_PATH) { $compilerDirectory | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8 }
Write-Output "PASS verified FPC $version x86_64 at $compilerDirectory"
