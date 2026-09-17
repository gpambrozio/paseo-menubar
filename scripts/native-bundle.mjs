// Builds, signs, notarizes, and staples the native PaseoIcon.app, then wraps
// it in the dmg and zip the Homebrew cask downloads.
//
// This replaces electron-builder for the native app. It is a script rather
// than a build-system plugin for the same reason notarize-dmg.mjs is: the
// order matters and has to be visible. Signing happens after the bundle is
// complete, notarization after signing, stapling after Apple accepts, and the
// dmg is built from the stapled bundle — an image made before stapling ships
// an app Gatekeeper rejects.
//
// The pure parts (the Info.plist, the artifact names) are exported and tested;
// the rest shells out and is exercised by running it.

import { spawn } from "node:child_process";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";

/** The bundle directory name. Not the display name, and not the cask token. */
export const BUNDLE_NAME = "PaseoIcon";
export const DISPLAY_NAME = "Paseo Icon";
export const BUNDLE_ID = "br.eng.gustavo.paseo-menubar";
/**
 * The macOS floor. It is declared here and in Package.swift's `platforms`,
 * and `scripts/check-cask-macos.mjs` reads it back out of the built bundle to
 * hold the cask to it. Raising it means raising all three.
 */
export const MIN_MACOS = "14.0";

/** notarytool takes credentials on argv, so nothing here echoes its command. */
const CREDENTIAL_ENV = ["APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD", "APPLE_TEAM_ID"];

/**
 * The bundle's Info.plist. `LSUIElement` is what keeps the app out of the
 * Dock; without it the menu bar app also owns a Dock icon it has no window
 * for.
 */
export function infoPlist({ version }) {
  if (!/^\d+\.\d+\.\d+$/.test(version ?? "")) {
    throw new Error(`version must look like 1.2.3, got ${JSON.stringify(version)}`);
  }
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleDevelopmentRegion</key>
\t<string>en</string>
\t<key>CFBundleDisplayName</key>
\t<string>${DISPLAY_NAME}</string>
\t<key>CFBundleExecutable</key>
\t<string>${BUNDLE_NAME}</string>
\t<key>CFBundleIconFile</key>
\t<string>icon</string>
\t<key>CFBundleIdentifier</key>
\t<string>${BUNDLE_ID}</string>
\t<key>CFBundleInfoDictionaryVersion</key>
\t<string>6.0</string>
\t<key>CFBundleName</key>
\t<string>${DISPLAY_NAME}</string>
\t<key>CFBundlePackageType</key>
\t<string>APPL</string>
\t<key>CFBundleShortVersionString</key>
\t<string>${version}</string>
\t<key>CFBundleVersion</key>
\t<string>${version}</string>
\t<key>LSApplicationCategoryType</key>
\t<string>public.app-category.developer-tools</string>
\t<key>LSMinimumSystemVersion</key>
\t<string>${MIN_MACOS}</string>
\t<key>LSUIElement</key>
\t<true/>
\t<key>NSHighResolutionCapable</key>
\t<true/>
\t<key>NSHumanReadableCopyright</key>
\t<string>Copyright © 2026 Gustavo Ambrozio</string>
</dict>
</plist>
`;
}

/**
 * The release asset names. The cask's `url` is built from these, and the
 * hyphens are not cosmetic: electron-builder's publisher renamed its
 * space-separated files on upload, the cask was written against those names,
 * and a manual upload has to match. Producing them hyphenated here removes
 * the rename step that nothing else validates.
 */
export function artifactNames({ version }) {
  if (!version) throw new Error("version is required");
  return {
    dmg: `Paseo-Icon-${version}-arm64.dmg`,
    zip: `Paseo-Icon-${version}-arm64-mac.zip`,
  };
}

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"], ...options });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

async function runOrThrow(command, args, what, options) {
  const { code, stdout, stderr } = await run(command, args, options);
  // `args` may hold the app-specific password, so only the command is named.
  if (code !== 0) throw new Error(`${what} failed (${command} exited ${code})\n${stderr || stdout}`);
  return stdout;
}

function readCredentials() {
  const missing = CREDENTIAL_ENV.filter((name) => !process.env[name]);
  if (missing.length > 0) {
    throw new Error(
      `Cannot notarize: ${missing.join(", ")} not set. APPLE_ID is the Apple ` +
        `account email, APPLE_APP_SPECIFIC_PASSWORD an app-specific password from ` +
        `appleid.apple.com, and APPLE_TEAM_ID the 10-character team from the ` +
        `signing certificate's common name.`,
    );
  }
  return [
    "--apple-id", process.env.APPLE_ID,
    "--password", process.env.APPLE_APP_SPECIFIC_PASSWORD,
    "--team-id", process.env.APPLE_TEAM_ID,
  ];
}

