# Installing Pounce

Pounce needs macOS 14 (Sonoma) or later and runs on Apple silicon and Intel (universal binary).
After installing, open it once and grant **Accessibility** in System Settings > Privacy & Security.
Text (OCR) mode also asks for **Screen Recording**.

- [DMG / zip](#dmg-or-zip)
- [Homebrew](#homebrew)
- [Nix](#nix)
- [From source](#from-source)
- [Gatekeeper and unsigned builds](#gatekeeper-and-unsigned-builds)
- [Permissions after updating](#permissions-after-updating)
- [Signing and notarizing releases](#signing-and-notarizing-releases)

## DMG or zip

Download `Pounce-<version>.dmg` (or `.zip`) from
[Releases](https://github.com/jaeaeich/pounce/releases), drag **Pounce** to **Applications**, open it.
Checksums are in `SHA256SUMS`:

```sh
shasum -a 256 -c SHA256SUMS --ignore-missing
```

Optional CLI: `ln -s /Applications/Pounce.app/Contents/MacOS/Pounce /usr/local/bin/pounce`
(symlinks work; the binary finds its app bundle through the link).

Pounce checks GitHub for a newer release at most once a day (a single anonymous request to
`api.github.com`; nothing else is sent) and only links to the download. Turn it off in Settings, or
set `POUNCE_NO_UPDATE_CHECK=1`. Nix installs never check.

## Homebrew

```sh
brew install --cask jaeaeich/tap/pounce
```

This installs `Pounce.app` to `/Applications` and the `pounce` CLI. Upgrade with
`brew upgrade --cask pounce`; `brew uninstall --zap --cask pounce` also removes the config and
preferences.

## Nix

```sh
nix run github:jaeaeich/pounce            # try it
nix profile install github:jaeaeich/pounce
```

nix-darwin / Home Manager modules are exported as `darwinModules.default` and
`homeManagerModules.default`. Both install the app and start it at login; `settings` is optional and
uses the same keys as `config.toml` (Settings becomes read-only):

```nix
{
  inputs.pounce.url = "github:jaeaeich/pounce";

  # nix-darwin: modules = [ inputs.pounce.darwinModules.default ];
  # Home Manager: imports = [ inputs.pounce.homeManagerModules.default ];
  services.pounce = {
    enable = true;
    settings = {
      shortcuts.hint = "hyper+f";
      hints.theme = "dark";
      general.hyper_key = true;
    };
  };
}
```
 Nix builds are not signed with a stable
identity, so macOS may ask for Accessibility again after each rebuild; `scripts/install.sh` signs
the build with a local certificate to avoid that.

## From source

Requires Swift 6 and the macOS 26 SDK (Xcode 26 or the matching Command Line Tools).

```sh
git clone https://github.com/jaeaeich/pounce && cd pounce
scripts/signing-setup.sh     # once: self-signed "Pounce Local Signing" cert, keeps the TCC grant stable
scripts/package.sh           # universal, signed Pounce.app -> dist/Pounce-<version>.{zip,dmg}
```

Or `swift build && .build/debug/Pounce` for development, and `scripts/test.sh` for the tests.

`scripts/package.sh` picks a signing identity automatically: a `Developer ID Application`
certificate if one is in the keychain, else `Pounce Local Signing`, else ad-hoc. Override with
`IDENTITY=...`; set `VERSION`, `BUILD_NUMBER`, `COMMIT`, `OUT`, `ARCHS` or `SKIP_DMG=1` as needed.

## Gatekeeper and unsigned builds

Releases are signed with a stable self-signed certificate but not notarized by Apple. Installing
with **Homebrew** handles this for you (the cask clears the download quarantine). A downloaded
DMG or zip is blocked on first open:

1. Open Pounce; dismiss the "cannot be opened" / "Apple could not verify" dialog.
2. System Settings > Privacy & Security, scroll down, click **Open Anyway** next to Pounce, confirm.

Or remove the quarantine flag: `xattr -dr com.apple.quarantine /Applications/Pounce.app`.
(Right-click > Open no longer bypasses Gatekeeper on macOS 15+.)

## Permissions after updating

macOS ties the Accessibility grant to the app's code signature. Updates signed with the same
certificate keep it. If the certificate changes (for example from a source build signed with
"Pounce Local Signing" to an official Developer ID release, or after an ad-hoc build), Pounce shows
as enabled but doesn't work: remove it from the Accessibility list with **−**, then re-add it or
relaunch Pounce and grant again. `tccutil reset Accessibility com.jaeaeich.pounce` does the same.

## Signing and notarizing releases

Pounce needs no entitlements beyond the hardened runtime (`Resources/Pounce.entitlements` is empty:
no sandbox, no Apple Events). The Mac App Store is not an option (Accessibility + event taps are
not allowed in the sandbox).

### One-time setup

1. Join the Apple Developer Program (paid).
2. Create a **Developer ID Application** certificate (Xcode > Settings > Accounts > Manage
   Certificates, or developer.apple.com > Certificates with a CSR from Keychain Access).
   Export it with its private key as a `.p12` with a password.
3. Create an **App Store Connect API key** (App Store Connect > Users and Access > Integrations >
   App Store Connect API, role *Developer*). Note the key id and issuer id; download `AuthKey_<id>.p8`.

### Locally

```sh
security import DeveloperID.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
xcrun notarytool store-credentials pounce-notary \
  --key AuthKey_XXXX.p8 --key-id XXXX --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
NOTARY_PROFILE=pounce-notary scripts/package.sh
# or: ASC_KEY_PATH=AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=... scripts/package.sh
spctl -a -vv /tmp/check/Pounce.app   # expect "accepted, source=Notarized Developer ID"
```

With a Developer ID identity the script signs with `--options runtime --timestamp`, builds the DMG,
notarizes it (which covers the app inside), staples the DMG and the app, then zips the stapled app.

### GitHub Actions

`.github/workflows/release-please.yml` keeps a release PR open from Conventional Commits
(`feat:`, `fix:`, `feat!:`); merging it bumps `version.txt` and `CHANGELOG.md`, tags `vX.Y.Z` and
runs `release.yml`, which packages, uploads the DMG, zip and `SHA256SUMS` to the release and
updates the Homebrew tap. Repository secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | `base64 -i DeveloperID.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` password |
| `ASC_KEY_ID` | API key id |
| `ASC_ISSUER_ID` | API issuer id |
| `ASC_KEY_P8` | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `HOMEBREW_TAP_TOKEN` | fine-grained PAT, *Contents: read and write* on `jaeaeich/homebrew-tap` |

Without the certificate secrets the release is ad-hoc signed and not notarized (users then need
the Gatekeeper steps above). Without `HOMEBREW_TAP_TOKEN` the tap update is skipped. The tap repo
`jaeaeich/homebrew-tap` needs a `Casks/` directory; the template is `packaging/homebrew/pounce.rb`.
