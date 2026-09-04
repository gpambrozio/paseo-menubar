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
#   depends_on   Neither line is decoration. `npm run dist` builds for the host
#                arch only, so every published artifact is arm64; without that,
#                Homebrew installs an app that cannot launch on Intel. The macos
#                line has to track the floor Electron imposes, which moves on
#                its own -- `npm run dist` runs scripts/check-cask-macos.mjs
#                against the built bundle and fails when the two disagree.
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

  url "https://github.com/gpambrozio/paseo-menubar/releases/download/v#{version}/Paseo-Icon-#{version}-arm64.dmg"
  name "Paseo Icon"
  desc "Menu-bar indicator for Paseo workspaces"
  homepage "https://github.com/gpambrozio/paseo-menubar"

  livecheck do
    url :url
    strategy :github_latest
  end

  # LSMinimumSystemVersion in the built bundle is 13.0. Nothing here sets that
  # floor: electron-builder.yml leaves `minimumSystemVersion` unset, so the
  # bundle inherits whatever Electron requires, and an Electron major can raise
  # it with no diff in this repo at all. Electron 44 did exactly that, moving it
  # from 12.0 to 13.0. scripts/check-cask-macos.mjs reads the floor out of the
  # built bundle during `npm run dist` and fails the release when this symbol
  # disagrees, because the failure it prevents is invisible to the maintainer:
  # the cask installs happily on the older macOS and the app then refuses to
  # launch, on someone else's machine. It runs at packaging time and not in the
  # test suite because as of Electron 44 the package has no postinstall, so
  # `npm ci` leaves no binary for a test to read.
  #
  # The bare symbol reads as "exactly Ventura" but Homebrew resolves it to a
  # minimum -- `brew info` reports "macOS >= 13" -- and the `">= :ventura"`
  # spelling is deprecated.
  depends_on macos: :ventura
  depends_on arch: :arm64

  app "PaseoIcon.app"

  # The app holds a tray icon and no window, so a plain `brew uninstall` would
  # leave it running with its menu bar item still there.
  uninstall quit: "br.eng.gustavo.paseo-menubar"

  # The userData directory is named from productName -- "Paseo Icon", not the
  # cask token. The app keeps no host credentials of its own (they are read from
  # the Paseo desktop app's storage), so this is Electron's own state only.
  zap trash: [
    "~/Library/Application Support/Paseo Icon",
    "~/Library/Preferences/br.eng.gustavo.paseo-menubar.plist",
    "~/Library/Saved Application State/br.eng.gustavo.paseo-menubar.savedState",
  ]
end
