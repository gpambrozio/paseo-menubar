import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    // The app is Swift; `swift test --package-path PaseoIconPackage` is its
    // suite. What is left here is the build tooling under scripts/, which is
    // plain .mjs and never compiled into anything. It still gets tested:
    // render-cask.mjs decides what checksum every Homebrew user downloads.
    include: ["scripts/**/*.test.mjs"],
    testTimeout: 30_000,
  },
});
