# Contributing

Thanks for looking. Issues and pull requests are welcome — this is a small
project, so the shortest path is usually to open an issue first and check the
change makes sense before writing it.

## Getting set up

```bash
SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install
npm run typecheck
npm test
```

The `SHARP_IGNORE_GLOBAL_LIBVIPS` flag is only needed if you have Homebrew's
`libvips` installed; see the Development section of the [README](README.md) for
the rest of the scripts.

There is no linter. Match the style of the code around you.

## Read the design docs first

`docs/superpowers/` holds four documents and they are not equals. The two design
documents bind; the implementation plan and the registry-sync plan are historical
records with known defects, kept because they explain why things are shaped the
way they are, not because they are correct. [CLAUDE.md](CLAUDE.md) has the table.

If a change disagrees with a design document, the document wins until it is
changed deliberately.

## Where code goes

The rule that shapes this codebase: **if it does not touch Electron, it does not
belong in `src/main.ts`.** Electron appears in exactly two modules — `src/main.ts`
and `src/tray/tray-presenter.ts`. Everything else is pure or takes its
collaborators by injection, and is tested without an Electron harness. If you
find yourself adding a decision to `main.ts`, that is the signal to extract it
into a module that can be tested. CLAUDE.md has the full module map.

A few rules that are easy to violate without knowing:

- **Never create a `BrowserWindow`.** This app needs no web contents.
- **Never derive a workspace's state.** Render the status the daemon computed.
  A second copy of that rule here is a second answer, and no test in either repo
  would catch the day they diverge.
- **Never crash the tray.** Bad input keeps the last known-good state and
  surfaces an error row. A `void`-ed promise that can reject is a bug.
- **No silent caps.** Any truncated list renders a visible overflow row.
- **The Paseo SDK is pinned exactly** at `0.4.0`, with no caret. Drifting it
  forward voids the compatibility reasoning that makes pinning safe.

## Testing

```bash
npx vitest run
```

Integration tests boot a real daemon in-process and are slow by design. Always
bind them to `127.0.0.1:0` so the OS picks the port — a fixed port collides with
your own daemon on 6767.

**Break the thing before you claim a test covers it.** Twice in this repo, test
evidence did not survive independent re-running: one failing transcript came from
an incomplete revert, and one test passed against the very mutation it targeted.
Before saying a test covers something, make the change it should catch and
confirm the test goes red.

## What cannot be verified from a terminal

Icon states, click-through, reconnect behaviour, and login-item registration are
only verifiable by a human running the app. If your change touches those, say
plainly what you did and did not check rather than implying a check you could not
perform. Also note that launching the app writes real state into
`~/Library/Application Support/Paseo Icon/`.

## Pull requests

CI runs `npm run typecheck && npm test` on macOS for every pull request, and
`main` requires it to pass. PRs are squash-merged, so the PR title becomes the
commit message on `main` — write it as one.
