#!/bin/sh
# Build with Nix, install to ~/Applications, sign, and (re)launch.
# Signing with a stable local certificate keeps the Accessibility grant across rebuilds;
# scripts/signing-setup.sh creates one ("Pounce Local Signing"); otherwise it signs ad-hoc.
set -e
cd "$(dirname "$0")/.."
nix build
dest="$HOME/Applications/Pounce.app"
pkill -f "$dest/Contents/MacOS/Pounce" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$dest"
cp -R "$(readlink -f result)/Applications/Pounce.app" "$dest"
chmod -R u+w "$dest"
kc="$HOME/Library/Keychains/pounce-signing.keychain-db"
[ -f "$kc" ] && security unlock-keychain -p pounce "$kc" 2>/dev/null || true
identity=$(security find-identity -p codesigning 2>/dev/null | awk -F'"' '/Pounce Local Signing/ {print $2; exit}')
codesign --force --deep -s "${identity:--}" "$dest"
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\nexec "%s/Contents/MacOS/Pounce" "$@"\n' "$dest" > "$HOME/.local/bin/pounce"
chmod +x "$HOME/.local/bin/pounce"
open "$dest"
echo "Installed $dest (signed: ${identity:-ad-hoc})"
