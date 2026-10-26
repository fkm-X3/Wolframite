# Check for supported architecture (x86_64 / 64-bit AMD or Intel)
$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne "AMD64") {
    Write-Host "Your arch isn't supported by Wolframite yet" -ForegroundColor Red
    exit 1
}

# Set target installation directory to wolframite/bin
$installDir = "$HOME\wolframite\bin"

if (!(Test-Path -Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

$url = "https://github.com/fkm-X3/Wolframite/releases/download/dev/ore-windows-x86_64.exe"
$outputFile = Join-Path $installDir "ore.exe"

Write-Host "Downloading latest dev build of 'ore'..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $url -OutFile $outputFile

# Add $installDir to User PATH if not already present
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -split ';' -notcontains $installDir) {
    Write-Host "Adding $installDir to User PATH..." -ForegroundColor Yellow
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$installDir", "User")
    $env:Path += ";$installDir"
}

Write-Host "Installation complete! Restart your terminal or run 'ore' directly." -ForegroundColor Green
