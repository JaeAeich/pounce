#!/usr/bin/env bash
# Build a distributable Pounce.app (universal), sign, verify, zip, DMG, optionally notarize.
#
#   scripts/package.sh                 # -> dist/Pounce-<version>.{zip,dmg} + SHA256SUMS
#
# Environment (all optional):
#   VERSION         marketing version            (default: version.txt, else `git describe`, else 0.0.0)
#   BUILD_NUMBER    CFBundleVersion              (default: git commit count, else 0)
#   COMMIT          short commit hash            (default: git rev-parse --short HEAD, else "unknown")
#   IDENTITY        codesign identity            (default: first "Developer ID Application", else
#                                                 "Pounce Local Signing", else ad-hoc "-")
#   KEYCHAIN        keychain holding IDENTITY    (searched by codesign; added to search list by caller)
#   NOTARY_PROFILE  `notarytool store-credentials` profile name, or
#   ASC_KEY_PATH + ASC_KEY_ID + ASC_ISSUER_ID   App Store Connect API key (.p8) for notarytool
#   ARCHS           default "arm64 x86_64"
#   OUT             output dir (default: dist)
#   SKIP_DMG=1      only produce the zip
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---- metadata ---------------------------------------------------------------------------------
in_git() { git rev-parse HEAD >/dev/null 2>&1; }
if [[ -z "${VERSION:-}" ]]; then
  if [[ -s version.txt ]]; then VERSION=$(tr -d '[:space:]' < version.txt)
  elif in_git && git describe --tags --abbrev=0 >/dev/null 2>&1; then VERSION=$(git describe --tags --abbrev=0)
  else VERSION=0.0.0; fi
fi
VERSION=${VERSION#v}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]] || die "VERSION '$VERSION' is not semver"
if in_git; then
  BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
  COMMIT=${COMMIT:-$(git rev-parse --short=8 HEAD)}
  [[ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]] || COMMIT="$COMMIT-dirty"
fi
BUILD_NUMBER=${BUILD_NUMBER:-0}
COMMIT=${COMMIT:-unknown}
ARCHS=${ARCHS:-arm64 x86_64}
OUT=${OUT:-dist}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)

# ---- signing identity -------------------------------------------------------------------------
local_kc="$HOME/Library/Keychains/pounce-signing.keychain-db"
if [[ -z "${IDENTITY:-}" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')
  if [[ -z "$IDENTITY" ]]; then
    [[ -f "$local_kc" ]] && security unlock-keychain -p pounce "$local_kc" 2>/dev/null || true
    # Self-signed, so not "valid" (-v) — that's fine for local signing.
    security find-identity -p codesigning 2>/dev/null | grep -q '"Pounce Local Signing"' && IDENTITY="Pounce Local Signing"
  fi
  IDENTITY=${IDENTITY:--}
fi
case "$IDENTITY" in
  "Developer ID Application"*) sign_kind=developer-id ;;
  -) sign_kind=ad-hoc ;;
  *) sign_kind=local ;;
esac

