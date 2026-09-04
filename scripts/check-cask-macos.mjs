// Asserts that the Homebrew cask's `depends_on macos:` matches the macOS floor
// the built bundle actually declares.
//
// Nothing in this repo sets that floor. electron-builder.yml leaves
// `minimumSystemVersion` unset, so the bundle inherits whatever Electron
// requires, and an Electron major can raise it with no diff here at all:
// Electron 44 moved it from 12.0 to 13.0 while the cask still said
// `:monterey`. That combination fails in the worst available way -- Homebrew
// installs on the older macOS because the cask permits it, the app refuses to
// launch, and the maintainer never sees it because their own machine is newer.
//
// This runs from `npm run dist`, after electron-builder, rather than from the
// test suite. The floor lives in the built app's Info.plist, and there is no
// copy of it to check earlier: as of Electron 44 the package has no postinstall
// at all, so `npm ci` never puts a binary in node_modules and a unit test has
// nothing to read. Packaging is also the only moment the answer matters.
//
// The comparison itself is a pure function so it is tested against fixtures
// instead of against a 120MB build. It lives in scripts/ rather than src/
// because src/ is compiled into dist/ and packaged into the asar; build tooling
// has no business shipping to users.

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
if (import.meta.url === `file://${process.argv[1]}`) {
  const { readFile } = await import("node:fs/promises");
  const path = await import("node:path");

  const args = new Map();
  for (let i = 2; i < process.argv.length; i += 2) {
    args.set(process.argv[i].replace(/^--/, ""), process.argv[i + 1]);
  }

  const appPath =
    args.get("app") ?? path.join(process.cwd(), "release", "mac-arm64", "PaseoIcon.app");
  const caskPath = path.join(process.cwd(), "packaging", "homebrew", "paseo-menubar.rb");

  const { floor, symbol } = assertCaskMatchesBundle(
    await readFile(caskPath, "utf8"),
    await readFile(path.join(appPath, "Contents", "Info.plist"), "utf8"),
  );
  console.log(`cask requires macOS ${floor} (:${symbol}), matching the built bundle`);
}
