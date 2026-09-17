# Source of truth for the cask published to gpambrozio/homebrew-tap. The tap's
# copy is generated from this file by .github/workflows/homebrew-cask.yml, which
# rewrites `version` and `sha256` from the release it is given -- so the two
# literals below are the last values synced by hand, not an authoritative record
# of the current release. Everything else in this file is authoritative, and the
# three lines most likely to be wrong are the three that were checked against a
# real build rather than inferred:
#
#   app          The bundle is PaseoIcon.app, not "Paseo Icon.app". BUNDLE_NAME
#                in scripts/native-bundle.mjs is what names the bundle
#                directory. native-bundle.test.mjs asserts the two still agree.
#   depends_on   Neither line is decoration. `npm run dist:native` builds for
#                the host arch only, so every published artifact is arm64;
#                without that, Homebrew installs an app that cannot launch on
#                Intel. The macos line has to track MIN_MACOS in
#                scripts/native-bundle.mjs, and scripts/check-cask-macos.mjs
#                checks the two agree, both at packaging time against the
#                built bundle and in the test suite against the plist the
#                script would write.
#   url          scripts/native-bundle.mjs writes the release assets with
#                hyphens directly ("Paseo-Icon-0.1.0-arm64.dmg"), so there is
#                no rename step left to describe. The workflow downloads this
#                exact URL to checksum it, so a name that drifts breaks the
#                build rather than shipping a 404.
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

  # LSMinimumSystemVersion in the built bundle is 14.0, declared in two places
  # that have to agree: `platforms` in PaseoIconPackage/Package.swift, and
  # MIN_MACOS in scripts/native-bundle.mjs, which writes the Info.plist. The
  # floor is 14 rather than the 13 the Electron build inherited because the app
  # uses the Observation framework.
  #
  # Two checks hold this symbol to that floor. scripts/native-bundle.test.mjs
  # compares it against the plist the packaging script would write, so a floor
  # raised without this line fails the suite; scripts/check-cask-macos.mjs
  # repeats the comparison against the real built bundle during packaging. The
  # failure they prevent is invisible to the maintainer: the cask installs
  # happily on the older macOS and the app then refuses to launch, on someone
  # else's machine.
  #
  # The bare symbol reads as "exactly Sonoma" but Homebrew resolves it to a
  # minimum -- `brew info` reports "macOS >= 14" -- and the `">= :sonoma"`
  # spelling is deprecated.
  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "PaseoIcon.app"

  # The app holds a tray icon and no window, so a plain `brew uninstall` would
  # leave it running with its menu bar item still there.
  uninstall quit: "br.eng.gustavo.paseo-menubar"

  # The native app keeps no state of its own beyond the login-item
  # registration, which SMAppService manages outside any file this stanza
  # could trash -- host credentials are read from the Paseo desktop app's own
  # storage, never copied here. The paths below are what the Electron build
  # left behind, named from productName -- "Paseo Icon", not the cask token --
  # and the bundle id the two builds share; they still apply to a
  # `brew uninstall --zap` on a machine that ran that build, and the native
  # app never recreates them.
  zap trash: [
    "~/Library/Application Support/Paseo Icon",
    "~/Library/Preferences/br.eng.gustavo.paseo-menubar.plist",
    "~/Library/Saved Application State/br.eng.gustavo.paseo-menubar.savedState",
  ]
end