notarize=none
if [[ -n "${NOTARY_PROFILE:-}" ]]; then notarize=profile
elif [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then notarize=api-key; fi
if [[ $notarize != none && $sign_kind != developer-id ]]; then
  echo "warning: notarization needs a Developer ID identity; skipping (identity: $IDENTITY)" >&2
  notarize=none
fi

say "Pounce $VERSION (build $BUILD_NUMBER, $COMMIT) — signing: $sign_kind, notarize: $notarize"

# ---- build ------------------------------------------------------------------------------------
# `swift build --arch arm64 --arch x86_64` needs Xcode's xcbuild; per-arch builds + lipo work with
# the Command Line Tools too.
slices=()
for arch in $ARCHS; do
  say "Building $arch"
  if ! swift build -c release --arch "$arch" --scratch-path ".build/$arch" --product Pounce > "/tmp/pounce-build-$arch.log" 2>&1; then
    grep -E "error:" "/tmp/pounce-build-$arch.log" || tail -n 30 "/tmp/pounce-build-$arch.log"
    die "build for $arch failed (log: /tmp/pounce-build-$arch.log)"
  fi
  bin="$(swift build -c release --arch "$arch" --scratch-path ".build/$arch" --show-bin-path)/Pounce"
  [[ -x "$bin" ]] || die "build for $arch failed"
  slices+=("$bin")
done

# ---- assemble ---------------------------------------------------------------------------------
stage=$(mktemp -d /tmp/pounce-package.XXXXXX)
trap 'rm -rf "$stage"' EXIT
app="$stage/Pounce.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "${slices[@]}" -output "$app/Contents/MacOS/Pounce"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUILD@/$BUILD_NUMBER/g" -e "s/@COMMIT@/$COMMIT/g" \
  Resources/Info.plist > "$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

# The toolchain adds an rpath to its own Swift runtime (CLT or /nix/store). The OS ships the
# runtime in /usr/lib/swift (macOS 14+), so drop every rpath that isn't relative to the bundle.
exe="$app/Contents/MacOS/Pounce"
rpaths() { otool -l "$1" | awk '/cmd LC_RPATH/ {getline; getline; print $2}'; }
while read -r rp; do
  [[ -z "$rp" || "$rp" == @* ]] && continue
  install_name_tool -delete_rpath "$rp" "$exe" 2>/dev/null || true
done < <(rpaths "$exe" | sort -u)
# Every remaining dylib must be an OS one.
if otool -L "$exe" | awk '/^\t/ {print $1}' | grep -vE '^(/usr/lib/|/System/Library/)'; then
  die "binary links non-system libraries (see above)"
fi

# ---- sign -------------------------------------------------------------------------------------
say "Signing ($IDENTITY)"
sign_args=(--force --sign "$IDENTITY" --options runtime --entitlements Resources/Pounce.entitlements)
[[ $sign_kind == developer-id ]] && sign_args+=(--timestamp)
[[ -n "${KEYCHAIN:-}" ]] && sign_args+=(--keychain "$KEYCHAIN")
codesign "${sign_args[@]}" "$app"
codesign --verify --strict --deep --verbose=2 "$app"

# ---- package ----------------------------------------------------------------------------------
name="Pounce-$VERSION"
zip="$OUT/$name.zip"
dmg="$OUT/$name.dmg"
rm -f "$zip" "$dmg"

make_dmg() {
  local src
  src=$(mktemp -d "$stage/dmg.XXXX")
  cp -R "$app" "$src/"
  ln -s /Applications "$src/Applications"
  hdiutil create -quiet -volname "Pounce $VERSION" -srcfolder "$src" -fs HFS+ -format UDZO -ov "$dmg"
  local dmg_args=(--force --sign "$IDENTITY")
  [[ $sign_kind == developer-id ]] && dmg_args+=(--timestamp)
  [[ -n "${KEYCHAIN:-}" ]] && dmg_args+=(--keychain "$KEYCHAIN")
  codesign "${dmg_args[@]}" "$dmg"
}

notary() {
  case $notarize in
    profile) xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m ;;
    api-key) xcrun notarytool submit "$1" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --timeout 30m ;;
  esac
}

if [[ $notarize != none ]]; then
  say "Notarizing"
  # Submitting the DMG notarizes the app inside it too; then staple both.
  if [[ "${SKIP_DMG:-}" == 1 ]]; then
    ditto -c -k --keepParent "$app" "$stage/submit.zip"
    notary "$stage/submit.zip"
  else
    make_dmg
    notary "$dmg"
    xcrun stapler staple "$dmg"
  fi
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
elif [[ "${SKIP_DMG:-}" != 1 ]]; then
  make_dmg
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

# ---- verify + summary -------------------------------------------------------------------------
say "Verifying"
check=$(mktemp -d "$stage/check.XXXX")
ditto -x -k "$zip" "$check"
codesign --verify --strict --deep "$check/Pounce.app"
"$check/Pounce.app/Contents/MacOS/Pounce" version
echo "spctl (informational; only Developer ID + notarized builds pass):"
spctl -a -vv -t exec "$check/Pounce.app" 2>&1 | sed 's/^/  /' || true

sums=("$name.zip"); [[ -f "$dmg" ]] && sums+=("$name.dmg")
(cd "$OUT" && shasum -a 256 "${sums[@]}" > SHA256SUMS)

say "Summary"
echo "  version     $VERSION (build $BUILD_NUMBER, commit $COMMIT)"
echo "  identity    $IDENTITY ($sign_kind)  notarized: $([[ $notarize != none ]] && echo yes || echo no)"
echo "  archs       $(lipo -archs "$exe")"
echo "  rpaths      $(rpaths "$exe" | tr '\n' ' ')"
for f in "$zip" "$dmg"; do [[ -f "$f" ]] && printf '  %-11s %s\n' "$(du -h "$f" | cut -f1)" "$f"; done
sed 's/^/  sha256      /' "$OUT/SHA256SUMS"
