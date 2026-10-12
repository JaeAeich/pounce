# Template for jaeaeich/homebrew-tap (Casks/pounce.rb). release.yml rewrites `version` and `sha256`.
#   brew install --cask jaeaeich/tap/pounce
cask "pounce" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/jaeaeich/pounce/releases/download/v#{version}/Pounce-#{version}.zip"
  name "Pounce"
  desc "Keyboard-driven clicking, scrolling and window navigation"
  homepage "https://github.com/jaeaeich/pounce"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Pounce only checks for updates and points at the release; upgrades go through brew.
  auto_updates false
  depends_on macos: ">= :sonoma"

  app "Pounce.app"
  # The executable re-execs through the symlink's target, so `pounce version` etc. see the bundle.
  binary "#{appdir}/Pounce.app/Contents/MacOS/Pounce", target: "pounce"

  # Releases are signed with a stable self-signed certificate but not notarized (no paid Apple
  # Developer account), so clear the download quarantine; otherwise Gatekeeper refuses to open it.
  # Fine in a personal tap (homebrew/cask wouldn't accept it).
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Pounce.app"], must_succeed: false
  end

  uninstall quit: "com.jaeaeich.pounce"

  zap trash: [
    "~/.config/pounce",
    "~/Library/Application Support/Pounce",
    "~/Library/Caches/com.jaeaeich.pounce",
    "~/Library/HTTPStorages/com.jaeaeich.pounce",
    "~/Library/Preferences/com.jaeaeich.pounce.plist",
    "~/Library/Saved Application State/com.jaeaeich.pounce.savedState",
  ]

  caveats <<~EOS
    Pounce needs Accessibility permission (System Settings > Privacy & Security > Accessibility).
    Updates keep that permission. If Pounce stops responding after an upgrade, turn it off and on
    again in that list.
  EOS
end
