# Standalone menu-bar app — agent status across hosts

Status: design approved 2026-08-16. Not implemented.

Relationship to the desktop tray design, which lives outside this repository at
`paseo/docs/superpowers/specs/2026-08-16-desktop-tray-agent-status-design.md`:
same goal, different home. That design puts the tray inside `packages/desktop` and
changes shipping app code. This one builds a separate app in its own repository
because the author is not a maintainer of `getpaseo/paseo` and cannot rely on
upstream accepting changes. Where the two agree, this document restates the
conclusion rather than linking, because the repositories are separate.

The two also differ in unit: that design lists workspaces and buckets them with the
daemon's workspace status, this one lists agents and uses `AgentSnapshotPayload`.
Agents are what was asked for here.

## Goal

A menu-bar item that shows at a glance whether any agent needs you. Idle shows the
plain icon. Anything needing attention changes the icon and puts a count beside it.
Opening the menu lists the agents behind that count, and clicking one lands you in
that agent.

## Constraints

These were decided during brainstorming and are not open for re-litigation during
implementation.

| Constraint | Decision |
| --- | --- |
| Hosts | Every configured host, not just the local daemon. |
| Packaging | Standalone app with its own installer, own repository. |
| Behavior | Indicator and navigation only. No notifications, no agent actions. |
| Input | Clipboard plus hand-edited config. A preferences window only if that chafes. |
| License | AGPL-3.0-or-later, source published. |
| Platforms | macOS is the target. Windows and Linux ship if they stay cheap. |

## Why not a Paseo plugin

The plugin contract has exactly three extension points — `addSurface`,
`addSidebarItem`, and `addAttachmentSource` (`packages/plugin/dist/host.d.ts:5`).
Client plugin code is evaluated in the Expo runtime and server plugin code runs in a
daemon subprocess. A menu-bar extra needs Electron's `Tray` in a main process, which
neither half of a plugin can reach. Plugins are not a path to this feature and will
not become one without a new extension point.

## Why an outside app is viable

Everything this app needs is published or otherwise unowned by the Paseo repo.

- `@getpaseo/client@0.4.0` and `@getpaseo/protocol@0.4.0` are on npm.
  `@getpaseo/server@0.4.0` is too, which matters for testing.
- `fetchAgents({ subscribe: {} })` seeds state and `on("agent_update")` delivers a
  discriminated union of `upsert` carrying a full `AgentSnapshotPayload` and `remove`
  carrying an id. Replicating a map from that needs no diffing. Use `DaemonClient` from
  `@getpaseo/client/internal/daemon-client`, the declared export the Paseo CLI itself
  uses, rather than the `createPaseoClient` wrapper: the wrapper does not expose
  `serverId`, and deep links require it. `DaemonClient.getLastServerInfoMessage()` does.
  Confine that surface to one module so a future SDK change lands in one file.
- `AgentSnapshotPayload` already carries `status`, `requiresAttention`,
  `attentionReason` (`finished | error | permission`), `title`, `cwd`, `workspaceId`,
  and `archivedAt`. Nothing is re-derived client-side.
- The installed desktop app registers the `paseo:` URL scheme, so
  `shell.openExternal(buildAgentDeepLink({serverId, agentId}))` navigates without any
  cooperation from it.
- `paseo daemon pair` prints a pairing offer URL and
  `parseConnectionOfferFromUrl` parses it, so remote hosts can be added through
  supported surface instead of by reading another app's storage.
- Paseo commits to old clients parsing messages from new daemons
  (`docs/protocol-compatibility.md`). Pinning the SDK is a supported position, not a
  gamble.

The one thing an outside app gives up: there is no shared host list. The registry
lives in the app's AsyncStorage under `@paseo:daemon-registry`
(`packages/app/src/runtime/host-runtime.ts:1287`), which on Electron is the renderer's
localStorage — locked while the app runs and not a file to parse. Hosts get configured
twice, once in Paseo and once here. That is the entire cost of staying outside the
repo, and it is accepted.

## Architecture

