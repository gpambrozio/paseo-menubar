import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    // scripts/ holds build tooling that never ships inside the asar, so it is
    // plain .mjs rather than TypeScript compiled into dist/. It still gets
    // tested: render-cask.mjs decides what checksum every Homebrew user
    // downloads.
    include: ["src/**/*.test.ts", "scripts/**/*.test.mjs"],
    testTimeout: 30_000,
  },
});
