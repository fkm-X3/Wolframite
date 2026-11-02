# install-compiler.ps1 — Install Wolframite toolchain on Windows
# Copies built artifacts from zig-out/ to %USERPROFILE%\wolframite\

$ErrorActionPreference = "Stop"

$InstallDir = Join-Path $env:USERPROFILE "wolframite"
$BinDir = Join-Path $InstallDir "bin"
$LibDir = Join-Path $InstallDir "lib"

New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
New-Item -ItemType Directory -Force -Path $LibDir | Out-Null

# Copy binaries from zig-out/ to install location
Copy-Item "zig-out/bin/ore.exe" -Destination "$BinDir/ore.exe" -Force
Copy-Item "zig-out/bin/Wolframite.exe" -Destination "$BinDir/Wolframite.exe" -Force

# Copy runtime library
Copy-Item "zig-out/lib/wfr_std.lib" -Destination "$LibDir/wfr_std.lib" -Force

Write-Host "Successfully installed Wolframite to $InstallDir"
