# Contributing

Thanks for looking. Issues and pull requests are welcome — this is a small
project, so the shortest path is usually to open an issue first and check the
change makes sense before writing it.

## Getting set up

```bash
SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install
npm run icons        # the tray glyphs are generated, not committed
npm run typecheck
npm test             # the build-tooling suite, then swift test
```

The app is a Swift package in `PaseoIconPackage/`; it needs Xcode 16.3 or newer,
because the manifest declares `swift-tools-version: 6.1`. What is left at the
repository root is build tooling under `scripts/`, plain `.mjs` that nothing
compiles.

The `SHARP_IGNORE_GLOBAL_LIBVIPS` flag is only needed if you have Homebrew's
`libvips` installed; see the Development section of the [README](README.md) for
the rest of the scripts.

There is no linter. Match the style of the code around you.

## Read the design docs first

`docs/superpowers/` holds seven documents and they are not equals. Three design
documents bind — two for behaviour, one for the native build. The four plans are
historical records with known defects, kept because they explain why things are
shaped the way they are, not because they are correct. [AGENTS.md](AGENTS.md) has
the table.

If a change disagrees with a design document, the document wins until it is
changed deliberately.

## Where code goes

The rule that shapes this codebase: **if it does not touch AppKit or SwiftUI, it
does not belong in the app target.** `PaseoIconCore` is the whole program and is
tested without a menu bar; `PaseoIcon` is the `MenuBarExtra` shell around it and
decides nothing. If you find yourself adding a decision to `AppCoordinator`, that
is the signal to extract it into the core, where a test can reach it. AGENTS.md
has the full module map.

A few rules that are easy to violate without knowing:

- **Never create a window.** `MenuBarExtra` in menu style is the whole interface.
- **Never derive a workspace's state.** Render the status the daemon computed.
  A second copy of that rule here is a second answer, and no test in either repo
  would catch the day they diverge. A bucket this build does not know gets its
  own named row rather than being guessed at or dropped.
- **Never crash the tray.** Bad input keeps the last known-good state and
  surfaces an error row. In Swift that also means no force unwraps and no
  arithmetic on untrusted numbers before they are bounded: a trap is uncatchable
  and takes the menu bar item with it.
- **No silent caps.** Any truncated list renders a visible overflow row, and
  every row needs its own identity — SwiftUI's `ForEach` keys on it, so two rows
  that collide become one.
- **The wire is pinned** to `@getpaseo/protocol` 0.4.0 and `protocolVersion: 1`
  — see below.

## Why the wire is pinned

The Swift structs in `PaseoIconCore/Daemon/` are a hand-written copy of one slice
of `@getpaseo/protocol` 0.4.0, and the handshake sends `protocolVersion: 1`.
Nothing in the app links a Paseo npm package any more, so the pin is a discipline
rather than a dependency range — which makes it easier to drift by accident, not
harder.

**The daemon conversation wants the client to stay old.** Paseo commits that old
clients parse messages from new daemons. That guarantee runs one direction only:
nothing says a *new* client can talk to an *old* daemon. Users install this app on
their own schedule and run whatever daemon their Paseo app ships, so teaching the
tray a newer message shape could float it past a user's daemon into the direction
that is not covered. `APP_VERSION` in the connection code is the same number
again — it goes out in the handshake as `appVersion`, and the daemon gates
provider visibility on it, so the two move together or not at all.

**Reading the desktop app's registry pulls the other way.** The host list is
parsed out of the Paseo desktop app's own storage, and the desktop app is *not*
version-pinned. When a Paseo update adds a connection type this version has never
heard of, the host is dropped and named in the error row rather than taking the
other hosts down with it. That degradation is deliberate, but the fix for it is
teaching the reader the new shape, which is the thing the pin otherwise forbids.
Do that on purpose, with the daemon-compatibility side weighed, not to clear a
warning.

`@getpaseo/server` is a third case: a devDependency the Swift integration tests
spawn through `scripts/swift-test-daemon.mjs` to boot a real daemon. It is pinned
so the tests exercise the daemon version this client claims to be compatible with.

## Testing

```bash
npm test                                    # both suites
swift test --package-path PaseoIconPackage  # the app
npx vitest run                              # the build tooling only
```

`npx vitest run` covers `scripts/` and nothing else — running it alone tells you
nothing about the app. Integration tests spawn a real daemon and are slow by
design. Always
bind them to `127.0.0.1:0` so the OS picks the port — a fixed port collides with
your own daemon on 6767.

**Break the thing before you claim a test covers it.** Test evidence here has
failed to survive independent re-running more than once: a failing transcript
from an incomplete revert, a test that passed against the very mutation it
targeted, and a test written in response to a crash that was shaped to pass.
Before saying a test covers something, make the change it should catch and
confirm the test goes red.

**Fixing a value is not fixing the arithmetic that consumes it.** Twice a fix
here has landed one line away from the bug it was meant to close. When you bound
a number, look at every use of it.

## What cannot be verified from a terminal

Icon appearance at Retina scale, click-through, reconnect behaviour, and
login-item registration are only verifiable by a human running the app. If your change touches those, say
plainly what you did and did not check rather than implying a check you could not
perform. Also note that launching the app writes real state into
`~/Library/Application Support/`, and that it shares a bundle id with any
installed copy, so the two cannot run at once.

## Pull requests

CI runs the typecheck, the build-tooling suite and `swift test` on macOS for
every pull request, and `main` requires it to pass. PRs are squash-merged, so the PR title becomes the
commit message on `main` — write it as one.
