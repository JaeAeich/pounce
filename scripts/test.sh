#!/usr/bin/env bash
# Unit tests (swift-testing) + end-to-end self-test, using the host Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."

flags=()
# Command Line Tools ship swift-testing outside the default search paths.
clt=/Library/Developer/CommandLineTools
if [[ "$(xcode-select -p)" == "$clt" ]]; then
  F=$clt/Library/Developer/Frameworks
  L=$clt/Library/Developer/usr/lib
  flags=(-Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F"
         -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L"
         -Xswiftc -plugin-path -Xswiftc "$clt/usr/lib/swift/host/plugins/testing")
fi

echo "==> Unit tests"
swift test --disable-xctest ${flags[@]+"${flags[@]}"} 2>&1 | grep -E "^(✔|✘|􁁛|􀢄)|Test run|error:" | tail -n 25

# --unit: skip the self-test (it needs a GUI session + Accessibility, e.g. on CI runners).
[[ "${1:-}" == "--unit" ]] && exit 0

echo "==> Self-test (scans + drives a real window)"
swift build 2>&1 | grep -E "error:" || true
"$(swift build --show-bin-path)/Pounce" selftest
