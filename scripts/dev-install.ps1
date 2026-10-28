# Check for supported architecture (x86_64 / 64-bit AMD or Intel)
$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne "AMD64") {
    Write-Host "Your arch isn't supported by Wolframite yet" -ForegroundColor Red
    exit 1
}

# Set target installation directory to wolframite base folder
$installDir = "$HOME\wolframite"
$binDir = Join-Path $installDir "bin"

if (!(Test-Path -Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

$url = "https://github.com/fkm-X3/Wolframite/releases/download/dev/ore-windows-x86_64.zip"
$tempZip = Join-Path $env:TEMP "ore-windows-x86_64.zip"

Write-Host "Downloading latest dev build archive of Wolframite..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $url -OutFile $tempZip

Write-Host "Extracting archive to $installDir..." -ForegroundColor Cyan
Expand-Archive -Path $tempZip -DestinationPath $installDir -Force
Remove-Item -Path $tempZip -Force

# Add $binDir to User PATH if not already present
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -split ';' -notcontains $binDir) {
    Write-Host "Adding $binDir to User PATH..." -ForegroundColor Yellow
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$binDir", "User")
    $env:Path += ";$binDir"
}

Write-Host "Installation complete! Restart your terminal or run 'ore' directly." -ForegroundColor Green