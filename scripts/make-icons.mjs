import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";

const ROOT = process.cwd();
const OUT = path.join(ROOT, "assets", "generated");
const LUCIDE_ICONS_DIR = path.join(ROOT, "node_modules", "lucide-static", "icons");
const PASEO_LOGO_PATH = path.join(ROOT, "assets", "paseo-logo.svg");
const PASEO_APP_ICON_PATH = path.join(ROOT, "assets", "paseo-app-icon.svg");

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

// The app icon -- the Finder, Dock-recents, dmg-window, and About-panel face of
// the app, not the tray image. electron-builder converts a single PNG into the
// .icns itself and wants at least 512x512; 1024 is the largest slot macOS asks
// for, so rendering that one size and letting it downsample beats hand-keeping
// an iconset.
const APP_ICON_SIZE = 1024;

// Paseo's own app icon holds its rounded tile at 88.3% of the canvas -- 452 of
// 512 px, measured off `packages/desktop/assets/icon.png` upstream. These two
// apps sit next to each other in the Finder, so the inset is matched to that
// rather than to the 80.5% of Apple's own icon template.
const APP_TILE_FRACTION = 0.8828;

// The notification badge, which is the whole visual difference between this
// icon and Paseo's: same mark, plus the dot that says "indicator". Every number
// is a fraction of the canvas so the badge survives being downsampled to the
// 16px slot with the rest of the icon.
//
// The ring is not decoration. The badge is deliberately large enough to overhang
// the tile's bottom-right corner, which puts part of the red on black and part
// of it on whatever is behind the icon; without a ring the overhanging arc
// disappears against a red-ish wallpaper or a Finder selection highlight.
const BADGE_RADIUS_FRACTION = 0.125;
const BADGE_RING_FRACTION = 0.022;
const BADGE_MARGIN_FRACTION = 0.008;
const BADGE_FILL = { r: 0xff, g: 0x3b, b: 0x30 }; // Apple's system red.
const BADGE_RING_COLOR = "#ffffff";

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

function cssColor({ r, g, b }) {
  return `rgb(${r},${g},${b})`;
}

/**
 * The vendored app icon is a `<rect>` tile behind the Paseo mark, sized in the
 * markup at 48px. `resize()` alone would rasterize it at that 48px and then
 * upscale a blurred 48px bitmap to 1024, so the target size goes into the
 * render density instead and sharp rasterizes at full resolution once.
 */
async function renderTile(size) {
  const svg = await readFile(PASEO_APP_ICON_PATH);
  const DECLARED_SIZE = 48;
  return sharp(svg, { density: (72 * size) / DECLARED_SIZE })
    .resize(size, size, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer();
}

function badgeMarkup(size) {
  const radius = size * BADGE_RADIUS_FRACTION;
  const ring = size * BADGE_RING_FRACTION;
  // The stroke straddles the path, so half of it sits outside `radius`. Anchor
  // on that outer edge or the ring is what gets clipped by the canvas.
  const centre = size - size * BADGE_MARGIN_FRACTION - (radius + ring / 2);
  return Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}">` +
      `<circle cx="${centre}" cy="${centre}" r="${radius}"` +
      ` fill="${cssColor(BADGE_FILL)}" stroke="${BADGE_RING_COLOR}" stroke-width="${ring}"/>` +
      `</svg>`,
  );
}

/**
 * `assertNotBlank` would pass on the tile alone, so a composite that silently
 * dropped the overlay -- a mistyped offset, an SVG sharp declined to parse --
 * would ship an icon indistinguishable from Paseo's own. Read the pixel back.
 */
async function assertBadgePainted(buffer, size) {
  const radius = size * BADGE_RADIUS_FRACTION;
  const ring = size * BADGE_RING_FRACTION;
  const centre = Math.round(size - size * BADGE_MARGIN_FRACTION - (radius + ring / 2));
  const { data } = await sharp(buffer)
    .extract({ left: centre, top: centre, width: 1, height: 1 })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const [r, g, b] = data;
  const TOLERANCE = 8;
  const matches =
    Math.abs(r - BADGE_FILL.r) <= TOLERANCE &&
    Math.abs(g - BADGE_FILL.g) <= TOLERANCE &&
    Math.abs(b - BADGE_FILL.b) <= TOLERANCE;
  if (!matches) {
    throw new Error(
      `Badge centre is rgb(${r},${g},${b}), expected ${cssColor(BADGE_FILL)} -- the overlay did not land`,
    );
  }
}

async function writeAppIcon() {
  const size = APP_ICON_SIZE;
  const tile = Math.round(size * APP_TILE_FRACTION);
  // Centre the tile; the badge then reaches into the transparent margin.
  const inset = Math.round((size - tile) / 2);
  const buffer = await sharp({
    create: { width: size, height: size, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  })
    .composite([
      { input: await renderTile(tile), left: inset, top: inset },
      { input: badgeMarkup(size), left: 0, top: 0 },
    ])
    .png()
    .toBuffer();
  const outFile = path.join(OUT, "icon.png");
  await assertNotBlank(buffer, outFile);
  await assertBadgePainted(buffer, size);
  await writeFile(outFile, buffer);
  console.log(`wrote ${outFile}`);
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

await writeAppIcon();