/** Renders the 1024px app icon into the .icns macOS actually reads. */
async function buildIcns(root, resourcesDir) {
  const source = path.join(root, "assets", "generated", "icon.png");
  const iconset = path.join(root, "release", "native", "icon.iconset");
  await rm(iconset, { recursive: true, force: true });
  await mkdir(iconset, { recursive: true });
  for (const size of [16, 32, 128, 256, 512]) {
    await runOrThrow("sips", ["-z", String(size), String(size), source, "--out", path.join(iconset, `icon_${size}x${size}.png`)], "Rendering icon");
    await runOrThrow("sips", ["-z", String(size * 2), String(size * 2), source, "--out", path.join(iconset, `icon_${size}x${size}@2x.png`)], "Rendering icon");
  }
  await runOrThrow("iconutil", ["-c", "icns", iconset, "-o", path.join(resourcesDir, "icon.icns")], "Building icns");
}

/**
 * Assembles the bundle from a release build. The tray PNGs come from the
 * Swift package's own resource bundle, which `swift build` produces beside the
 * executable, so the app finds them through `Bundle.module` exactly as it does
 * under `swift run`.
 */
export async function buildBundle({ root, version }) {
  // Checked here rather than only where the plist is written: that happens
  // after `swift build -c release`, so a typo in --version would burn the whole
  // release build before saying so.
  infoPlist({ version });
  const out = path.join(root, "release", "native");
  const app = path.join(out, `${BUNDLE_NAME}.app`);
  await rm(app, { recursive: true, force: true });
  const macos = path.join(app, "Contents", "MacOS");
  const resources = path.join(app, "Contents", "Resources");
  await mkdir(macos, { recursive: true });
  await mkdir(resources, { recursive: true });

  await runOrThrow("swift", ["build", "-c", "release", "--package-path", "PaseoIconPackage", "--product", BUNDLE_NAME], "Building the app", { cwd: root });
  const binDir = (await runOrThrow("swift", ["build", "-c", "release", "--package-path", "PaseoIconPackage", "--show-bin-path"], "Locating the build", { cwd: root })).trim();

  await runOrThrow("cp", [path.join(binDir, BUNDLE_NAME), path.join(macos, BUNDLE_NAME)], "Copying the executable");
  // The resource bundle SwiftPM emits for the app target, carrying the tray icons.
  await runOrThrow("cp", ["-R", path.join(binDir, "PaseoIconPackage_PaseoIcon.bundle"), resources], "Copying resources");
  await writeFile(path.join(app, "Contents", "Info.plist"), infoPlist({ version }));
  await writeFile(path.join(app, "Contents", "PkgInfo"), "APPL????");
  await buildIcns(root, resources);
  await runOrThrow("plutil", ["-lint", path.join(app, "Contents", "Info.plist")], "Validating Info.plist");
  return app;
}

/**
 * Signs with the hardened runtime and a secure timestamp, both of which
 * notarization requires. Deep, because the resource bundle is inside.
 */
export async function sign(app, identity) {
  await runOrThrow("codesign", ["--force", "--deep", "--options", "runtime", "--timestamp", "--sign", identity, app], "Signing");
  await runOrThrow("codesign", ["--verify", "--strict", "--deep", app], "Verifying the signature");
}

