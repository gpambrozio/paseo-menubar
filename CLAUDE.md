# CLAUDE.md

Paseo Icon is a macOS menu-bar indicator for [Paseo](https://paseo.sh) workspaces. It
shows whether any workspace needs you, across every configured host, and deep-links into
the Paseo desktop app on click. It is a status indicator and launcher — it never runs
agents itself.

It mirrors the Paseo sidebar: same rows, same five state buckets, same labels. The state
comes from the daemon, never from a client-side derivation. The design doc explains why.

It is a **separate project from the `getpaseo/paseo` repo** and depends on that project
only through published npm packages and supported surfaces. Nothing here can assume an
upstream change will land.

## The spec is the authority

`docs/superpowers/` holds two documents. They are not equals:

| Document | Standing |
| --- | --- |
| `2026-08-16-standalone-menubar-app-design.md` | **Binding.** Settles any disagreement. |
| `2026-08-16-paseo-icon-implementation-plan.md` | Historical. Contains known defects. |

Read the design doc before non-trivial work. Do **not** implement from the plan: it was
written before the code and review caught four spec requirements it never mentioned, a
deep-link string that could not parse, an auth classifier that was unreachable by
construction, and a config write that left a permission window. It is kept because it
records why things are shaped the way they are, not because it is correct.

## Where logic goes

The rule that shapes this codebase: **if it does not touch Electron, it does not belong in
`src/main.ts`.** Electron appears in exactly two modules — `src/main.ts` and
`src/tray/tray-presenter.ts`. Everything else is pure or takes its collaborators by
injection, and is tested without an Electron harness.

| Module | Owns |
| --- | --- |
| `src/main.ts` | Wiring only. Lifecycle, tray creation, dialogs, clipboard, `shell`, menu handlers. |
| `src/config/host-config.ts` | Read, write, and watch `config.json`. |
| `src/config/config-session.ts` | Config lifecycle: first-run seed, reload, add-host, which of the two errors wins. |
| `src/config/pairing.ts` | Pairing URL to host entry. |
| `src/daemon/host-connection.ts` | One host: connect, seed, subscribe, reconnect, report status. **All SDK use lives here.** |
| `src/daemon/host-fleet.ts` | The set of connections: apply a config, isolate a bad entry, retry, serialize rebuilds. |
| `src/daemon/host-store.ts` | Replicated workspaces and agents, keyed by host. |
| `src/tray/view-model.ts` | Store state to icon, count, sections, click targets, and host display names. |
| `src/tray/menu-template.ts` | View model to Electron menu template. |
| `src/launch/open-paseo.ts` | Deep link, with a browser fallback. |

`host-fleet.ts` and `config-session.ts` exist because the first cut put their logic in
`main.ts`, where nothing could test it. If you find yourself adding a decision to
`main.ts`, that is the signal to extract instead.

## Critical rules

- **Never create a `BrowserWindow`.** `Tray` and `Menu` are main-process APIs; this app
  needs no web contents. A preferences window is deliberately deferred.
- **The SDK is pinned exactly** — `@getpaseo/client`, `@getpaseo/protocol`, and
  `@getpaseo/server` at `0.4.0`, no caret. Paseo guarantees that old clients parse
  messages from new daemons; drifting the client forward voids the reasoning that makes
  pinning safe.
- **Use `DaemonClient` from `@getpaseo/client/internal/daemon-client`, not
  `createPaseoClient`.** The public wrapper does not expose `serverId`, and deep links
  need it; `getLastServerInfoMessage()` does. Keep that import in `host-connection.ts` so
  an SDK change lands in one file.
- **Never crash the tray.** Invalid config keeps the last known-good state and surfaces a
  `Configuration error` row. A `void`-ed promise that can reject is a bug — Node throws on
  unhandled rejections, and two such crashes have already been fixed here.
- **No silent caps.** Any truncated list renders a visible overflow row.
- **Never derive a workspace's state.** Render `WorkspaceDescriptorPayload.status`, the
  bucket the daemon computed. The rule lives in the daemon and changes there; a second
  copy here is a second answer, and no test in either repo would catch the day they
  diverge.
- **Section order and labels are copied, not invented.** They come from
  `STATUS_BUCKET_ORDER` and `STATUS_BUCKET_LABELS` in
  `packages/app/src/hooks/sidebar-status-view-model.ts` upstream. Paseo's glossary rule
  is "UI label wins, no synonyms", so the tray says what the sidebar says.
- **`config.json` is written `0600`** via temp-file + `rename()`. It holds TCP passwords
  and relay keys, and the app's own watcher reads it.

## Working here

```bash
SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install   # Homebrew libvips breaks sharp's prebuild
npx vitest run                              # 181 tests, 10 files
npm run typecheck
```

- **Do not launch the app to check your work.** `electron .` writes a real `config.json`
  into `~/Library/Application Support/Paseo Icon/`.
- **`npm run dist` takes minutes** and downloads Electron binaries. Don't run it casually.
- **There is no linter.** Don't assume `npm run lint` exists.
- **Integration tests boot a real daemon** in-process from `@getpaseo/server`. They are
  slow by design. Always `listen: "127.0.0.1:0"` so the OS picks the port — a fixed port
  collides with the developer's own daemon on 6767.

## Distribution

`brew install --cask gpambrozio/tap/paseo-menubar` is the install path. The cask's
source of truth is `packaging/homebrew/paseo-menubar.rb` **here**, not the copy in
the tap — `.github/workflows/homebrew-cask.yml` renders this file and pushes the
result to `gpambrozio/homebrew-tap`, so an edit made in the tap is overwritten by
the next release.

- **The cask token is `paseo-menubar`, the display name is `Paseo Icon`, and the
  bundle is `PaseoIcon.app`.** All three are correct and all three are different.
  The rename moved the package, appId, and repo to `paseo-menubar` while leaving
  `productName` alone, and `executableName: PaseoIcon` is what names the bundle
  directory. `scripts/render-cask.test.mjs` asserts the cask's `app` stanza still
  matches `electron-builder.yml`, because renaming that field breaks every
  `brew install` with an "unable to locate app" long after the release ships.
- **Run the workflow by hand after uploading the artifacts.** Uploads are manual,
  so `release: published` can fire while the dmg is still going up. The workflow
  downloads the exact url the cask names and checksums the bytes rather than
  trusting the API's digest field — that is also what catches the hyphen-vs-space
  asset naming, which nothing else validates.
- **`scripts/` is build tooling and is not compiled into `dist/`**, so it is plain
  `.mjs`. It is still tested: `vitest.config.ts` includes `scripts/**/*.test.mjs`.
  `render-cask.mjs` throws rather than no-op when a substitution finds no match —
  a silent no-op there publishes a cask that pins the old checksum against the new
  version, which fails every user's install while the workflow stays green.
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
  current" and pushes nothing. That exercises auth, download, and checksum without
  touching the tap — but not `git push`, which is only covered by a run that
  actually changes something.
- **Verify a cask change by tapping it, not by reading it.** `brew style` on a
  loose file reports Sorbet and `frozen_string_literal` offenses that do not apply
  to casks in a tap; `brew audit --cask --online` and `brew livecheck` are the real
  checks, and the deprecated `depends_on macos: ">= :monterey"` spelling was caught
  this way and not by review.

## Two things this project learned the hard way

**Mutate before you claim coverage.** Twice, test evidence here did not survive
independent re-running: one RED transcript came from an incomplete revert, and one test
passed against the very mutation it targeted. Before reporting a test as covering
something, break the thing it covers and confirm the test goes red.

**No agent can see a menu bar.** Icon states, click-through, reconnect, and login-item
registration are verifiable only by a human running the app. Say so plainly rather than
narrating a check you did not perform.

## Known issues

- Past 200 agents on one host, an agent can be capped out of the seed and its workspace
  then opens in the browser instead of the app. The daemon's `status_priority` scoring
  has no `requiresAttention` branch, so an agent whose attention reason is `finished`
  sorts last and goes first. Closing this needs a daemon-side sort key. The cap stays
  visible in the menu, so nothing is lost silently.
- The `addHost` save-failure test assumes a non-root runner.
- The `release` workflow neither signs nor publishes. `appId`, `publish.owner`, and
  `notarize: true` are settled, and a local `npm run dist` signs and notarizes both the
  `.app` and the dmg from the maintainer's keychain — but the repo has no Actions secrets,
  so a `v*` tag push fails at the notarize step. Uploading is manual for a second reason:
  electron-builder publishes each artifact as it finishes, which is before
  `scripts/notarize-dmg.mjs` can staple the dmg, so `--publish always` would ship an image
  Gatekeeper rejects. Closing this needs the five secrets *and* a publish step ordered
  after stapling.
- Releases are `arm64` only — `npm run dist` builds for the host arch, so there is no
  Intel or universal artifact.
- **`latest-mac.yml` and the dmg's blockmap are stale by construction.** electron-builder
  writes both before `scripts/notarize-dmg.mjs` staples the dmg, and stapling grows the
  file — measured at 1984 bytes on 0.1.0 — so the recorded `size` and `sha512` describe an
  image that no longer exists. The zip's entry is still correct. Neither file is uploaded
  to releases, and nothing reads them yet because there is no auto-updater; adding
  electron-updater means regenerating this metadata after stapling, not before.
- `latest-mac.yml` also refers to the artifacts with hyphens (`Paseo-Icon-…`) while the
  files on disk have a space (`Paseo Icon-…`). electron-builder's own publisher renames
  them; a manual upload has to do it by hand, and does, so release asset names are
  hyphenated.
