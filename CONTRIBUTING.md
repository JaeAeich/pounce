# Contributing

```sh
swift build                 # debug build (Swift 6, macOS 26 SDK)
./scripts/test.sh           # unit tests + end-to-end self-test
./scripts/test.sh --unit    # unit tests only
./scripts/install.sh        # build with Nix, sign, install to ~/Applications and relaunch
scripts/package.sh          # universal .app, .dmg and .zip in dist/
```

- Run `scripts/signing-setup.sh` once so local builds keep the same signature and macOS keeps the
  Accessibility permission across rebuilds.
- The self-test drives the real modes against invisible fixture windows; it never takes focus.
  Checks that need Accessibility run from Settings › About › Run Self-Test.
- `pounce snapshot <dir>` renders every window and overlay to PNG (used for `docs/`).
- `pounce doctor <bundle-id>` reports what Pounce can see in a running app.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org); releases are cut by
  release-please. See [docs/INSTALL.md](docs/INSTALL.md#signing-and-notarizing-releases) for signing.
