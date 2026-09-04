import { describe, expect, it } from "vitest";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  MACOS_SYMBOLS,
  assertCaskMatchesBundle,
  bundleMacOSFloor,
  caskMacOSSymbol,
} from "./check-cask-macos.mjs";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const CASK_PATH = path.join(ROOT, "packaging", "homebrew", "paseo-menubar.rb");

// Fixtures rather than a real build: the check runs against a 120MB bundle that
// only exists after `npm run dist`, and the logic being tested is the
// comparison, not the packaging.
function plist(floor) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Paseo Icon</string>
	<key>LSMinimumSystemVersion</key>
	<string>${floor}</string>
</dict>
</plist>
`;
}

const cask = (symbol) => `cask "paseo-menubar" do\n  depends_on macos: :${symbol}\n  depends_on arch: :arm64\nend\n`;

describe("bundleMacOSFloor", () => {
  it("reads the version out of an Info.plist", () => {
    expect(bundleMacOSFloor(plist("13.0"))).toBe("13.0");
  });

  it("throws when the plist declares no floor at all", () => {
    expect(() => bundleMacOSFloor(plist("13.0").replace(/LSMinimumSystemVersion/, "Other"))).toThrow(
      /no LSMinimumSystemVersion/i,
    );
  });
});

describe("caskMacOSSymbol", () => {
  it("reads the symbol the cask depends on", () => {
    expect(caskMacOSSymbol(cask("ventura"))).toBe("ventura");
  });

  it("throws when the cask has no macOS requirement", () => {
    expect(() => caskMacOSSymbol(`cask "x" do\n  depends_on arch: :arm64\nend\n`)).toThrow(
      /found 0/,
    );
  });

  it("throws when the cask has more than one, since only one can be right", () => {
    expect(() => caskMacOSSymbol(cask("ventura") + cask("sonoma"))).toThrow(/found 2/);
  });
});

describe("assertCaskMatchesBundle", () => {
  it("passes when the cask names the floor the bundle declares", () => {
    expect(assertCaskMatchesBundle(cask("ventura"), plist("13.0"))).toEqual({
      floor: "13.0",
      symbol: "ventura",
    });
  });

  it("ignores the patch component, which Homebrew has no symbol for", () => {
    expect(assertCaskMatchesBundle(cask("ventura"), plist("13.5.2")).symbol).toBe("ventura");
  });

  // The exact regression this exists for: Electron 44 raised the floor to 13.0
  // while the cask still said :monterey.
  it("fails when an Electron bump raised the floor past what the cask allows", () => {
    expect(() => assertCaskMatchesBundle(cask("monterey"), plist("13.0"))).toThrow(
      /requires macOS 13\.0 \(:ventura\) but the cask says :monterey/,
    );
  });

  it("fails when the cask is stricter than the bundle, which locks out users for nothing", () => {
    expect(() => assertCaskMatchesBundle(cask("sonoma"), plist("13.0"))).toThrow(/:sonoma/);
  });

  it("refuses a macOS version it has no symbol for rather than guessing", () => {
    expect(() => assertCaskMatchesBundle(cask("ventura"), plist("99.0"))).toThrow(
      /no Homebrew symbol/i,
    );
  });
});

describe("the cask as it stands", () => {
  it("names a macOS symbol this script knows", async () => {
    const symbol = caskMacOSSymbol(await readFile(CASK_PATH, "utf8"));
    expect([...MACOS_SYMBOLS.values()]).toContain(symbol);
  });
});
