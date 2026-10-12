# Pounce for Raycast

Run [Pounce](https://github.com/jaeaeich/pounce) modes from Raycast, so you can bind them to Raycast
hotkeys or aliases.

| Command | How it runs |
| --- | --- |
| Click, Scroll, Grid, Windows, Search Menu, Text, Mouse | `open pounce://<mode>` (starts Pounce if needed) |
| Repeat Last Action, Pause / Resume Shortcuts | the `pounce` CLI (Pounce must be running) |

The CLI is found at `/opt/homebrew/bin/pounce`, `/usr/local/bin/pounce`, `~/.nix-profile/bin/pounce`,
`/run/current-system/sw/bin/pounce`, `~/.local/bin/pounce`, or inside `Pounce.app` in `/Applications`
or `~/Applications`.

## Requirements

Pounce installed and granted Accessibility permission. See the
[install guide](https://github.com/jaeaeich/pounce/blob/main/docs/INSTALL.md).

## Development

```sh
npm install
npm run dev      # loads the extension into Raycast
npm run lint
npm run publish  # opens a PR against raycast/extensions
```
