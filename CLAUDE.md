# CLAUDE.md

Paseo Icon is a macOS menu-bar indicator for [Paseo](https://paseo.sh) workspaces. It
shows whether any workspace needs you, across every configured host, and deep-links into
the Paseo desktop app on click. It is a status indicator and launcher — it never runs
agents itself.

It mirrors the Paseo sidebar: same rows, same five state buckets, same labels. The state
comes from the daemon, never from a client-side derivation. The design docs explain why.

**The app is a Swift package.** `PaseoIconPackage/` holds everything that ships:
`PaseoIconCore` is the whole program and is tested without a menu bar, `PaseoIcon` is the
`MenuBarExtra` shell around it. What is left at the repository root is build tooling under
`scripts/`, plain `.mjs` that nothing compiles. The Electron app this replaced was deleted
at the end of the native parity plan.

It is a **separate project from the `getpaseo/paseo` repo** and depends on that project
only through published npm packages and supported surfaces. Nothing here can assume an
upstream change will land.

## The spec is the authority

`docs/superpowers/` holds seven documents. They are not equals:

| Document | Standing |
| --- | --- |
| `2026-08-16-standalone-menubar-app-design.md` | **Binding** for behaviour. Settles any disagreement about what the tray shows. |
| `2026-08-19-registry-sync-design.md` | **Binding.** Supersedes the parts of the doc above that describe `config.json` as the source of hosts and clipboard pairing as the way to add one. |
| `2026-09-16-native-swift-app-design.md` | **Binding** for the native build: the wire contract, the relay E2EE contract, the module map. Changes how the app is built, not what it shows. |
| `plans/2026-09-16-native-app-parity.md` | Historical. Plan 2 of the native build, executed 2026-09-16. Its code blocks were refreshed from the committed sources as review changed them, but the committed code wins. |
| `plans/2026-09-16-native-app-foundation.md` | Historical. Plan 1 of the native build. |
| `2026-08-16-paseo-icon-implementation-plan.md` | Historical. Describes the deleted Electron app. Contains known defects. |
| `plans/2026-08-19-registry-sync.md` | Historical. Describes the deleted Electron app. |

Read the design docs before non-trivial work. Do **not** implement from a plan: each was
written before its code, and review changed both of them afterwards.

## Where logic goes

The rule that shapes this codebase: **if it does not touch AppKit or SwiftUI, it does not
belong in the app target.** Everything else is pure or takes its collaborators by
injection, and is tested without a menu bar. That is why 322 tests can cover a menu bar
app that no agent can see.

| Path under `PaseoIconPackage/Sources/` | Owns |
| --- | --- |
| `PaseoIconCore/ErrorText.swift` | `MessageError` and `errorText`, the one narrowing every failure path shares. |
| `PaseoIconCore/Config/HostEntry.swift` | The host shapes and their fingerprint. No I/O. |
| `PaseoIconCore/Config/AppConfig.swift` | The validated host set. The only way a config is built. |
| `PaseoIconCore/Registry/Binary.swift` | Varints, CRC32C, LevelDB's checksum mask. |
| `PaseoIconCore/Registry/Snappy.swift` | The raw snappy decoder LevelDB blocks need. |
| `PaseoIconCore/Registry/SSTable.swift` | One `.ldb`: footer, index, blocks, checksums. |
| `PaseoIconCore/Registry/WAL.swift` | One `.log`: record framing and batches. |
| `PaseoIconCore/Registry/LocalStorage.swift` | Chromium localStorage key framing and value encoding. |
| `PaseoIconCore/Registry/FileSystem.swift` | The two filesystem calls the reader makes, injected. |
| `PaseoIconCore/Registry/LevelDBReader.swift` | A LevelDB directory: newest sequence wins. |
| `PaseoIconCore/Registry/PaseoRegistry.swift` | Locate the Paseo app, validate profiles, map to `HostEntry`. |
| `PaseoIconCore/Registry/RegistrySession.swift` | Watch, debounce, poll, fingerprint, apply, own the error row. |
| `PaseoIconCore/Registry/RegistryWatcher.swift` | Keeping the directory watch attached. |
| `PaseoIconCore/Registry/FSEventsWatch.swift` | The production watch: FSEvents with file-level events. |
| `PaseoIconCore/Daemon/*` | One host: connect, handshake, seed, subscribe, reconnect. **All wire and E2EE code lives here.** |
| `PaseoIconCore/Daemon/HostFleet.swift` | The set of connections: apply, isolate, retry, web fallback. |
| `PaseoIconCore/Store/HostStore.swift` | Replicated workspaces and agents, keyed by host. The `HostSink`. |
| `PaseoIconCore/Tray/TrayViewModel.swift` | Store state to icon, count, sections, click targets, host names. |
| `PaseoIconCore/Tray/MenuModel.swift` | The menu as data. Every row, label, and rule. |
| `PaseoIconCore/Launch/OpenPaseo.swift` | Deep links, with the browser fallback. |
| `PaseoIcon/TrayIcons.swift` | The five bucket glyphs as template images. |
| `PaseoIcon/MenuBarLabel.swift` | The rendered menu bar item: glyph plus count. |
| `PaseoIcon/MenuContent.swift` | Renders `[MenuItem]`. Decides nothing. |
| `PaseoIcon/AppCoordinator.swift` | The object graph, login item, alerts, `NSWorkspace`. |
| `PaseoIcon/PaseoIconApp.swift` | The `MenuBarExtra` scene and the app delegate. |

`HostFleet` and `RegistrySession` exist because the first cut put their logic in the app
layer, where nothing could test it. If you find yourself adding a decision to
`AppCoordinator`, that is the signal to extract instead.

## Critical rules

- **Never create a window.** `MenuBarExtra` in menu style is the whole interface, and the
  style is stated rather than inferred for that reason. A preferences window is
  deliberately deferred.
- **The wire is pinned to `@getpaseo/protocol` 0.4.0 and `protocolVersion: 1`**, and the
  Swift structs are a hand-written copy of that slice. Paseo guarantees that old clients
  parse messages from new daemons; that guarantee is what makes the copy safe. The npm
  packages that remain are test harnesses, not dependencies of the app.
- **`@MainActor` where the code says so, and callbacks that cross a thread must hop.**
  FSEvents schedules on the main queue and re-enters through `MainActor.assumeIsolated`;
  `NSWorkspace`'s completion arrives anywhere and hops with `Task { @MainActor in }`. An
  annotation that silences the compiler without making the guarantee is a bug.
- **Collaborators are injected, never reached for.** The reader takes a `FileSystem`, the
  session takes its watch and its read, the fleet takes a connection factory. That is what
  makes the whole chain testable without a daemon, a menu bar, or a real registry.
- **Never crash the tray.** No force unwraps, no `try!`, no unchecked index arithmetic, and
  no arithmetic on untrusted numbers before they are bounded. A Swift trap is uncatchable
  and takes the menu bar item with it, leaving nothing to click and nothing to quit. Two
  such bugs have already been fixed here, one of them a fix that stopped one line short of
  the addition that actually overflowed.
- **No silent caps.** Any truncated list renders a visible overflow row, and every row
  carries its own identity — SwiftUI's `ForEach` keys on it, so two rows that collide
  become one, which is a silent cap by another route. That has been fixed twice.
- **Never derive a workspace's state.** Render `WorkspaceDescriptor.status`, the bucket the
  daemon computed. The rule lives in the daemon and changes there; a second copy here is a
  second answer, and no test in either repo would catch the day they diverge. A bucket this
  build does not know is named in its own row, never guessed at and never dropped.
- **Section order and labels are copied, not invented.** They come from
  `STATUS_BUCKET_ORDER` and `STATUS_BUCKET_LABELS` in
  `packages/app/src/hooks/sidebar-status-view-model.ts` upstream. Paseo's glossary rule
  is "UI label wins, no synonyms", so the tray says what the sidebar says.
- **The daemon's order is the order.** `fetch_workspaces_request` sorts by
  `status_priority`, and the store preserves that with an insertion-ordered map because the
  menu caps each section. Re-sorting here shows a different fifteen than the sidebar does.
- **Hosts come from the Paseo desktop app's Chromium localStorage, and nothing
  else.** The record is `@paseo:daemon-registry` under origin `paseo://app`, in
  `~/Library/Application Support/Paseo/Local Storage/leveldb`. This is an
  unsupported surface and it is the app's only source of hosts: `config.json`
  is neither read nor written, and there is no pairing flow. When the tray comes
  up empty after a Paseo update, check three things in order — the record key,
  the value's encoding tag, and the block compression type. The reader refuses
  an unknown compression type by design rather than guessing, so that failure
  names itself. See `docs/superpowers/2026-08-19-registry-sync-design.md`.
- **The LevelDB reader never takes the lock and never writes.** It reads while
  Chromium writes, so every block's CRC32C is verified before it is parsed and
  an unreadable file is skipped rather than failing the whole read. Removing a
  checksum check to "make it work" converts a torn read into silently wrong
  credentials. A file that is gone (`ENOENT`) by the time it is read means the
  listing was stale and the directory is listed again, winner or not; any other
  read error is damage. Both distinctions were bugs once.
- **One bad profile never costs another host.** The registry is parsed one
  profile at a time and a profile the tray cannot use is named in the error
  row; only a record that is not an array at all fails the whole read. The
  desktop app is not version-pinned, so a connection type it adds tomorrow has
  to reduce to "this host has no usable connection", not to zero hosts.

## Working here

```bash
SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install   # Homebrew libvips breaks sharp's prebuild
npm test                                    # vitest (scripts) then swift test
swift test --package-path PaseoIconPackage  # 322 Swift tests, 32 suites
npx vitest run                              # 43 tests, 4 files — build tooling only
npm run typecheck
npm run icons                               # tray glyphs and the app icon
npm run fixtures:registry                   # LevelDB fixtures
npm run fixtures:e2ee                       # the tweetnacl E2EE vectors
npm run dist -- --version 0.4.0 --identity "Developer ID Application: ..."
PASEO_ICON_RELAY_E2E=1 swift test --package-path PaseoIconPackage --filter RelayEndToEndTests
swift run --package-path PaseoIconPackage PaseoIconProbe --offer '<pairing url>'
```

- **The tray glyphs are generated, not committed.** `npm run icons` writes them into
  `PaseoIconPackage/Sources/PaseoIcon/Resources/TrayIcons/`, which is git-ignored except
  for a `.gitkeep`. The keep file is load-bearing: `Package.swift` declares that directory
  as a `.copy` resource, and SwiftPM refuses to build a target whose declared resource
  path does not exist — so ignoring the whole directory makes `swift build` *and*
  `swift test` fail on a fresh clone with an error that never mentions the generator. An
  empty directory builds fine and `TrayIcons.preflight()` names the real problem at launch.
- **The glyphs load at both scales.** `image(for:)` adds the 1x and `@2x` files as two
  representations of one 16pt image. Loading a single file gives a single representation
  and 1x art on every Retina menu bar, which is what the Electron image loader used to
  prevent by itself.
- **`classic-level` is a devDependency, used only by `fixtures:registry`.** It opens a
  real LevelDB to generate the `.ldb`/`.log` fixtures the registry reader is tested
  against; the app never links it. It must never become a dependency of the app — the
  reader that ships is hand-written Swift, and a native LevelDB binding would defeat the
  reason it exists.
- **Do not launch the app to check your work.** It writes real state under
  `~/Library/Application Support/`, and it shares a bundle id with any installed copy.
- **There is no linter.** Don't assume `npm run lint` exists.
- **Integration tests boot a real daemon** from `@getpaseo/server`, spawned as `node` by
  `scripts/swift-test-daemon.mjs`, so the root `npm install` has to have run. They are slow
  by design. Always `listen: "127.0.0.1:0"` so the OS picks the port — a fixed port
  collides with the developer's own daemon on 6767.
- **The relay end-to-end test is opt-in** because it needs `wrangler` from
  `scripts/relay-harness`, installed separately. The daemon and echo harnesses need nothing
  beyond the root install.

## Distribution

`brew install --cask gpambrozio/tap/paseo-menubar` is the install path. The cask's
source of truth is `packaging/homebrew/paseo-menubar.rb` **here**, not the copy in
the tap — `.github/workflows/homebrew-cask.yml` renders this file and pushes the
result to `gpambrozio/homebrew-tap`, so an edit made in the tap is overwritten by
the next release.

- **`npm run dist` regenerates the icons, then runs `scripts/native-bundle.mjs`.** The
  icon step is part of the script and not a thing to remember: the glyphs are generated
  rather than committed, so packaging without them produces an app with no menu bar image.
  The script builds the Swift release binary, assembles `PaseoIcon.app` around it, checks
  the cask against the Info.plist it just wrote, signs with the identity you pass,
  notarizes and staples the app, writes the dmg and the zip, then signs and notarizes the
  dmg as well. That order matters: the Electron build wrote its update metadata before
  stapling, so the recorded size and checksum described a file that no longer existed.
  Nothing here measures anything before the last mutation.
- **The dmg gets its own signature and ticket.** Homebrew never needs it — it mounts the
  image and copies the stapled app out — but someone who downloads the dmg from the
  releases page opens the image itself, and an unsigned one earns a Gatekeeper warning
  before they ever reach the app.
- **The cask token is `paseo-menubar`, the display name is `Paseo Icon`, and the
  bundle is `PaseoIcon.app`.** All three are correct and all three are different.
  `BUNDLE_NAME` in `scripts/native-bundle.mjs` is what names the bundle directory, and
  `scripts/render-cask.test.mjs` asserts the cask's `app` stanza still matches it, because
  renaming that field breaks every `brew install` with an "unable to locate app" long
  after the release ships.
- **The macOS floor is 14 and lives in four places that must agree**: `platforms` in
  `PaseoIconPackage/Package.swift`, `MIN_MACOS` in `scripts/native-bundle.mjs`,
  `depends_on macos: :sonoma` in the cask, and the sentence in `README.md`. Three checks
  hold them together — `native-bundle.test.mjs` compares the script against the cask and
  the README, and `npm run dist` calls `assertCaskMatchesBundle` from
  `scripts/check-cask-macos.mjs` against the Info.plist of the bundle it just assembled. The floor is 14 rather than 13 because the app uses the Observation
  framework. The failure they prevent is invisible to the maintainer: the cask installs
  happily on the older macOS and the app then refuses to launch, on someone else's machine.
- **Release assets are hyphenated** — `Paseo-Icon-0.4.0-arm64.dmg`. The packaging script
  writes those names directly, so the rename electron-builder's publisher used to do is
  gone. The tap workflow downloads that exact URL to checksum the bytes, so a drift breaks
  the build rather than shipping a 404.
- **Run the workflow by hand after uploading the artifacts.** Uploads are manual,
  so `release: published` can fire while the dmg is still going up. The workflow
  downloads the exact url the cask names and checksums the bytes rather than
  trusting the API's digest field.
- **`scripts/` is build tooling and never ships**, so it is plain `.mjs`. It is still
  tested: `vitest.config.ts` includes `scripts/**/*.test.mjs`. `render-cask.mjs` throws
  rather than no-op when a substitution finds no match — a silent no-op there publishes a
  cask that pins the old checksum against the new version, which fails every user's install
  while the workflow stays green.
- **`HOMEBREW_TAP_TOKEN` is a fine-grained PAT and it expires.** `GITHUB_TOKEN` is
  scoped to this repo and cannot write to the tap, so the workflow uses a PAT with
  `contents: write` on `gpambrozio/homebrew-tap` only. When it lapses the run fails
  at "Check out the tap" with a permissions error that says nothing about expiry —
  regenerate it at github.com/settings/personal-access-tokens and re-run
  `gh secret set HOMEBREW_TAP_TOKEN --repo gpambrozio/paseo-menubar`. The workflow
  still degrades to printing the cask when the secret is absent entirely, but an
  *expired* secret is present, so that guard does not catch this.
- **Re-running against the current release is a safe test.** Rendering is
  idempotent, so a dispatch for a tag the tap already serves reaches "Tap already
  current" and pushes nothing.
- **Verify a cask change by tapping it, not by reading it.** `brew style` on a
  loose file reports Sorbet and `frozen_string_literal` offenses that do not apply
  to casks in a tap; `brew audit --cask --online` and `brew livecheck` are the real
  checks, and the deprecated `depends_on macos: ">= :monterey"` spelling was caught
  this way and not by review.

## Three things this project learned the hard way

**Mutate before you claim coverage.** Test evidence here has failed to survive independent
re-running more than once: a RED transcript from an incomplete revert, a test that passed
against the very mutation it targeted, and a test written in response to a crash that was
shaped to pass. Before reporting a test as covering something, break the thing it covers
and confirm it goes red.

**Fixing a conversion is not fixing the arithmetic that consumes it.** The SSTable reader
was given a bounds check on a varint that could not fit in an `Int`, and the very next line
still added three of those numbers together and overflowed. Twice now, a fix has landed one
line away from the bug it was meant to close. When you fix a value, look at every use of it.

**No agent can see a menu bar.** Icon appearance at Retina scale, click-through, the login
item's checkmark, and a real relay host are verifiable only by a human running the app. Say
so plainly rather than narrating a check you did not perform.

## Known issues

- Past 200 agents on one host, an agent can be capped out of the seed and its workspace
  then opens in the browser instead of the app. The daemon's `status_priority` scoring
  has no `requiresAttention` branch, so an agent whose attention reason is `finished`
  sorts last and goes first. Closing this needs a daemon-side sort key. The cap stays
  visible in the menu, so nothing is lost silently.
- **The native app and the deleted Electron app share a bundle id.** The single-instance
  guard means they cannot run at the same time, so an installed copy of the old app has to
  be replaced rather than run alongside. `brew upgrade` does that; a hand-placed copy does
  not.
- The `release` workflow neither signs nor publishes. The repo has no Actions secrets, so
  a `v*` tag skips packaging with a notice — and even with the three `APPLE_*` secrets,
  `codesign` reads the Developer ID certificate from a keychain that a runner does not
  have. Closing this needs the secrets *and* a step that imports a base64 `.p12` into a
  temporary keychain.
- **CI has never run green.** The workflows moved to `macos-15` because
  `swift-tools-version: 6.1` is unreadable by the Xcode 15 that `macos-14` carries, but
  with no secrets and no successful run, the toolchain floor on the runner is unverified.
- Releases are `arm64` only — the packaging script builds for the host arch, so there is no
  Intel or universal artifact.
- There is no auto-updater, and the script writes no update metadata. Adding one means
  generating that metadata after stapling, not before.
- The registry reader depends on Chromium's private on-disk format. It handles
  uncompressed and snappy blocks; a future Chromium that writes zstd will make
  the tray show a named compression error until the reader learns that codec.
