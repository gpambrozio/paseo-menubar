# CLAUDE.md

Paseo Icon is a macOS menu-bar indicator for [Paseo](https://paseo.sh) coding agents. It
shows whether any agent needs you, across every configured host, and deep-links into the
Paseo desktop app on click. It is a status indicator and launcher — it never runs agents
itself.

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
| `src/daemon/agent-store.ts` | Replicated agent map keyed by host. |
| `src/tray/view-model.ts` | Store state to icon, count, and sections. |
| `src/tray/menu-template.ts` | View model to Electron menu template. |
| `src/launch/open-agent.ts` | Deep link, with a browser fallback. |

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
- **`config.json` is written `0600`** via temp-file + `rename()`. It holds TCP passwords
  and relay keys, and the app's own watcher reads it.

## Working here

```bash
SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install   # Homebrew libvips breaks sharp's prebuild
npx vitest run                              # 112 tests, 9 files
npm run typecheck
```

- **Do not launch the app to check your work.** `electron .` writes a real `config.json`
  into `~/Library/Application Support/Paseo Icon/`.
- **`npm run dist` takes minutes** and downloads Electron binaries. Don't run it casually.
- **There is no linter.** Don't assume `npm run lint` exists.
- **Integration tests boot a real daemon** in-process from `@getpaseo/server`. They are
  slow by design. Always `listen: "127.0.0.1:0"` so the OS picks the port — a fixed port
  collides with the developer's own daemon on 6767.

## Two things this project learned the hard way

**Mutate before you claim coverage.** Twice, test evidence here did not survive
independent re-running: one RED transcript came from an incomplete revert, and one test
passed against the very mutation it targeted. Before reporting a test as covering
something, break the thing it covers and confirm the test goes red.

**No agent can see a menu bar.** Icon states, click-through, reconnect, and login-item
registration are verifiable only by a human running the app. Say so plainly rather than
narrating a check you did not perform.

## Known issues

- An agent whose attention reason is `finished` can be capped out of the seed past 200
  active agents on one host. The daemon's `status_priority` scoring has no
  `requiresAttention` branch, so closing this needs a daemon-side sort key. The cap stays
  visible in the menu, so the undercount is never silent.
- The `addHost` save-failure test assumes a non-root runner.
- `appId` and `publish.owner` in `electron-builder.yml` are unconfirmed, and `notarize` is
  off. All three need a decision before distributing to anyone else.
