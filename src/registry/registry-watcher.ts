/**
 * Keeps a filesystem watch on the Paseo app's leveldb directory attached,
 * across the directory not existing yet and across the watch failing later.
 *
 * The directory belongs to another program that may be installed after this
 * one starts, uninstalled while it runs, or reinstalled. A watch established
 * once at launch is therefore not enough: a machine where Paseo arrives after
 * the tray does would sit on the 60-second poll for the life of the process.
 * `ensureAttached` is the seam for that — the session calls it after every
 * read, so the first read that works is also what attaches the watch.
 *
 * Nothing here rejects or throws. An `FSWatcher` `'error'` with no listener
 * takes the process down, and so does a floating rejected promise, so both
 * are contained: `open`'s implementation reports an error rather than raising
 * one, and every path off `resolveDir` is caught.
 *
 * `fs.watch` itself is injected, which keeps this module free of both Electron
 * and the filesystem and lets the reattachment logic be tested directly.
 */
export interface RegistryWatcher {
  /** Matches `createRegistrySession`'s `watch`. Returns the detach function. */
  watch(onChange: () => void): () => void;
  /** Attaches if nothing is attached. Safe to call on every read. */
  ensureAttached(): void;
}

export interface RegistryWatcherOptions {
  /** Resolves the directory to watch; rejects when Paseo is not installed. */
  resolveDir: () => Promise<string>;
  /**
   * Starts one watch and returns its detach function. It must not throw:
   * a directory that vanishes between resolution and this call is expected,
   * and is reported through `onError` like any other failure.
   */
  open: (dir: string, handlers: { onChange: () => void; onError: () => void }) => () => void;
}

export function createRegistryWatcher(options: RegistryWatcherOptions): RegistryWatcher {
  const { resolveDir, open } = options;

  let notify: (() => void) | null = null;
  let detach: (() => void) | null = null;
  let resolving = false;

  function ensureAttached(): void {
    // Not started, already attached, or a resolution is already in flight.
    // The last guard is what stops a burst of reads from opening a watch per
    // read while the first `resolveDir` is still pending.
    if (notify === null || detach !== null || resolving) return;

    resolving = true;
    void resolveDir()
      .then((dir) => {
        resolving = false;
        if (notify === null || detach !== null) return;
        detach = open(dir, {
          onChange: () => notify?.(),
          // The watch died. Forget it so the next `ensureAttached` opens a
          // fresh one; `open` owns closing the failed handle.
          onError: () => {
            detach = null;
          },
        });
      })
      .catch(() => {
        // Paseo is not installed. The session's poll calls back here.
        resolving = false;
      });
  }

  return {
    watch(onChange) {
      notify = onChange;
      ensureAttached();
      return () => {
        notify = null;
        const current = detach;
        detach = null;
        current?.();
      };
    },
    ensureAttached,
  };
}