One Electron main process. No `BrowserWindow` is ever created. `Tray` and `Menu` are
main-process APIs, so an indicator needs no web contents.

Data flows one direction:

```
config file ──> HostConnection (one per host) ──> AgentStore ──> view model ──> Tray
                    @getpaseo/client               replicated      pure fn      Electron
                                                      map
```

| Module | Responsibility |
| --- | --- |
| `src/main.ts` | Wiring only. No logic. |
| `src/config/host-config.ts` | Read, write, and watch `config.json`. |
| `src/config/pairing.ts` | Pairing URL to host entry. |
| `src/daemon/host-connection.ts` | One host: connect, seed, subscribe, reconnect, report status. |
| `src/daemon/agent-store.ts` | Replicated map keyed by `serverId:agentId`. Pure. |
| `src/tray/view-model.ts` | Store state to icon, count, and menu sections. Pure. |
| `src/tray/menu-template.ts` | View model to Electron menu template. Pure. |
| `src/tray/tray-presenter.ts` | Applies the view model to an Electron `Tray`. |
| `src/launch/open-agent.ts` | Deep link, with a browser fallback. |

Electron appears in two modules. Everything that can be gotten wrong — counting,
ordering, grouping, icon selection — is pure TypeScript that tests without an Electron
harness.

Menu rebuilds coalesce on a short timer so a burst of `agent_update` messages rebuilds
once.

Every `upsert` carries a complete `AgentSnapshotPayload`, so the store applies updates
in arrival order and ignores the optional `seq` and `generation` fields. A reconnect
re-seeds from `agents.list` and replaces that host's entries wholesale rather than
merging, so a subscription gap cannot leave a stale agent behind.

## Icon and count

Three states. Highest priority wins.

| State | Condition | Shows |
| --- | --- | --- |
| Attention | any agent with `requiresAttention` | attention icon and a count |
| Working | any agent with `status` of `running` or `initializing` | working icon, no count |
| Idle | neither | plain icon |

Attention outranks working. The desktop app's favicon does the opposite — it checks
`running` first and returns before testing attention
(`packages/app/src/hooks/use-favicon-status.ts:30`). That is fine for a favicon and
wrong here: during a work session something is nearly always running, so running-wins
would mask the state you are waiting on.

The count is one number: agents with `requiresAttention === true`, spanning all three
`attentionReason` values. The menu bar is too narrow for a breakdown; the breakdown is
the menu's job.

No platform supports a numeric badge on a tray icon. On macOS the count goes in
`tray.setTitle()` beside a template image, which also gets light and dark mode for
free. On Windows and Linux it goes in the tooltip and the menu header.

## Menu

```
Needs you
  ✓  Fix login redirect          done            laptop
  ⏸  Add rate limiting           permission      studio
  ⚠  Migrate schema              error           laptop
Working
  ◐  Refactor terminal input                     laptop
Idle (12)                                        ▸
─────────────────────────
laptop · connected     studio · reconnecting
─────────────────────────
Open Paseo      Add host from clipboard…      Edit configuration…
Start at login  ✓
Quit
```

Grouping is by state, with host as a per-item label shown only when more than one host
is configured. You open this menu to answer "what needs me", and state-first grouping
answers that in one glance; host-first grouping makes you scan several sections to find
three agents.

- Idle agents collapse into a submenu. Attention and working agents always list in full.
- The attention list caps at 15 with an explicit `…and N more` row that opens the app.
  Caps are visible, never silent.
- `title` is nullable; items fall back to the basename of `cwd`.
- Agents with `archivedAt` set are excluded everywhere, including counts.
- Every action is reachable from the menu itself. AppIndicator desktops on Linux
  swallow left-click, so nothing may live on click-only.

## Configuration

`config.json` in `app.getPath("userData")`. Not `PASEO_HOME` — that is the daemon's
directory and this app does not own it.

Host entries reuse published schemas instead of parallel ones. Direct entries are a
`DirectTcpHostConnectionSchema` from `@getpaseo/protocol/host-connection-schema`; relay
entries are a `ConnectionOffer` plus a label. The file is written `0600` because it
holds TCP passwords and relay keys. Paseo already keeps those unencrypted in
localStorage, so this is not a regression, but a file is greppable and restrictive
permissions are the minimum bar.

