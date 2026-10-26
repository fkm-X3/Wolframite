#!/usr/bin/env bash

set -e

# Detect architecture
ARCH="$(uname -m)"

# Check if architecture is x86_64 / amd64
if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "amd64" ]; then
    echo "Your arch isn't supported by Wolframite yet"
    exit 1
fi

URL="https://github.com/fkm-X3/Wolframite/releases/download/dev/ore-linux-x86_64.tar.gz"

# Determine install target directory (wolframite base folder)
if [ "$EUID" -eq 0 ]; then
    INSTALL_DIR="/usr/local/wolframite"
else
    INSTALL_DIR="$HOME/wolframite"
    mkdir -p "$INSTALL_DIR"
fi

BIN_DIR="$INSTALL_DIR/bin"
TARGET="$BIN_DIR/ore"

echo "Downloading latest dev build archive of Wolframite..."
TEMP_TAR="$(mktemp)"
curl -sSL "$URL" -o "$TEMP_TAR"

echo "Extracting archive to $INSTALL_DIR..."
tar -xzf "$TEMP_TAR" -C "$INSTALL_DIR"
rm -f "$TEMP_TAR"

echo "Setting executable permissions..."
chmod +x "$TARGET"

echo "Successfully installed Wolframite to $INSTALL_DIR"

# Automatically add BIN_DIR to environment PATH
if [ "$EUID" -eq 0 ]; then
    export PATH="$PATH:$BIN_DIR"
    echo "Added $BIN_DIR to current session PATH."
else
    # Determine default shell configuration file
    SHELL_RC=""
    if [[ "$SHELL" == */zsh ]]; then
        SHELL_RC="$HOME/.zshrc"
    elif [[ "$SHELL" == */bash ]]; then
        SHELL_RC="$HOME/.bashrc"
    else
        SHELL_RC="$HOME/.profile"
    fi

    if [ -f "$SHELL_RC" ] && ! grep -q "wolframite/bin" "$SHELL_RC"; then
        echo -e "\n# Added by Wolframite installer" >> "$SHELL_RC"
        echo "export PATH=\"\$PATH:$BIN_DIR\"" >> "$SHELL_RC"
        echo "Added $BIN_DIR to $SHELL_RC"
    fi

    # Export for current session
    export PATH="$PATH:$BIN_DIR"
fi

echo "Installation complete! Restart your terminal or run 'source $SHELL_RC' to update your current session."