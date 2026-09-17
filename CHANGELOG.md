# Changelog

Notable changes to Paseo Icon. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries describe what changed for someone running the app. Refactors, tests, and
documentation are left to the git history.

## [Unreleased]

**This release requires macOS 14 (Sonoma) or later.** Earlier releases ran on
macOS 13.

### Changed

- The app is now a native Swift menu-bar app rather than an Electron one. It
  reads the same host registry, shows the same five state buckets with the same
  labels and order, opens the same deep links, and installs through the same
  Homebrew cask, so there is nothing to reconfigure. It launches faster and uses
  a fraction of the memory.
- A workspace in a state this version does not recognise now gets its own row
  saying so. It used to disappear, which made a busy fleet look idle after a
  Paseo update added a state.
- The menu bar glyph is drawn at Retina scale. It was being drawn at half
  resolution on every Retina display.

### Fixed

- A corrupted entry in the desktop app's storage could make the menu bar item
  vanish on every launch, with no error to explain it. Those reads are now
  bounded and report as a named error row.
- Two menu rows that happened to read the same could collapse into one, hiding
  an overflow or truncation notice. Each row now carries its own identity.

## [0.3.0] — 2026-09-03

**This release requires macOS 13 or later.** Earlier releases ran on macOS 12.

### Changed

- Updated to Electron 44, which is what raises the macOS requirement. If you are
  on macOS 12, stay on 0.2.0: Homebrew will not offer you this version, and a
  manually installed copy will not launch.

## [0.2.0] — 2026-09-03

Hosts now come from the Paseo desktop app instead of from a config file of this
app's own. There is nothing to configure and nothing to pair.

### Added

- Install with Homebrew: `brew install --cask gpambrozio/tap/paseo-menubar`.

### Changed

- The host list is read from the Paseo desktop app's own storage, so the tray
  shows exactly the hosts the app knows about, and picks up additions and
  removals without a restart.
- The **Working** bucket uses a sport-shoe icon, matching the Paseo sidebar.
- A host that cannot be read is reported as a `Configuration error` row rather
  than being dropped, and one unreadable host no longer costs you the others.

### Removed

- **The app's own `config.json` host list.** An existing file is left on disk
  untouched, but it no longer has any effect. Hosts paired in the Paseo desktop
  app appear automatically; hosts that only ever existed in this file will not.
- **The clipboard pairing flow** and its menu item. Pair hosts in the Paseo
  desktop app instead.

### Fixed

- A torn read of the desktop app's storage — the app writing while the tray
  reads — no longer yields a stale host list in silence.
- The storage watcher is re-established if it dies, so host changes are still
  picked up after the desktop app is reinstalled or updated.
- Reordering hosts in the desktop app no longer forces every connection to be
  rebuilt.
- Two hosts claiming the same daemon are rejected instead of quietly shadowing
  each other.

## [0.1.0] — 2026-08-17

First release.

### Added

- A menu-bar icon showing the most urgent bucket across every host, badged with
  how many workspaces are in it. Only **Needs input**, **Failed**, and **Ready
  to review** are counted, so the badge clears once the rest is just running.
- A menu grouping workspaces into the same five buckets as the Paseo sidebar,
  with the sidebar's own labels and order.
- Clicking a workspace opens it in the Paseo desktop app, falling back to the
  host's web UI when the app cannot take the link.
- A per-host connection status row, so a daemon that has gone away is visible
  rather than silently missing.
- Signed and notarized builds of both the app and the disk image, so Gatekeeper
  opens them without a right-click detour. Apple Silicon only, macOS 12 or later.

[0.3.0]: https://github.com/gpambrozio/paseo-menubar/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/gpambrozio/paseo-menubar/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/gpambrozio/paseo-menubar/releases/tag/v0.1.0