First run needs no configuration. The app probes `localhost:6767` and adds a daemon
that answers. Remote hosts are added by copying the URL from `paseo daemon pair` and
choosing `Add host from clipboard…`, which parses it, shows a native confirmation
dialog naming the host, and writes the entry. `Edit configuration…` opens the file for
anything else.

Config changes apply live, debounced.

## Failure handling

- **Connection loss is a normal state.** The SDK reconnects with backoff. Each host
  reports `connecting`, `connected`, or `disconnected` on its status line. A
  disconnected host's agents leave the counts immediately — the icon never reflects
  data the app cannot vouch for.
- **Auth rejection is distinct from unreachable.** It shows `authentication failed`
  with a re-pair action. Retrying a wrong password behind backoff forever is the
  failure mode that wastes an afternoon.
- **Invalid config keeps the last known-good state** in memory and surfaces a
  `Configuration error` row. It never crashes the tray and never silently reverts to
  defaults.
- **Single instance lock** via `app.requestSingleInstanceLock()`. Two tray icons is a
  bug users cannot diagnose.
- `LSUIElement: 1` in `mac.extendInfo` so there is no dock icon. A login-item toggle
  drives `app.setLoginItemSettings`.

## Testing

Unit, vitest, no Electron import:

- `agent-store` reduced over a scripted sequence of `agent_update` messages: upsert,
  update, remove, and a reconnect re-seed that drops an agent the gap removed.
- `view-model`: all three icon states, count boundaries at zero and one, the 15-item
  cap and its overflow row, null-`title` fallback, archived exclusion, and exclusion of
  a disconnected host's agents.
- `pairing`: valid offer URL, malformed fragment, absent fragment.

Integration:

- `host-connection` against a real daemon started in-process from
  `@getpaseo/server@0.4.0`: initial seed, live update, disconnect, reconnect.

Manual: no automated harness can see a tray. Release evidence is screenshots of all
three icon states on macOS, plus the same on Windows and each Linux desktop that ships.

## Platforms

| Platform | Support |
| --- | --- |
| macOS | Menu bar extra. Template images, `tray.setTitle()` for the count. The target. |
| Windows | Notification area icon, context menu, count in the tooltip. |
| Linux | Needs libappindicator or StatusNotifier. GNOME needs a shell extension, which users must install themselves. On AppIndicator desktops left-click opens the menu and `click` may not fire. |

Linux is where "cheap" stops being true — not in the build, which is one more matrix
entry, but in support burden from the GNOME extension requirement. Ship it only if
someone asks.

## Distribution

`electron-builder` producing dmg and zip on macOS, mirroring the shape of
`packages/desktop/electron-builder.yml`. GitHub Actions matrix and `electron-updater`
against a GitHub releases provider, mirroring `.github/workflows/desktop-release.yml`.

Signing is the real cost and it is not shared: a signed and notarized macOS build needs
its own Apple Developer account, and Windows needs its own certificate. Unsigned builds
are fine for the author and rough for anyone else. Decide before announcing it, not
before building it.

AGPL-3.0-or-later, matching the SDK's inherited license. Neither `@getpaseo/client` nor
`@getpaseo/protocol` declares a license field or ships a LICENSE file, so this is the
conservative reading rather than a documented one. Confirm with maintainers before
distributing binaries widely.

## Deferred

Named so they are choices rather than omissions.

- **Notifications.** Would need a rule for who notifies when the desktop app is also
  running, or you get everything twice.
- **Preferences window.** An on-demand `BrowserWindow`, built only if clipboard and
  file editing prove annoying in daily use.
- **Agent actions** such as approving a pending permission from the menu.
- **A shared host registry.** If the author ever becomes a maintainer, backing
  `@paseo:daemon-registry` with a file on Electron via the injectable storage at
  `packages/app/src/runtime/host-runtime.ts:1378` would remove double configuration.
  Mobile would stay on AsyncStorage.