/**
 * Submits, waits, and staples. Apple accepting the submission is not the same
 * as the ticket being attached, so both are read back off the finished bundle.
 */
export async function notarize(app, out) {
  const credentials = readCredentials();
  const zip = path.join(out, "notarize.zip");
  // Scratch, not an artifact: removed on the way out whether Apple accepted or
  // refused, so a rejected submission does not leave it beside the real dmg.
  try {
    await runOrThrow("ditto", ["-c", "-k", "--keepParent", app, zip], "Zipping for notarization");
    console.log(`submitting ${path.basename(app)} to Apple; this waits on their queue`);
    const output = await runOrThrow("xcrun", ["notarytool", "submit", zip, ...credentials, "--wait"], "Notarizing");
    // notarytool exits 0 for a submission that finished but was rejected, so the
    // status line is what actually decides.
    if (!/status:\s*Accepted/i.test(output)) throw new Error(`Apple did not accept the app:\n${output}`);
    await runOrThrow("xcrun", ["stapler", "staple", app], "Stapling");
    await runOrThrow("xcrun", ["stapler", "validate", app], "Validating the staple");
    await runOrThrow("spctl", ["-a", "-t", "exec", "-vv", app], "Gatekeeper assessment");
  } finally {
    await rm(zip, { force: true });
  }
}

/** The dmg and zip, built from the stapled bundle, never before it. */
export async function makeArtifacts({ app, out, version }) {
  const names = artifactNames({ version });
  const dmg = path.join(out, names.dmg);
  const zip = path.join(out, names.zip);
  await rm(dmg, { force: true });
  await rm(zip, { force: true });

  const staging = path.join(out, "dmg-staging");
  await rm(staging, { recursive: true, force: true });
  await mkdir(staging, { recursive: true });
  await runOrThrow("cp", ["-R", app, path.join(staging, path.basename(app))], "Staging the dmg");
  await runOrThrow("ln", ["-s", "/Applications", path.join(staging, "Applications")], "Linking Applications");
  await runOrThrow("hdiutil", ["create", "-volname", DISPLAY_NAME, "-srcfolder", staging, "-ov", "-format", "UDZO", dmg], "Building the dmg");
  await rm(staging, { recursive: true, force: true });

  // The zip carries the stapled bundle as-is; `ditto` preserves the signature.
  await runOrThrow("ditto", ["-c", "-k", "--keepParent", app, zip], "Building the zip");
  return { dmg, zip };
}

// Usage: node scripts/native-bundle.mjs --version 0.4.0 [--identity "Developer ID Application: ..."] [--skip-notarize]
if (import.meta.url === `file://${process.argv[1]}`) {
  const args = new Map();
  for (let i = 2; i < process.argv.length; i++) {
    const flag = process.argv[i];
    if (!flag.startsWith("--")) continue;
    const next = process.argv[i + 1];
    if (next && !next.startsWith("--")) {
      args.set(flag.slice(2), next);
      i++;
    } else {
      args.set(flag.slice(2), true);
    }
  }

  const root = process.cwd();
  const version = args.get("version") ?? JSON.parse(await readFile(path.join(root, "package.json"), "utf8")).version;
  const out = path.join(root, "release", "native");
  await mkdir(out, { recursive: true });

  const app = await buildBundle({ root, version });
  console.log(`built ${app}`);

  const identity = args.get("identity") ?? process.env.CODESIGN_IDENTITY;
  if (!identity) {
    // Unsigned is a legitimate local build; shipping one is not, so it says so.
    console.log("no --identity and no CODESIGN_IDENTITY: leaving the bundle unsigned, which is fine locally and never shippable");
    process.exit(0);
  }
  await sign(app, identity);
  console.log("signed");

  if (args.get("skip-notarize")) {
    console.log("--skip-notarize: stopping before Apple");
    process.exit(0);
  }
  await notarize(app, out);
  console.log("notarized and stapled");

  const { dmg, zip } = await makeArtifacts({ app, out, version });
  console.log(`wrote ${path.basename(dmg)} and ${path.basename(zip)}`);
}
