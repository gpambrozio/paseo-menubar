# Source of truth for the cask published to gpambrozio/homebrew-tap. The tap's
# copy is generated from this file by .github/workflows/homebrew-cask.yml, which
# rewrites `version` and `sha256` from the release it is given -- so the two
# literals below are the last values synced by hand, not an authoritative record
# of the current release. Everything else in this file is authoritative, and the
# three lines most likely to be wrong are the three that were checked against a
# real build rather than inferred:
#
#   app          The bundle is PaseoIcon.app, not "Paseo Icon.app". productName
#                is "Paseo Icon", but electron-builder.yml sets
#                `executableName: PaseoIcon`, and that is what names the bundle
#                directory. render-cask.test.mjs asserts the two still agree.
#   depends_on   arch is not decoration. `npm run dist` builds for the host arch
#                only, so every published artifact is arm64; without this,
#                Homebrew installs an app that cannot launch on Intel.
#   url          The files on disk have a space ("Paseo Icon-0.1.0-arm64.dmg")
#                and the release assets have hyphens. electron-builder's own
#                publisher renames them, and the manual upload matches it by
#                hand. The workflow downloads this exact URL to checksum it, so
#                a rename breaks the build rather than shipping a 404.
#
# The token is paseo-menubar (the repo and package name) while the display name
# stays "Paseo Icon" (the app's own name). Homebrew keeps those separate on
# purpose; `name` is what `brew info` shows.
cask "paseo-menubar" do
  version "0.1.0"
  sha256 "b7843da2e2cabc56db02565818abe2ad5c9d0896b041228e8ee2b76c0c44d00d"

  url "https://github.com/gpambrozio/paseo-menubar/releases/download/v#{version}/Paseo-Icon-#{version}-arm64.dmg",
      verified: "github.com/gpambrozio/paseo-menubar/"
  name "Paseo Icon"
  desc "Menu-bar indicator for Paseo workspaces"
  homepage "https://github.com/gpambrozio/paseo-menubar"

  livecheck do
    url :url
    strategy :github_latest
  end

  # LSMinimumSystemVersion in the built bundle is 12.0. The bare symbol reads as
  # "exactly Monterey" but Homebrew resolves it to a minimum -- `brew info`
  # reports "macOS >= 12" -- and the `">= :monterey"` spelling is deprecated.
  depends_on macos: :monterey
  depends_on arch: :arm64

  app "PaseoIcon.app"

  # The app holds a tray icon and no window, so a plain `brew uninstall` would
  # leave it running with its menu bar item still there.
  uninstall quit: "br.eng.gustavo.paseo-menubar"

  # config.json lives in the userData directory, which Electron names from
  # productName -- "Paseo Icon", not the cask token. It holds TCP passwords and
  # relay keys, so `brew uninstall --zap` is the one that really removes them.
  zap trash: [
    "~/Library/Application Support/Paseo Icon",
    "~/Library/Preferences/br.eng.gustavo.paseo-menubar.plist",
    "~/Library/Saved Application State/br.eng.gustavo.paseo-menubar.savedState",
  ]
end
