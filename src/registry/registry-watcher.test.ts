import { describe, expect, it } from "vitest";
import { createRegistryWatcher } from "./registry-watcher.js";

/** Lets every pending `resolveDir` continuation run. */
function flush(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

interface OpenCall {
  dir: string;
  fire: () => void;
  fail: () => void;
  closed: boolean;
}

function harness(resolveDir: () => Promise<string>) {
  const opens: OpenCall[] = [];
  const watcher = createRegistryWatcher({
    resolveDir,
    open: (dir, { onChange, onError }) => {
      const call: OpenCall = { dir, fire: onChange, fail: onError, closed: false };
      opens.push(call);
      return () => {
        call.closed = true;
      };
    },
  });
  return { watcher, opens };
}

describe("createRegistryWatcher", () => {
  it("attaches to the resolved directory and forwards changes", async () => {
    const { watcher, opens } = harness(async () => "/db");
    let changes = 0;
    watcher.watch(() => changes++);
    await flush();

    expect(opens).toHaveLength(1);
    expect(opens[0]!.dir).toBe("/db");
    opens[0]!.fire();
    expect(changes).toBe(1);
  });

  it("attaches on a later read when Paseo was not installed at launch", async () => {
    let installed = false;
    const { watcher, opens } = harness(async () => {
      if (!installed) throw new Error("Paseo desktop app not found");
      return "/db";
    });

    watcher.watch(() => undefined);
    await flush();
    expect(opens).toEqual([]);

    // Installing Paseo mid-session used to leave the app on the 60-second
    // poll for the life of the process: the watch was established once, and
    // never again.
    installed = true;
    watcher.ensureAttached();
    await flush();
    expect(opens).toHaveLength(1);
  });

  it("never rejects when the directory cannot be resolved", async () => {
    const { watcher } = harness(async () => {
      throw new Error("nope");
    });
    // An unhandled rejection is fatal in the main process, so the absence of
    // a throw here is the whole assertion.
    expect(() => watcher.watch(() => undefined)).not.toThrow();
    await flush();
  });

  it("does not open a second watch while one is already attached", async () => {
    const { watcher, opens } = harness(async () => "/db");
    watcher.watch(() => undefined);
    await flush();
    watcher.ensureAttached();
    watcher.ensureAttached();
    await flush();

    expect(opens).toHaveLength(1);
  });

  it("does not probe the directory again while a probe is in flight", async () => {
    let release: (dir: string) => void = () => {};
    const pending = new Promise<string>((resolve) => {
      release = resolve;
    });
    let probes = 0;
    const { watcher, opens } = harness(() => {
      probes++;
      return pending;
    });

    watcher.watch(() => undefined);
    watcher.ensureAttached();
    watcher.ensureAttached();

    // `ensureAttached` runs after every read, so without this guard a slow or
    // hung probe would stack one more on each poll. Nothing downstream
    // notices -- the attach check inside the continuation stops a second
    // watch either way -- so the probe count is what pins it.
    expect(probes).toBe(1);

    release("/db");
    await flush();
    expect(opens).toHaveLength(1);
  });

  it("re-attaches after the watch reports an error", async () => {
    const { watcher, opens } = harness(async () => "/db");
    watcher.watch(() => undefined);
    await flush();

    // macOS drops watches when the watched directory is replaced, which a
    // compaction does. Without a fresh attach the tray is on the poll alone
    // from then on.
    opens[0]!.fail();
    watcher.ensureAttached();
    await flush();

    expect(opens).toHaveLength(2);
  });

  it("stops watching and stops forwarding once detached", async () => {
    const { watcher, opens } = harness(async () => "/db");
    let changes = 0;
    const stop = watcher.watch(() => changes++);
    await flush();

    stop();
    expect(opens[0]!.closed).toBe(true);
    opens[0]!.fire();
    expect(changes).toBe(0);

    // And a read arriving after shutdown must not resurrect it.
    watcher.ensureAttached();
    await flush();
    expect(opens).toHaveLength(1);
  });

  it("does not attach a directory that resolves after the watcher was detached", async () => {
    let release: (dir: string) => void = () => {};
    const { watcher, opens } = harness(
      () =>
        new Promise<string>((resolve) => {
          release = resolve;
        }),
    );

    const stop = watcher.watch(() => undefined);
    stop();
    release("/db");
    await flush();

    expect(opens).toEqual([]);
  });
});
