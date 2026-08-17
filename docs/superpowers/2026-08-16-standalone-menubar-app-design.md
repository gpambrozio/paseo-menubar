# Standalone menu-bar app — workspace status across hosts

Status: implemented. Approved 2026-08-16; amended 2026-08-16 when the unit changed
from agents to workspaces.

Relationship to the desktop tray design, which lives outside this repository at
`paseo/docs/superpowers/specs/2026-08-16-desktop-tray-agent-status-design.md`:
same goal, different home. That design puts the tray inside `packages/desktop` and
changes shipping app code. This one builds a separate app in its own repository
because the author is not a maintainer of `getpaseo/paseo` and cannot rely on
upstream accepting changes. Where the two agree, this document restates the
conclusion rather than linking, because the repositories are separate.

Both list workspaces and bucket them with the daemon's workspace status. This one
started on agents, and the first build showed why that was wrong: side by side
with the Paseo sidebar the two disagreed on row names, on section names, and on
which state a thing was in.

## Goal

A menu-bar item that shows at a glance whether any workspace needs you. A quiet
fleet shows the plain icon. Anything needing you changes the icon and puts a count
beside it. Opening the menu lists the workspaces behind that count, and clicking
one lands you in that workspace.

## Say what Paseo says

The unit is the workspace and the state is the `WorkspaceStateBucket` the daemon
already computed. Nothing here re-derives either.

Paseo's `docs/glossary.md` rule is "UI label wins, no synonyms". The tray and the
sidebar describe the same fleet, so a user reading both has to see one vocabulary.
An invented one fails that twice over: the labels differ from the sidebar's, and
the states differ from the daemon's. "Idle" is the clearest case — it is not a
Paseo state at all. A workspace with nothing pending is `done`.

Deriving state client-side also drifts. The bucket rule lives in the daemon and
changes there; a copy in this repo is a second answer that is right until the day
it is not, and no test in either repo would catch the day. Consuming
`WorkspaceDescriptorPayload.status` means the tray is wrong only when the sidebar
is wrong too.

The one thing that is copied is the section order and the five labels, from
`STATUS_BUCKET_ORDER` and `STATUS_BUCKET_LABELS` in
`packages/app/src/hooks/sidebar-status-view-model.ts`. They live in the app
package, not in `@getpaseo/protocol`, so there is nothing to import. The copy is
named in a comment at `src/tray/view-model.ts` so a reader knows what it must
track.

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
- `fetchWorkspaces({ subscribe: {} })` seeds state and `on("workspace_update")`
  delivers a discriminated union of `upsert` carrying a full
  `WorkspaceDescriptorPayload` and `remove` carrying an id. `fetchAgents` and
  `agent_update` are the same shape. Replicating a map from either needs no diffing.
  Use `DaemonClient` from `@getpaseo/client/internal/daemon-client`, the declared
  export the Paseo CLI itself uses, rather than the `createPaseoClient` wrapper: the
  wrapper does not expose `serverId`, and deep links require it.
  `DaemonClient.getLastServerInfoMessage()` does. Confine that surface to one module
  so a future SDK change lands in one file.
- The two `remove` payloads are not interchangeable. `workspace_update`'s field is
  `id`; `agent_update`'s is `agentId`. Reading the wrong one yields `undefined` and a
  row that never leaves the menu.
- `WorkspaceDescriptorPayload` already carries `name`, `projectDisplayName`,
  `status`, `diffStat`, and `archivingAt`. `AgentSnapshotPayload` carries
  `workspaceId`, which is what ties an agent to its row.
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
config file ──> HostConnection (one per host) ──> HostStore ──> view model ──> Tray
                    @getpaseo/client              replicated      pure fn      Electron
                                                     maps
```

| Module | Responsibility |
| --- | --- |
| `src/main.ts` | Wiring only. No logic. |
| `src/config/host-config.ts` | Read, write, and watch `config.json`. |
| `src/config/pairing.ts` | Pairing URL to host entry. |
| `src/config/config-session.ts` | Owns the config lifecycle: first-run seed, reload, add-host, and which of the two errors wins. Electron-free. |
| `src/daemon/host-connection.ts` | One host: connect, seed, subscribe, reconnect, report status. |
| `src/daemon/host-fleet.ts` | Owns the set of connections: apply a config, isolate a bad entry, retry a host, serialize rebuilds. Electron-free. |
| `src/daemon/host-store.ts` | Replicated workspaces and agents, keyed by host. Pure. |
| `src/tray/view-model.ts` | Store state to icon, count, sections, and click targets. Pure. |
| `src/tray/menu-template.ts` | View model to Electron menu template. Pure. |
| `src/tray/tray-presenter.ts` | Applies the view model to an Electron `Tray`. |
| `src/launch/open-paseo.ts` | Deep link, with a browser fallback. |
| `src/error-text.ts` | The message to show for a thrown value. |

Electron appears in two modules. Everything that can be gotten wrong — counting,
ordering, grouping, icon selection, picking a click target — is pure TypeScript that
tests without an Electron harness.

`config-session.ts` and `host-fleet.ts` were not in the original design. They exist
because the first cut put their logic in `main.ts`, where nothing could test it. Both take
their collaborators by injection for that reason, and the rule they enforce is the one
above: if it does not touch Electron, it does not belong in `main.ts`.

The store holds two lists per host because they answer two questions. Workspaces are
what the menu shows. Agents exist only to resolve a click, for the reason in
[Click-through](#click-through).

Menu rebuilds coalesce on a short timer so a burst of update messages rebuilds once.

Every `upsert` carries a complete payload, so the store applies updates in arrival
order and ignores the optional `seq` and `generation` fields. A reconnect re-seeds and
replaces that host's entries wholesale rather than merging, so a subscription gap
cannot strand a dead row. Both lists are fetched before either is applied: a
half-applied seed pairs fresh workspaces with a stale agent index, and the retry runs
both anyway.

## Icon and count

The count is workspaces in `needs_input`, `failed`, or `attention`. Not `done`: in
Paseo's vocabulary `done` is the resting state, so counting it would badge every quiet
workspace permanently. The menu bar is too narrow for a breakdown; the breakdown is the
menu's job.

| State | Condition | Shows |
| --- | --- | --- |
| Attention | the count is above zero | attention icon and the count |
| Working | the count is zero and something is `running` | working icon, no count |
| Idle | neither | plain icon |

Attention outranks working. The desktop app's favicon does the opposite — it checks
`running` first and returns before testing attention
(`packages/app/src/hooks/use-favicon-status.ts:30`). That is fine for a favicon and
wrong here: during a work session something is nearly always running, so running-wins
would mask the state you are waiting on.

No platform supports a numeric badge on a tray icon. On macOS the count goes in
`tray.setTitle()` beside a template image, which also gets light and dark mode for
free. On Windows and Linux it goes in the tooltip and the menu header.

## Menu

```
Needs input
  fix-login-redirect  ·  paseo  ·  +40 −12  ·  laptop
