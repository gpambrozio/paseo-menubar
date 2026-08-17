# assets/

`paseo-logo.svg` is vendored from `getpaseo/paseo`,
`packages/website/public/logo.svg`, at the commit current when it was copied
in. It is AGPL-3.0-or-later, like the rest of that repo. It is copied rather
than referenced because this repo has no dependency on `getpaseo/paseo` and a
contributor's machine has no reason to have that repo checked out.

The file is a single `<path fill="white">` with no gradients, `<defs>`, or
background — a clean silhouette, safe to rasterize as a template image. Don't
substitute `favicon.svg` or `favicon-dark.svg` from the same source: both wrap
this path in a filled rounded-square tile, which renders as a solid blob at
tray icon sizes.

`scripts/make-icons.mjs` rasterizes it into `generated/doneTemplate.png` for
the `done` bucket — see the design doc for why the app's own mark is the icon
for its resting state.
