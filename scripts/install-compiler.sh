#!/usr/bin/env bash
set -euo pipefail

# Detect architecture
ARCH="$(uname -m)"
if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "amd64" ]; then
    echo "Your arch isn't supported by Wolframite yet" >&2
    exit 1
fi

# Determine install target directory (matching dev-install.sh)
if [ "$EUID" -eq 0 ]; then
    INSTALL_DIR="/usr/local/wolframite"
else
    INSTALL_DIR="$HOME/wolframite"
    mkdir -p "$INSTALL_DIR"
fi

BIN_DIR="$INSTALL_DIR/bin"
LIB_DIR="$INSTALL_DIR/lib"
mkdir -p "$BIN_DIR" "$LIB_DIR"

# Copy binaries from zig-out/ to install location
cp zig-out/bin/ore "$BIN_DIR/ore"
cp zig-out/bin/Wolframite "$BIN_DIR/Wolframite"
chmod +x "$BIN_DIR/ore" "$BIN_DIR/Wolframite"

# Copy runtime library
cp zig-out/lib/libwfr_std.a "$LIB_DIR/libwfr_std.a"

echo "Successfully installed Wolframite to $INSTALL_DIR"
