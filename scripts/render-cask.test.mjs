import { describe, expect, it } from "vitest";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { renderCask } from "./render-cask.mjs";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const TEMPLATE_PATH = path.join(ROOT, "packaging", "homebrew", "paseo-menubar.rb");

const SHA = "a".repeat(64);
const OTHER_SHA = "b".repeat(64);

async function template() {
  return await readFile(TEMPLATE_PATH, "utf8");
}

describe("renderCask", () => {
  it("rewrites the version and sha256 stanzas", async () => {
    const out = renderCask(await template(), { version: "0.2.0", sha256: SHA });

    expect(out).toContain(`  version "0.2.0"\n`);
    expect(out).toContain(`  sha256 "${SHA}"\n`);
  });

  it("changes nothing but those two lines", async () => {
    const source = await template();
    const out = renderCask(source, { version: "0.2.0", sha256: SHA });

    const changed = source
      .split("\n")
      .map((line, index) => [line, out.split("\n")[index]])
      .filter(([before, after]) => before !== after);

    expect(changed).toEqual([
      [`  version "0.1.0"`, `  version "0.2.0"`],
      [
        `  sha256 "b7843da2e2cabc56db02565818abe2ad5c9d0896b041228e8ee2b76c0c44d00d"`,
        `  sha256 "${SHA}"`,
      ],
    ]);
  });

  // The url stanza interpolates #{version}, so rewriting the version stanza is
  // what moves the download. If someone ever inlines the version into the url,
  // this catches it -- the rendered cask would otherwise point at the old file
  // while advertising the new version.
  it("leaves no trace of the previous version", async () => {
    const out = renderCask(await template(), { version: "0.2.0", sha256: SHA });
    // Comments are prose and may cite a concrete filename as an example; it is
    // the executable stanzas that must not carry a stale version.
    const stanzas = out
      .split("\n")
      .filter((line) => !line.trimStart().startsWith("#"))
      .join("\n");

    expect(stanzas).not.toContain("0.1.0");
    expect(stanzas).not.toContain(
      "b7843da2e2cabc56db02565818abe2ad5c9d0896b041228e8ee2b76c0c44d00d",
    );
  });

  it("is idempotent when re-rendered with the same inputs", async () => {
    const once = renderCask(await template(), { version: "0.2.0", sha256: SHA });
    const twice = renderCask(once, { version: "0.2.0", sha256: SHA });

    expect(twice).toBe(once);
  });

  it("can re-render an already-rendered cask", async () => {
    const once = renderCask(await template(), { version: "0.2.0", sha256: SHA });
    const twice = renderCask(once, { version: "0.3.0", sha256: OTHER_SHA });

    expect(twice).toContain(`  version "0.3.0"\n`);
    expect(twice).toContain(`  sha256 "${OTHER_SHA}"\n`);
  });

  // A silent no-op is the failure worth engineering against: it would push a
  // cask that pins the previous checksum against the new version's url, and
  // every `brew install` would fail its integrity check.
  it("throws when there is no version stanza to rewrite", () => {
    const source = `cask "x" do\n  sha256 "${SHA}"\nend\n`;

    expect(() => renderCask(source, { version: "0.2.0", sha256: OTHER_SHA })).toThrow(
      /version stanza/i,
    );
  });

  it("throws when there is no sha256 stanza to rewrite", () => {
    const source = `cask "x" do\n  version "0.1.0"\nend\n`;

    expect(() => renderCask(source, { version: "0.2.0", sha256: SHA })).toThrow(/sha256 stanza/i);
  });

  it("throws when a stanza appears more than once", () => {
    const source = `cask "x" do\n  version "0.1.0"\n  version "0.1.0"\n  sha256 "${SHA}"\nend\n`;

    expect(() => renderCask(source, { version: "0.2.0", sha256: OTHER_SHA })).toThrow(
      /version stanza/i,
    );
  });

  it.each([
    ["v0.2.0", /leading v/i],
    ["", /version/i],
    ["  ", /version/i],
  ])("rejects the version %j", async (version, message) => {
    expect(() => renderCask("", { version, sha256: SHA })).toThrow(message);
  });

  it.each([
    ["too short", "abc"],
    ["uppercase hex", "A".repeat(64)],
    ["non-hex", "z".repeat(64)],
    ["prefixed", `sha256:${SHA}`],
  ])("rejects a %s sha256", (_label, sha256) => {
    expect(() => renderCask("", { version: "0.2.0", sha256 })).toThrow(/sha256/i);
  });
});

