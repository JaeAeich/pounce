#!/bin/sh
# Formatting and lint. `scripts/lint.sh --fix` rewrites files in place.
set -e
cd "$(dirname "$0")/.."
if [ "${1:-}" = "--fix" ]; then
  swift format -i -r Sources Tests Package.swift
  command -v nixfmt >/dev/null && nixfmt flake.nix nix/*.nix
  exit 0
fi
swift format lint --strict -r Sources Tests Package.swift
if command -v nixfmt >/dev/null; then nixfmt --check flake.nix nix/*.nix; fi