Failed
  migrate-schema  ·  paseo  ·  +8 −2  ·  laptop
Ready to review
  add-rate-limiting  ·  paseo-icon  ·  +120 −4  ·  studio
Working
  refactor-terminal-input  ·  paseo  ·  laptop
Done
  bump-deps  ·  paseo  ·  laptop
─────────────────────────
laptop · connected     studio · reconnecting
─────────────────────────
Open Paseo      Add host from clipboard…      Edit configuration…
Start at login  ✓
Quit
```

Five flat sections, in the sidebar's order and words. Grouping is by state, with host
as a per-item label shown only when more than one host is configured. You open this
menu to answer "what needs me", and state-first grouping answers that in one glance;
host-first grouping makes you scan several sections to find three workspaces.

- No submenus. `Done` is a section like the other four, because it is one in the
  sidebar. Hiding it behind a hover would make it the odd one out and would put a
  bucket the user asked to see one interaction further away.
- Empty sections are omitted.
- Each section caps at 15 rows with an explicit `…and N more` row that opens the app.
  Caps are visible, never silent.
- Rows carry the workspace's own `name`, `projectDisplayName`, and `diffStat`. A zero
  diff renders as nothing rather than `+0 −0`.
- Workspaces with `archivingAt` set are excluded everywhere, including counts.
- The seed page limit is 200 per list per host. Hitting it on workspaces means the rows
  are a subset, and a `Not all workspaces shown` line says so. Hitting it on agents
  costs click targets rather than rows, and gets its own line.
- Every action is reachable from the menu itself. AppIndicator desktops on Linux
  swallow left-click, so nothing may live on click-only.

## Click-through

There is no workspace deep link, and this repo cannot add one. The desktop app's
`open-url` handler calls `parseAgentDeepLink`, which returns `null` unless the path's
second segment is `agent`, and the handler drops what it cannot parse — so
`paseo://h/<serverId>/workspace/<id>` opens nothing at all.

So the tray keeps fetching and subscribing to agents purely to resolve a click.
`AgentSnapshotPayload.workspaceId` maps an agent to its row, and a click opens the
workspace's most relevant agent through the link that does work. "Most relevant" is
`getAgentStatusPriority` from `@getpaseo/protocol/agent-state-bucket` — the daemon's
own ranking, lower is more urgent — so the click lands on the agent Paseo itself would
call the reason the workspace is in the bucket it is in. `updatedAt` newest-first, then
id, break ties, so the same fleet always resolves to the same agent. Archived agents
are never targets.

Two fallbacks, in order:

1. **No agent in the workspace** — open `{webBaseUrl}/h/{serverId}/workspace/{id}`,
   which the daemon's own web UI does route. Preferred over `paseo://` even with the
   desktop app installed: the browser lands on the right workspace, and the bare scheme
   would only bring Paseo forward at whatever it was already showing.
2. **No agent and no web base URL** — a relay host has no HTTP origin, so neither route
   exists. Open Paseo itself. A menu row that does nothing reads as a broken app.

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
  disconnected host's rows leave the counts immediately — the icon never reflects
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

- `host-store` reduced over scripted `workspace_update` and `agent_update` sequences:
  upsert, update, remove, and a reconnect re-seed that drops a row the gap removed.
- `view-model`: all three icon states, the count's bucket membership including that
  `done` never counts, section order and omission of empty sections, the 15-row cap and
  its overflow row, `archivingAt` exclusion, exclusion of a disconnected host's rows,
  and the click-target rule with all three tiebreakers.
- `menu-template`: the five section labels, flatness, row composition, and every cap
  row.
- `pairing`: valid offer URL, malformed fragment, absent fragment.

Every click-target case is arranged so the tiebreakers would pick a *different* agent
than the rule under test. The first cut was not, and three tests passed against the
mutation they targeted.

Integration:

- `host-connection` against a real daemon started in-process from
  `@getpaseo/server@0.4.0`: initial seed of both lists, live update, disconnect,
  reconnect.

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