// The macOS floor is the one cask stanza nothing in this repo controls.
// electron-builder.yml leaves `minimumSystemVersion` unset, so the bundle
// inherits whatever the pinned Electron requires -- Electron 44 moved it from
// 12.0 to 13.0 with no diff here at all. A stale `depends_on macos:` is
// invisible to whoever ships the release: Homebrew installs on the older macOS
// and the app then refuses to launch, on someone else's machine.
//
// Homebrew names releases by symbol and the bundle records a number, so the two
// only meet through this table. An Electron that demands something outside it
// fails here rather than being guessed at.
const MACOS_SYMBOLS = new Map([
  ["12", "monterey"],
  ["13", "ventura"],
  ["14", "sonoma"],
  ["15", "sequoia"],
  ["26", "tahoe"],
]);

const ELECTRON_INFO_PLIST = path.join(
  ROOT,
  "node_modules",
  "electron",
  "dist",
  "Electron.app",
  "Contents",
  "Info.plist",
);

/**
 * The macOS version the built bundle will declare. An explicit
 * `minimumSystemVersion` in electron-builder.yml wins; otherwise it is whatever
 * the installed Electron asks for.
 */
async function bundleMacOSFloor() {
  const builder = await readFile(path.join(ROOT, "electron-builder.yml"), "utf8");
  const override = builder.match(/^\s+minimumSystemVersion:\s*"?([\d.]+)"?\s*$/m)?.[1];
  if (override) return override;

  // Deliberately not a skip. Electron's binary is a postinstall download, and
  // an absent one means this checkout cannot build the app either -- reporting
  // that is more useful than passing a test that checked nothing.
  let plist;
  try {
    plist = await readFile(ELECTRON_INFO_PLIST, "utf8");
  } catch {
    throw new Error(
      `Electron's Info.plist is missing at ${ELECTRON_INFO_PLIST}. Its postinstall ` +
        "download did not run; 'node node_modules/electron/install.js' fetches it.",
    );
  }
  return plist.match(
    /<key>LSMinimumSystemVersion<\/key>\s*<string>([\d.]+)<\/string>/,
  )?.[1];
}

describe("the cask requires the macOS the bundle actually needs", () => {
  it("names the same floor Electron imposes", async () => {
    const floor = await bundleMacOSFloor();
    expect(floor).toBeDefined();

    const major = floor.split(".")[0];
    const symbol = MACOS_SYMBOLS.get(major);
    expect(
      symbol,
      `No Homebrew symbol known for macOS ${floor}. Add it to MACOS_SYMBOLS.`,
    ).toBeDefined();

    expect(await template()).toContain(`  depends_on macos: :${symbol}\n`);
  });
});

// The cask names the bundle directory, which comes from `executableName` in
// electron-builder.yml and not from productName. Changing that field renames
// PaseoIcon.app and silently breaks every `brew install --cask` with an
// "unable to locate app" long after the release ships.
describe("the cask and electron-builder agree", () => {
  it("installs the bundle that electron-builder.yml names", async () => {
    const builder = await readFile(path.join(ROOT, "electron-builder.yml"), "utf8");
    const executableName = builder.match(/^executableName:\s*(\S+)$/m)?.[1];

    expect(executableName).toBeDefined();
    expect(await template()).toContain(`  app "${executableName}.app"\n`);
  });

  it("publishes to the repo the cask downloads from", async () => {
    const builder = await readFile(path.join(ROOT, "electron-builder.yml"), "utf8");
    const owner = builder.match(/^\s+owner:\s*(\S+)$/m)?.[1];
    const repo = builder.match(/^\s+repo:\s*(\S+)$/m)?.[1];

    expect(await template()).toContain(`https://github.com/${owner}/${repo}/releases/download/`);
  });
});
