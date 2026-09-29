#!/bin/bash
# Installs kex for the current user (Linux, WSL2, macOS). No root needed.
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/kex"
BIN="$HOME/.local/bin"

mkdir -p "$DEST/server" "$BIN"
install -m 755 "$SRC/kex" "$DEST/kex"
install -m 755 "$SRC/server/kex-server.sh" "$DEST/server/kex-server.sh"
for cmd in kex kexit kstatus; do
    ln -sfn "$DEST/kex" "$BIN/$cmd"
done

echo "Installed kex to $DEST (commands: kex, kexit, kstatus in $BIN)"
case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "Note: $BIN isn't on your PATH. Add it, e.g.: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
esac
echo "Next: kex setup"
