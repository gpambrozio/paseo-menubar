# Reading hosts from the Paseo app's registry

**Status:** binding for this change. Supersedes the parts of
`2026-08-16-standalone-menubar-app-design.md` that describe `config.json` as the source of
hosts and clipboard pairing as the way to add one. Everything else in that document stands.

## The problem

Every remote host has to be paired twice: once in the Paseo desktop app, and again here by
copying a `paseo daemon pair` link onto the clipboard. The second pairing is pure
duplication — the desktop app already holds working credentials for exactly the hosts the
tray wants to show.

It also decays. A relay endpoint change or a re-keyed daemon updates the app and leaves
this app's `config.json` pointing at credentials that no longer work, with no signal beyond
a host that stops connecting.

## What we are doing

The Paseo desktop app's host registry becomes the **only** source of hosts. `config.json`
stops holding hosts, clipboard pairing is deleted, and the tray shows exactly the hosts the
desktop app has.

### Where the credentials are

The desktop app persists its registry through
`@react-native-async-storage/async-storage`, which on the Electron renderer is plain
`localStorage`:

| | |
| --- | --- |
| Directory | `~/Library/Application Support/Paseo/Local Storage/leveldb` |
| Record key | `_paseo://app\x00\x01@paseo:daemon-registry` |
| Value | JSON array of `HostProfile` |

Written by `HostRuntime.persistHosts` in the upstream repo
(`packages/app/src/runtime/host-runtime.ts`); the key is defined at `REGISTRY_STORAGE_KEY`
in the same file.

### Why this is sufficient

`RelayHostConnection` carries `relayEndpoint`, `useTls`, and `daemonPublicKeyB64`;
`HostProfile` carries `serverId`. Those are every field of `ConnectionOfferV2Schema`, so
the offer `RelayHostSchema` stores is reconstructible without loss. Direct TCP maps
field-for-field.

There is no second secret to recover. `createClientChannel`
(`packages/relay/src/encrypted-channel.ts`) generates a fresh keypair per connection, so
`daemonPublicKeyB64` is the entire credential. Importing it genuinely removes re-pairing
rather than deferring it.

### What this costs

This is an unsupported surface, and after this change it is the app's **only** way to
function. `CLAUDE.md` says this project depends on the upstream repo through published npm
packages and supported surfaces; the record's location, key framing, and Chromium value
encoding are none of those, and will change with no type error and no failing test.
Upstream also treats `daemonPublicKeyB64` as a secret — `app-diagnostic-report.ts` redacts
it from diagnostics — and there is no export path: the app's pair-link modal is
import-only.

The payload *shape* is safe, being the published protocol schemas. The way we reach it is
not. This is accepted deliberately, not overlooked.

## Module layout

New `src/registry/`, following the existing pure-module-plus-injection pattern. Electron
still appears in exactly two modules.

| Module | Owns |
| --- | --- |
| `registry/leveldb-reader.ts` | Read-only Chromium LevelDB: SSTable `.ldb` blocks and `.log` write-ahead records, newest sequence wins. Knows nothing about Paseo. |
| `registry/local-storage.ts` | Chromium localStorage record semantics: the `_<origin>\x00\x01<key>` framing and the leading encoding byte. |
| `registry/paseo-registry.ts` | Locate the support directory, read the registry key, validate, map `HostProfile[]` to `HostEntry[]`. |
| `registry/registry-session.ts` | Initial read, watch, debounce, fingerprint compare, apply to the fleet, own the error row. Replaces `config-session.ts`. |
| `registry/registry-watcher.ts` | Keeping the watch attached across "not installed yet" and "the watch died". |

Snappy decompression comes from `snappyjs` — pure JS, no native code. The code we write is
block and log framing only.

### Deleted

- `src/config/pairing.ts` and its test
- `src/config/config-session.ts` and its test
- `loadConfig`, `saveConfig`, `watchConfig`, and the `0600` temp-file-plus-rename write in
  `src/config/host-config.ts`
- `addHostFromClipboard` in `src/main.ts`, and the `Add host from clipboard…` and
  `Edit configuration…` menu items in `src/tray/menu-template.ts`

