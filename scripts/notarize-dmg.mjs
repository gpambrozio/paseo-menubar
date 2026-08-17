// Sign-adjacent half of the release: electron-builder notarizes the .app and
// staples a ticket into the bundle, but it does not notarize the disk image
// wrapped around it. With `dmg.sign: true` in electron-builder.yml the image is
// signed, and Apple's rule is that a signed disk image must also be notarized --
// so this script is not an optimization, it is what keeps the dmg valid.
//
// It runs from `npm run dist`, after electron-builder, rather than as an
// electron-builder hook: the hooks that fire early enough to precede publishing
// do not cleanly own the artifact list, and a stapled-after-upload dmg is
// exactly the failure this exists to prevent. See the note in
// .github/workflows/release.yml about the publishing path.

import { readdir } from "node:fs/promises";
import { spawn } from "node:child_process";
import path from "node:path";

const ROOT = process.cwd();
const RELEASE_DIR = path.join(ROOT, "release");

// notarytool takes credentials on argv, so nothing here echoes the command it
// runs -- an app-specific password in a build log is a credential leak.
const CREDENTIAL_ENV = ["APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD", "APPLE_TEAM_ID"];

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

async function runOrThrow(command, args, what) {
  const { code, stdout, stderr } = await run(command, args);
  if (code !== 0) {
    // `command` and `what` are safe to name; `args` may hold the password.
    throw new Error(`${what} failed (${command} exited ${code})\n${stderr || stdout}`);
  }
  return stdout;
}

function readCredentials() {
  const missing = CREDENTIAL_ENV.filter((name) => !process.env[name]);
  if (missing.length > 0) {
    throw new Error(
      `Cannot notarize the dmg: ${missing.join(", ")} not set. ` +
        `APPLE_ID is the Apple account email, APPLE_APP_SPECIFIC_PASSWORD an ` +
        `app-specific password from appleid.apple.com, and APPLE_TEAM_ID the ` +
        `10-character team from the signing certificate's common name.`,
    );
  }
  return [
    "--apple-id",
    process.env.APPLE_ID,
    "--password",
    process.env.APPLE_APP_SPECIFIC_PASSWORD,
    "--team-id",
    process.env.APPLE_TEAM_ID,
  ];
}

async function findDiskImages() {
  const entries = await readdir(RELEASE_DIR).catch(() => {
    throw new Error(`No ${RELEASE_DIR} directory -- run electron-builder first`);
  });
  const images = entries.filter((name) => name.endsWith(".dmg"));
  if (images.length === 0) {
    // Silence here would read as success while shipping nothing notarized.
    throw new Error(`No .dmg found in ${RELEASE_DIR} -- did the DMG target build?`);
  }
  return images.map((name) => path.join(RELEASE_DIR, name));
}

/**
 * Submitting an unsigned image earns a slow round trip and an opaque rejection
 * from Apple. `dmg.sign: true` is what should have signed it, so an unsigned
 * image here means that setting was lost, and saying so is more useful than
 * relaying whatever notarytool decides to complain about.
 */
async function assertSigned(image) {
  const { code, stderr } = await run("codesign", ["-dv", image]);
  if (code !== 0) {
    throw new Error(
      `${path.basename(image)} is not signed (${stderr.trim()}). ` +
        `Check that electron-builder.yml still sets dmg.sign: true.`,
    );
  }
}

/**
 * Apple accepting the submission is not the same as the ticket being attached:
 * stapling is a separate local step that can fail on its own. Read both back
 * off the finished file rather than trusting the two exit codes above.
 */
async function assertNotarized(image) {
  await runOrThrow("xcrun", ["stapler", "validate", image], "Staple validation");
  await runOrThrow(
    "spctl",
    ["-a", "-vvv", "-t", "open", "--context", "context:primary-signature", image],
    "Gatekeeper assessment",
  );
}

const credentials = readCredentials();

for (const image of await findDiskImages()) {
  const name = path.basename(image);
  await assertSigned(image);
  console.log(`submitting ${name} to Apple; this waits on their queue`);
  const output = await runOrThrow(
    "xcrun",
    ["notarytool", "submit", image, ...credentials, "--wait"],
    `Notarizing ${name}`,
  );
  // notarytool exits 0 for a submission that finished but was rejected, so the
  // status line is the thing that actually decides.
  if (!/status:\s*Accepted/i.test(output)) {
    throw new Error(`Apple did not accept ${name}:\n${output}`);
  }
  await runOrThrow("xcrun", ["stapler", "staple", image], `Stapling ${name}`);
  await assertNotarized(image);
  console.log(`notarized and stapled ${name}`);
}
