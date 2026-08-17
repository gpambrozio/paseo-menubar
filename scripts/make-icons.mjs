import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";

const OUT = path.join(process.cwd(), "assets", "generated");

const SHAPES = {
  // Hollow circle: nothing needs you.
  idle: '<circle cx="8" cy="8" r="5.5" fill="none" stroke="black" stroke-width="1.5"/>',
  // Half-filled circle: work in progress.
  working:
    '<circle cx="8" cy="8" r="5.5" fill="none" stroke="black" stroke-width="1.5"/>' +
    '<path d="M8 2.5 A5.5 5.5 0 0 1 8 13.5 Z" fill="black"/>',
  // Filled circle: something is waiting on you.
  attention: '<circle cx="8" cy="8" r="5.5" fill="black"/>',
};

await mkdir(OUT, { recursive: true });

for (const [name, shape] of Object.entries(SHAPES)) {
  for (const scale of [1, 2]) {
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">${shape}</svg>`;
    const suffix = scale === 1 ? "" : `@${scale}x`;
    const file = path.join(OUT, `${name}Template${suffix}.png`);
    await sharp(Buffer.from(svg))
      .resize(16 * scale, 16 * scale)
      .png()
      .toBuffer()
      .then((data) => writeFile(file, data));
    console.log(`wrote ${file}`);
  }
}
