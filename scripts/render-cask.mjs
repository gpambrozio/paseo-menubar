// Rewrites the version and sha256 of the Homebrew cask in
// packaging/homebrew/paseo-menubar.rb so .github/workflows/homebrew-cask.yml can
// publish it to gpambrozio/homebrew-tap.
//
// This is two lines of substitution, and it is a tested module rather than a
// `sed` in the workflow for one reason: a substitution that matches nothing
// fails silently. The result would be a cask advertising the new version while
// pinning the previous release's checksum, so every `brew install --cask` dies
// on an integrity mismatch -- and the workflow would be green. Every path
// through renderCask either changes the line or throws.
//
// It lives in scripts/ rather than src/ because src/ is compiled into dist/ and
// packaged into the asar; build tooling has no business shipping to users.

const VERSION_PATTERN = /^(\s*version\s+)"[^"]*"$/gm;
const SHA256_PATTERN = /^(\s*sha256\s+)"[^"]*"$/gm;
const SHA256_FORMAT = /^[0-9a-f]{64}$/;

function replaceExactlyOnce(source, pattern, replacement, stanza) {
  // `pattern` is /g, so lastIndex would carry over between calls on a shared
  // regex. Counting via match() and replacing separately keeps each call
  // independent of the last.
  const found = source.match(pattern) ?? [];
  if (found.length !== 1) {
    throw new Error(
      `expected exactly one ${stanza} stanza to rewrite, found ${found.length}. ` +
        `The cask template is not shaped the way this script assumes, and rewriting ` +
        `it anyway would publish a cask that does not match the release.`,
    );
  }
  return source.replace(pattern, `$1"${replacement}"`);
}

/**
 * @param {string} source        the cask file, as text
 * @param {{version: string, sha256: string}} release
 * @returns {string} the cask with `version` and `sha256` pointing at `release`
 */
export function renderCask(source, { version, sha256 }) {
  if (!version || !version.trim()) {
    throw new Error("version is required to render the cask");
  }
  // Homebrew interpolates `version` straight into the download url, and the
  // release assets are named 0.1.0 while the git tag is v0.1.0. A leading v
  // here produces a url that 404s, so reject it rather than guessing.
  if (/^v/i.test(version)) {
    throw new Error(
      `version "${version}" has a leading v; pass the release version, not the tag name`,
    );
  }
  if (!SHA256_FORMAT.test(sha256)) {
    throw new Error(
      `sha256 "${sha256}" is not 64 lowercase hex characters; pass the bare digest, ` +
        `not a "sha256:" prefixed or uppercase one`,
    );
  }

  const withVersion = replaceExactlyOnce(source, VERSION_PATTERN, version, "version");
  return replaceExactlyOnce(withVersion, SHA256_PATTERN, sha256, "sha256");
}

// CLI: node scripts/render-cask.mjs --version 0.2.0 --sha256 <digest> \
//        [--template packaging/homebrew/paseo-menubar.rb] [--out -]
if (import.meta.url === `file://${process.argv[1]}`) {
  const { readFile, writeFile } = await import("node:fs/promises");
  const path = await import("node:path");

  const args = new Map();
  for (let i = 2; i < process.argv.length; i += 2) {
    args.set(process.argv[i].replace(/^--/, ""), process.argv[i + 1]);
  }

  const templatePath =
    args.get("template") ?? path.join(process.cwd(), "packaging", "homebrew", "paseo-menubar.rb");
  const rendered = renderCask(await readFile(templatePath, "utf8"), {
    version: args.get("version"),
    sha256: args.get("sha256"),
  });

  const out = args.get("out");
  if (!out || out === "-") {
    process.stdout.write(rendered);
  } else {
    await writeFile(out, rendered);
    console.log(`wrote ${out} for ${args.get("version")}`);
  }
}
