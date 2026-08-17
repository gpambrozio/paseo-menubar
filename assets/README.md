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

`paseo-app-icon.svg` is vendored from the same repo,
`packages/website/public/favicon.svg`, and is the tile-and-mark form the caveat
above warns off for tray use: a black rounded square behind the mark. That is
exactly right for an app icon and wrong for a template image, so the two files
stay separate rather than one being derived from the other.

`scripts/make-icons.mjs` renders it into `generated/icon.png` at 1024px with a
red notification badge over the bottom-right corner, and `electron-builder.yml`
points `mac.icon` at that file. The badge is the only thing distinguishing this
icon from Paseo's own app icon, which is the intent — same family, and the dot
says "indicator". `generated/icon.png` is build input, not a runtime asset, so
`electron-builder.yml` excludes it from the packaged app.