`host-config.ts` keeps the schemas and `hostsFingerprint` and becomes
`src/config/host-entry.ts`. The fleet still consumes `HostEntry`, and the schemas still
derive from the published protocol rather than being redefined here.

### `config.json` after this change

The app neither reads nor writes `config.json`. An existing file is left on disk untouched
rather than deleted — it holds credentials the user may want, and removing another
program's data on upgrade is not this change's business. It simply stops having any effect.

### The first-run `Local` seed

`config-session.ts` seeded a `Local` host at `127.0.0.1:6767` on first run. That seed is
removed: the desktop app's registry already contains the local daemon, so seeding one would
duplicate it. The consequence is that a machine where the Paseo desktop app has never run
shows **no hosts at all**, not even a local one, and the error row is the only thing in the
menu. That is the accepted cost of a single source of truth.

### Unchanged

`host-fleet.ts`, `host-store.ts`, `view-model.ts`, `open-paseo.ts`, and `menu-template.ts`
apart from the two removed items.

## The reader

### Finding the record without a MANIFEST parser

Reading a LevelDB properly means `CURRENT` → `MANIFEST` → version set → live files per
level. We need one key, and LevelDB internal keys carry an 8-byte trailer of
`(sequence << 8) | type`. So we scan every `.ldb`, `.sst`, and `.log` in the directory, collect
every record matching our key, and take the highest sequence number, honoring type `0` as
a deletion. Correct by construction, and it skips the version set entirely.

Within an `.ldb` we use the index block to seek to the single data block that can contain
the key rather than decompressing every block.

### CRC verification is load-bearing

We never take the `LOCK`, so we read while Chromium writes and while compactions rename
files underneath us. Both formats checksum their blocks with masked CRC32C. Checking it is
what turns a torn read into "retry on the next tick" instead of "silently wrong
credentials". A block that fails CRC is discarded, never parsed.

Discarding is not enough on its own, and getting that wrong is what the first
implementation did: the torn file may be the one holding the *newest* write, so dropping
it quietly and returning an older sibling file's record presents a superseded host list —
credentials included — as current. Every discard is therefore counted and travels back
with the value, and the row says the hosts may be out of date. When no value survives at
all, absence and damage are indistinguishable, so that case is reported as a failure
rather than as "the key is gone".

### Compression is the drift canary

Chromium's LevelDB fork has historically used snappy, and the current on-disk data is
snappy. A block whose compression byte is neither `0` (none) nor `1` (snappy) is not
guessed at. It surfaces a named error, because that is exactly the moment this bet stops
paying.

## Mapping

Per `HostProfile`:

- `id` = `serverId`. **Not** the registry's connection id: distinct hosts share the
  identical connection id `relay:wss:relay.paseo.sh:443`, which `HostEntrySchema`'s
  duplicate-id check rejects outright. `serverId` is unique per daemon and stable across
  restarts, which also keeps `paseo-menubar-${entry.id}` stable for daemon session resume.
- `label` = the profile's label.
- The connection is chosen by `preferredConnectionId`, falling back to the first supported
  connection when the preferred one is unsupported.
- `directSocket` and `directPipe` are skipped; the tray supports neither.
- A host with no supported connection is dropped and counted into the error row, reusing
  the existing `noteEntryFailures` shape.
- Two profiles carrying the same `serverId` collapse to the first, and the second is
  counted into the error row the same way. The id keys the fleet's connection map, so
  admitting both would leave one live socket wearing the other's label, type, and web
  base url. The built config is then parsed through `AppConfigSchema` before it reaches
  the fleet, which is what `host-fleet.ts`'s duplicate-id invariant is written against.

Path discovery probes `Paseo` under Application Support only. A development build of the
desktop package is not probed: it loads its window from the dev server rather than
`paseo://app`, so its localStorage is keyed under that origin and the record above would
never be found there — a probe that succeeded would only turn "not installed" into a
misleading "no hosts yet".

A profile the tray cannot parse — an unknown connection type, a malformed known one — is
dropped and named in the error row like a host with no usable connection. Only a record
that is not an array at all fails the whole read. The desktop app is not version-pinned,
so one profile from a newer app must never cost the hosts beside it.

## Refresh

