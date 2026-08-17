import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";

const ROOT = process.cwd();
const OUT = path.join(ROOT, "assets", "generated");
const LUCIDE_ICONS_DIR = path.join(ROOT, "node_modules", "lucide-static", "icons");
const PASEO_LOGO_PATH = path.join(ROOT, "assets", "paseo-logo.svg");

// Lucide's 24x24 artboard with the default stroke-width="2" reads thin and
// weedy at a 16px menu-bar size, next to native items drawn with heavier
// strokes. Judged against the vendored default at both 16px and 32px, this
// reads clearly without the pinwheel's inner strokes starting to touch at
// 2x. Rasterizing straight from the source and upscaling afterward would
// blur rather than fix this, so the stroke goes into the markup before sharp
// ever sees it.
const LUCIDE_STROKE_WIDTH = 2.75;

// The Paseo mark is a filled organic shape sitting among stroked geometric
// glyphs, and straight from source it rendered smaller and lighter than all of
// them -- 81% of the canvas at 29% ink, against 94-100% and 40-66% for the
// Lucide set. Both numbers are corrected here rather than by editing the
// vendored logo, so re-vendoring it from upstream stays a plain copy.
//
// Scale is about the artboard centre. Stroke is in viewBox units (the logo's
// box is 700 wide) and dilates the filled path, which is what "thicker" means
// for a shape with no strokes of its own. Past roughly stroke 24 the mark's
// inner counters start closing up and it stops reading as the logo.
const PASEO_MARK_SCALE = 1.15;
const PASEO_MARK_STROKE = 16;

// One entry per workspace status bucket, in the app's own section order.
// `file` is the on-disk prefix -- camelCase so it stays a valid identifier,
// unlike the bucket name itself (`needs_input`).
const ICONS = [
  { bucket: "needs_input", file: "needsInput", source: { kind: "lucide", name: "megaphone" } },
  { bucket: "failed", file: "failed", source: { kind: "lucide", name: "circle-x" } },
  { bucket: "attention", file: "attention", source: { kind: "lucide", name: "triangle-alert" } },
  { bucket: "running", file: "running", source: { kind: "lucide", name: "loader-pinwheel" } },
  // The Paseo mark itself: the resting state shows the app's own identity
  // rather than a workspace glyph. See the design doc for why.
  { bucket: "done", file: "done", source: { kind: "paseo-mark" } },
];

async function lucideMarkup(name) {
  const raw = await readFile(path.join(LUCIDE_ICONS_DIR, `${name}.svg`), "utf8");
  // `stroke="currentColor"` never resolves when sharp rasterizes a standalone
  // SVG with no surrounding CSS `color` -- it renders empty rather than
  // erroring, so a missed substitution here is a silent blank icon.
  return raw
    .replaceAll('stroke="currentColor"', 'stroke="#000"')
    .replaceAll('stroke-width="2"', `stroke-width="${LUCIDE_STROKE_WIDTH}"`);
}

async function paseoMarkMarkup() {
  const raw = await readFile(PASEO_LOGO_PATH, "utf8");
  // Template images use only the alpha channel, so the fill color is cosmetic,
  // but a concrete black is conventional and keeps the source readable outside
  // the tray. The stroke matches the fill so it fattens the shape rather than
  // outlining it.
  const painted = raw.replace(
    'fill="white"',
    `fill="#000" stroke="#000" stroke-width="${PASEO_MARK_STROKE}" stroke-linejoin="round"`,
  );
  if (painted === raw) {
    // The vendored logo is a single `fill="white"` path; a re-vendored file that
    // paints itself differently would silently skip both corrections.
    throw new Error(`Expected a fill="white" path in ${PASEO_LOGO_PATH}`);
  }
  // Scaling about the centre keeps the mark where it is while it grows.
  return painted
    .replace(
      "<path ",
      `<g transform="translate(350,350) scale(${PASEO_MARK_SCALE}) translate(-350,-350)"><path `,
    )
    .replace("</svg>", "</g></svg>");
}

async function markupFor(source) {
  return source.kind === "lucide" ? lucideMarkup(source.name) : paseoMarkMarkup();
}

/**
 * A blank render is the exact failure mode `tray-presenter.ts` already
 * guards against at load time (`nativeImage.isEmpty()`), and it is silent at
 * the raster stage: sharp happily writes a fully-transparent PNG with no
 * warning. Fail the build instead of shipping one.
 */
async function assertNotBlank(buffer, file) {
  const { data } = await sharp(buffer).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  for (let i = 3; i < data.length; i += 4) {
    if (data[i] > 0) return;
  }
  throw new Error(`Rasterized icon has no opaque pixels: ${file}`);
}

await mkdir(OUT, { recursive: true });

for (const { file, source } of ICONS) {
  const svg = await markupFor(source);
  for (const scale of [1, 2]) {
    const size = 16 * scale;
    const suffix = scale === 1 ? "" : `@${scale}x`;
    const outFile = path.join(OUT, `${file}Template${suffix}.png`);
    const buffer = await sharp(Buffer.from(svg), { density: 72 * scale * 4 })
      .resize(size, size, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
      .png()
      .toBuffer();
    await assertNotBlank(buffer, outFile);
    await writeFile(outFile, buffer);
    console.log(`wrote ${outFile}`);
  }
}
