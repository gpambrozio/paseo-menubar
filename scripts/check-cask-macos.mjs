// Asserts that the Homebrew cask's `depends_on macos:` matches the macOS floor
// the built bundle actually declares.
//
// The floor is set in this repo now -- `MIN_MACOS` in native-bundle.mjs writes
// it into the Info.plist, and `platforms` in Package.swift has to agree -- but
// the check survives the move because the failure it catches does not depend on
// where the number comes from. A cask that permits an older macOS than the
// bundle requires fails in the worst available way: Homebrew installs happily,
// the app refuses to launch, and the maintainer never sees it because their own
// machine is newer. Under Electron this used to drift on its own, with an
// Electron major raising the floor with no diff here at all.
//
// native-bundle.mjs imports `assertCaskMatchesBundle` and calls it during
// `npm run dist`, right after the bundle is assembled. native-bundle.test.mjs
// compares the cask against `MIN_MACOS` early; this reads the built app's
// Info.plist, which is the only artifact that can disagree with both. The
// command-line entry point below is for checking a bundle by hand.
//
// The comparison itself is a pure function so it is tested against fixtures
// instead of against a whole build. Everything in scripts/ is build tooling
// that never ships: the app is a Swift package, and this file is plain .mjs
// that nothing compiles.

// Homebrew names macOS releases by symbol and the bundle records a number, so
// the two only meet through this table. A floor outside it throws rather than
// being guessed at -- a wrong guess here is exactly the silent breakage this
// script exists to prevent.
export const MACOS_SYMBOLS = new Map([
  ["12", "monterey"],
  ["13", "ventura"],
  ["14", "sonoma"],
  ["15", "sequoia"],
  ["26", "tahoe"],
]);

const LS_MINIMUM_SYSTEM_VERSION =
  /<key>LSMinimumSystemVersion<\/key>\s*<string>([\d.]+)<\/string>/;
const CASK_DEPENDS_ON_MACOS = /^\s*depends_on\s+macos:\s+:(\w+)\s*$/gm;

/** The macOS version string an Info.plist declares as its minimum. */
export function bundleMacOSFloor(infoPlistXml) {
  const floor = infoPlistXml.match(LS_MINIMUM_SYSTEM_VERSION)?.[1];
  if (!floor) {
    throw new Error(
      "no LSMinimumSystemVersion in the bundle's Info.plist. Without it there is " +
        "nothing to check the cask against, and a cask that permits too old a macOS " +
        "installs an app that cannot launch.",
    );
  }
  return floor;
}

/** The single macOS symbol the cask depends on. */
export function caskMacOSSymbol(caskSource) {
  const found = caskSource.match(CASK_DEPENDS_ON_MACOS) ?? [];
  if (found.length !== 1) {
    throw new Error(
      `expected exactly one \`depends_on macos:\` stanza in the cask, found ${found.length}. ` +
        `The cask is not shaped the way this script assumes, so its macOS requirement ` +
        `cannot be verified.`,
    );
  }
  return found[0].match(/:(\w+)\s*$/)[1];
}

/**
 * Throws unless the cask requires exactly the macOS the bundle declares.
 * Returns the agreed floor and symbol so the caller can report it.
 */
export function assertCaskMatchesBundle(caskSource, infoPlistXml) {
  const floor = bundleMacOSFloor(infoPlistXml);
  const major = floor.split(".")[0];
  const expected = MACOS_SYMBOLS.get(major);

  if (!expected) {
    throw new Error(
      `the bundle requires macOS ${floor}, which has no Homebrew symbol in ` +
        `MACOS_SYMBOLS. Add it there rather than leaving the cask unchecked.`,
    );
  }

  const actual = caskMacOSSymbol(caskSource);
  if (actual !== expected) {
    throw new Error(
      `the bundle requires macOS ${floor} (:${expected}) but the cask says :${actual}. ` +
        `Update \`depends_on macos:\` in packaging/homebrew/paseo-menubar.rb, and the ` +
        `macOS version README.md promises. Shipping as-is lets Homebrew install on a ` +
        `macOS the app cannot launch on.`,
    );
  }

  return { floor, symbol: expected };
}

// Usage: node scripts/check-cask-macos.mjs [--app release/mac-arm64/PaseoIcon.app]
// `import.meta.url` is realpath-resolved and percent-encoded; `process.argv[1]`
// is neither. Comparing them directly makes this whole block a silent no-op for
// a clone reached through any symlinked path, or one whose path has a space --
// the script runs, imports, does nothing, and exits 0. For this file that
// means writing no cask while the workflow reports success.
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
  const { readFile } = await import("node:fs/promises");
  const path = await import("node:path");

  const args = new Map();
  for (let i = 2; i < process.argv.length; i += 2) {
    args.set(process.argv[i].replace(/^--/, ""), process.argv[i + 1]);
  }

  const appPath =
    args.get("app") ?? path.join(process.cwd(), "release", "native", "PaseoIcon.app");
  const caskPath = path.join(process.cwd(), "packaging", "homebrew", "paseo-menubar.rb");

  const { floor, symbol } = assertCaskMatchesBundle(
    await readFile(caskPath, "utf8"),
    await readFile(path.join(appPath, "Contents", "Info.plist"), "utf8"),
  );
  console.log(`cask requires macOS ${floor} (:${symbol}), matching the built bundle`);
}