`fs.watch` on the leveldb directory, debounced 500ms because Chromium writes constantly for
unrelated keys, then read → map → `hostsFingerprint` compare → `fleet.apply` only when the
host set actually changed. The fingerprint ignores the order of the host list: that order
is the Paseo app's serialization order now, not a user's, so a reshuffle must not tear down
live connections. A 60s poll backs it up: macOS `fs.watch` can miss events across
the atomic renames a compaction performs.

The watch is re-established rather than attached once. The directory may not exist at
launch — Paseo can be installed afterwards — and a watch can die later, so every read
re-attaches if nothing is attached, and the poll is what drives that when the tray has no
hosts at all.

## Failure states

None of these may throw into the main process, and none may crash the tray.

| State | Behaviour |
| --- | --- |
| Support directory absent | **Keep last known-good hosts**; row reports the Paseo desktop app was not found |
| Key missing, or an empty registry | Zero hosts; row points at pairing a host in the Paseo app |
| Parse, CRC, or schema failure | **Keep last known-good hosts**; row carries the detail |
| Partly unreadable database with a value still found | Apply the hosts found; row says they may be out of date |
| Unknown compression type | Keep last known-good hosts; row names the compression type |

The first row said "zero hosts" until the code was reviewed against it. A missing
support directory reaches the session as a rejected read, indistinguishable there from a
torn one, so it takes the keep-last-known-good path — and that is the better behaviour:
the two states agree on first launch, and they only diverge if Paseo is uninstalled or
its storage moves mid-session, where dropping every live connection helps nobody. The
table was wrong, not the code.

The error row currently clicks through to `Edit configuration…`, which will not exist.
It opens the Paseo desktop app instead, since that is where every one of these is fixed.

## Testing

### Fixtures are generated by real LevelDB

`classic-level` goes in `devDependencies` only — never in the bundle, so notarization is
untouched. `scripts/make-registry-fixtures.mjs` writes small `.ldb`/`.log` trees that are
committed, so the tests themselves need no native module. This validates our parser against
the actual C++ format producer rather than against our own reading of the format, which is
the failure mode hand-rolled binary parsing usually dies of.

Fixture cases, each produced by controlling whether the writer compacts:

- record present only in the `.log` (fresh write, no compaction)
- record in a compacted `.ldb`
- an `.ldb` value superseded by a newer `.log` write
- a deleted key
- both value encodings: Latin1 and UTF-16LE

Fixtures are synthetic. No real credential is committed.

### Mutation checks

Per the project's "mutate before you claim coverage" rule, each of these is broken and
confirmed red before the corresponding test is reported as covering anything:

- flip a CRC byte; the block must be rejected, not parsed
- invert the sequence-number comparison; the stale value must fail the test
- swap the encoding byte; the value must come back mangled

### Unit boundaries

`paseo-registry` mapping is pure: preferred-connection selection, fallback when the
preferred connection is unsupported, skipping `directSocket`/`directPipe`, dropping a host
with no usable connection into the failure list, and relay offer construction.

`registry-session` takes an injected reader, so debounce, fingerprint suppression of no-op
rebuilds, last-known-good retention on read failure, and each error message are testable
with no filesystem.

### Integration

One test reuses the existing real-daemon harness: boot a daemon on `127.0.0.1:0`, hand
`registry-session` an injected reader returning a host entry pointing at the port the OS
picked, and assert the fleet connects and the store fills. Static fixtures cannot encode a
dynamic port, so this stays injected rather than fixture-driven.

### What no test covers

Reading the actual Paseo app's storage on a real machine. That was verified by hand once
against live data during design. The shipped code path against a running Paseo app, and the
tray rows it produces, are human-verifiable only — consistent with this project's standing
rule that no agent can see a menu bar.

## Documentation

`CLAUDE.md` is part of this change. It needs:

- the module table updated for `src/registry/` and the removed config modules
- the `config.json` is written `0600` rule removed
- the clipboard pairing flow removed
- the `181 tests, 10 files` count corrected
- a new critical rule recording the dependency on Chromium private storage: what it costs,
  and that an empty tray after a Paseo update means checking the record key, the value
  encoding, and the block compression type first
