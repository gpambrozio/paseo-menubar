import { describe, expect, it } from "vitest";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { BUNDLE_ID, BUNDLE_NAME, DISPLAY_NAME, MIN_MACOS, artifactNames, infoPlist } from "./native-bundle.mjs";
import { MACOS_SYMBOLS, assertCaskMatchesBundle, caskMacOSSymbol } from "./check-cask-macos.mjs";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const CASK_PATH = path.join(ROOT, "packaging", "homebrew", "paseo-menubar.rb");
const README_PATH = path.join(ROOT, "README.md");
const MANIFEST_PATH = path.join(ROOT, "PaseoIconPackage", "Package.swift");

describe("infoPlist", () => {
  it("declares the bundle the cask installs and the id the cask quits", () => {
    const plist = infoPlist({ version: "0.4.0" });
    expect(plist).toContain(`<key>CFBundleExecutable</key>\n\t<string>${BUNDLE_NAME}</string>`);
    expect(plist).toContain(`<key>CFBundleIdentifier</key>\n\t<string>${BUNDLE_ID}</string>`);
    expect(plist).toContain(`<key>CFBundleName</key>\n\t<string>${DISPLAY_NAME}</string>`);
  });

  it("marks the app as an agent, so it has no Dock icon", () => {
    // Without this the menu bar app also owns a Dock icon it has no window for.
    expect(infoPlist({ version: "0.4.0" })).toContain("<key>LSUIElement</key>\n\t<true/>");
  });

  it("carries the version into both version keys", () => {
    const plist = infoPlist({ version: "1.2.3" });
    expect(plist).toContain("<key>CFBundleShortVersionString</key>\n\t<string>1.2.3</string>");
    expect(plist).toContain("<key>CFBundleVersion</key>\n\t<string>1.2.3</string>");
  });

  it("refuses a version that is not three numbers", () => {
    // A malformed version reaches the cask's url and produces a 404 release
    // asset, which is only discovered by a user's failed install.
    expect(() => infoPlist({ version: "v1.2" })).toThrow(/1\.2\.3/);
    expect(() => infoPlist({})).toThrow(/1\.2\.3/);
  });

  it("declares the macOS floor the cask is held to", () => {
    expect(infoPlist({ version: "0.4.0" })).toContain(`<key>LSMinimumSystemVersion</key>\n\t<string>${MIN_MACOS}</string>`);
  });
});

describe("artifactNames", () => {
  it("names the assets with hyphens, the way the cask's url spells them", () => {
    // The cask downloads this exact name. electron-builder's publisher used to
    // rename its space-separated files on upload; producing them hyphenated
    // removes the rename step that nothing else validates.
    expect(artifactNames({ version: "0.4.0" })).toEqual({
      dmg: "Paseo-Icon-0.4.0-arm64.dmg",
      zip: "Paseo-Icon-0.4.0-arm64-mac.zip",
    });
  });

  it("requires a version", () => {
    expect(() => artifactNames({})).toThrow(/version/);
  });
});

describe("the cask and the native bundle agree", () => {
  it("installs the bundle this script builds", async () => {
    const cask = await readFile(CASK_PATH, "utf8");
    // Renaming the bundle breaks every `brew install` with "unable to locate
    // app", long after the release ships.
    expect(cask).toContain(`  app "${BUNDLE_NAME}.app"\n`);
  });

  it("quits the bundle id this script declares", async () => {
    const cask = await readFile(CASK_PATH, "utf8");
    // The app holds a menu bar item and no window, so a plain uninstall would
    // leave it running.
    expect(cask).toContain(`uninstall quit: "${BUNDLE_ID}"`);
  });

  it("requires the macOS this bundle declares", async () => {
    const cask = await readFile(CASK_PATH, "utf8");
    // The same comparison `npm run dist` runs against the built bundle, done
    // here against the plist this script would write, so a floor raised in
    // Package.swift and here fails the suite rather than a user's install.
    expect(assertCaskMatchesBundle(cask, infoPlist({ version: "0.4.0" }))).toEqual({
      floor: MIN_MACOS,
      symbol: MACOS_SYMBOLS.get(MIN_MACOS.split(".")[0]),
    });
  });

  it("names a macOS symbol check-cask-macos knows", async () => {
    const symbol = caskMacOSSymbol(await readFile(CASK_PATH, "utf8"));
    expect([...MACOS_SYMBOLS.values()]).toContain(symbol);
  });

  it("downloads the asset names this script produces", async () => {
    const cask = await readFile(CASK_PATH, "utf8");
    const version = cask.match(/^\s*version\s+"([^"]+)"$/m)?.[1];
    expect(version).toBeDefined();
    // The url interpolates #{version}; compare the rendered tail.
    expect(cask).toContain(artifactNames({ version: "VERSION" }).dmg.replace("VERSION", '#{version}'));
  });
});

describe("the packaging script is reachable the way the docs say", () => {
  // The Electron `dist` generated the icons before packaging. When it was
  // replaced, that step fell off, and the glyphs are gitignored -- so a clean
  // checkout packaged an app with no menu bar image and nothing said so. The
  // failure is invisible until someone launches the shipped build.
  it("regenerates the icons before it packages", async () => {
    const pkg = JSON.parse(await readFile(path.join(ROOT, "package.json"), "utf8"));
    expect(pkg.scripts.dist).toContain("icons");
    expect(pkg.scripts.dist).toContain("native-bundle.mjs");
  });

  it("ships the version the bundle will claim", async () => {
    // `npm run dist` with no --version falls back to this, so a stale number
    // here silently labels the artifacts with the previous release.
    const pkg = JSON.parse(await readFile(path.join(ROOT, "package.json"), "utf8"));
    expect(pkg.version).toMatch(/^\d+\.\d+\.\d+$/);
  });
});

describe("the package manifest and the native bundle agree", () => {
  // AGENTS.md names four places the macOS floor lives, and every other check
  // hangs off MIN_MACOS: this file compares it to the cask and the README, and
  // check-cask-macos.mjs compares the cask to the built Info.plist. Nothing
  // parsed the manifest, so raising `platforms` alone would leave the binary's
  // LC_BUILD_VERSION above the floor the plist, the cask and the README all
  // still advertise -- with every check green. Homebrew installs happily and
  // the app refuses to launch, on someone else's machine.
  it("declares the same macOS floor the bundle will claim", async () => {
    const manifest = await readFile(MANIFEST_PATH, "utf8");
    const declared = manifest.match(/\.macOS\(\.v(\d+)\)/);
    expect(declared).not.toBeNull();
    expect(declared[1]).toBe(MIN_MACOS.split(".")[0]);
  });
});

describe("the README and the native bundle agree", () => {
  // check-cask-macos.mjs already phrases its failure as "the macOS version
  // README.md promises", but nothing made that true. Raising the floor without
  // this test leaves the shipped doc telling people on the old macOS to install
  // an app Homebrew will refuse them, and no suite notices.
  it("promises the macOS this bundle requires", async () => {
    const readme = await readFile(README_PATH, "utf8");
    const major = MIN_MACOS.split(".")[0];
    expect(readme).toContain(`need macOS ${major} or later`);
  });
});
