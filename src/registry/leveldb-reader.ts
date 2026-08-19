import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { findInTable, UnsupportedCompressionError, type InternalRecord } from "./sstable.js";
import { findInLog } from "./wal.js";

interface ScanResult {
  winner: InternalRecord | null;
  relevantCount: number;
  parseSkipCount: number;
  vanishedCount: number;
  firstParseError: unknown;
}

/**
 * The value the newest surviving record carried, and whether anything in the
 * directory was unreadable while we worked it out.
 *
 * The two travel together on purpose. A damaged file and a usable value are
 * not alternatives: the damaged file may have held the *newest* write, in
 * which case the value returned here is a superseded one. Collapsing that
 * into a bare value is what let a torn `.log` hand back the previous host
 * list as authoritative, so the caller gets both and decides.
 */
export interface LevelDbReadResult {
  /** `null` when the key is absent — never `null` alongside a `parseFailure`. */
  value: Uint8Array | null;
  /** Detail for the error row when part of the database was unreadable. */
  parseFailure: string | null;
}

/**
 * One pass over the directory: list it, and best-effort read every `.ldb`/
 * `.sst`/`.log` in that listing.
 *
 * Two kinds of failure are tracked separately because they mean different
 * things. A file that disappears between `readdir` and `readFile` almost
 * always means Chromium's compaction wrote its replacement and then unlinked
 * this one — the data migrated, it did not vanish, so `vanishedCount` alone
 * is not evidence anything is wrong. A file that is still there but fails to
 * parse means the bytes are unintelligible, which is exactly the condition
 * the design doc's failure table wants surfaced — so only that case sets
 * `firstParseError`.
 *
 * A `.log` that parses but had to discard fragments counts as a parse
 * failure too. Its surviving records are still used — they may be the newest
 * anywhere — but the file is damaged, and the caller has to be able to say so
 * even when some other file produced a winner.
 */
async function scan(dir: string, userKey: Uint8Array): Promise<ScanResult> {
  const names = await readdir(dir);

  let winner: InternalRecord | null = null;
  let relevantCount = 0;
  let parseSkipCount = 0;
  let vanishedCount = 0;
  let firstParseError: unknown;

  for (const name of names) {
    // `.sst` is LevelDB's pre-2013 name for the same table format and is
    // still read by every version since. A Chromium profile is unlikely to
    // hold one, but "scan every file, newest sequence wins" is this module's
    // whole correctness argument, and a skipped file breaks it silently.
    const isTable = name.endsWith(".ldb") || name.endsWith(".sst");
    const isLog = name.endsWith(".log");
    if (!isTable && !isLog) continue;
    relevantCount += 1;

    let bytes: Buffer;
    try {
      bytes = await readFile(path.join(dir, name));
    } catch {
      // Compacted away between listing and reading. Nothing to recover, and
      // not a sign the file's contents were ever bad.
      vanishedCount += 1;
      continue;
    }

    let records: InternalRecord[];
    try {
      if (isTable) {
        records = findInTable(bytes, userKey);
      } else {
        const log = findInLog(bytes, userKey);
        records = log.records;
        if (log.droppedFragments > 0) {
          parseSkipCount += 1;
          firstParseError ??= new Error(
            `Discarded ${log.droppedFragments} corrupt record fragment(s) in ${name}`,
          );
        }
      }
    } catch (error) {
      // A corrupt or half-written file must not hide a good record in a
      // sibling file, but an unsupported compression type means the format
      // moved under us and every file is suspect -- that one propagates.
      if (error instanceof UnsupportedCompressionError) {
        throw error;
      }
      parseSkipCount += 1;
      firstParseError ??= error;
      continue;
    }

    for (const record of records) {
      if (!winner || record.sequence > winner.sequence) winner = record;
    }
  }

  return { winner, relevantCount, parseSkipCount, vanishedCount, firstParseError };
}

/**
 * Reads the newest live value for one key out of a Chromium LevelDB, without
 * taking the database lock.
 *
 * Reading a LevelDB properly means CURRENT -> MANIFEST -> version set -> live
 * files per level. We need exactly one key, and every record carries a
 * sequence number that totally orders it against every other write, so
 * scanning all files and taking the highest sequence is correct by
 * construction and skips the version set entirely.
 *
 * "No value" is ambiguous by itself: it means either the key was never
 * written (or was deleted), or a file that could have held it failed to
 * parse. The design doc's failure table gives those two states different
 * behaviour downstream (zero hosts + pairing prompt vs. keep-last-known-good
 * + error detail), so this function must not collapse them into the same
 * `null`. Ending with no value and at least one file that failed to *parse*
 * is reported as a real failure rather than absence, by throwing.
 *
 * A damaged file alongside a value that *was* found is the subtler case, and
 * the one that used to be lost entirely: the winner is returned, because a
 * healthy sibling's record is still the best answer available, but
 * `parseFailure` says the newest write may have been in the bytes we could
 * not read. Discarding the winner would be worse — the tray would drop every
 * host over one torn file — and discarding the signal is what let a stale
 * host list, credentials and all, look authoritative.
 *
 * A file that merely vanished between listing and read is handled
 * differently: if that is the only thing that went wrong (no winner, no
 * parse failures, at least one vanished file), the listing was stale, so the
 * scan is retried exactly once with a fresh `readdir`. A second miss falls
 * through to whatever that second scan found, `null` included — this is a
 * bounded retry, not a poll loop.
 */
export async function readLevelDbValue(
  dir: string,
  userKey: Uint8Array,
): Promise<LevelDbReadResult> {
  let result = await scan(dir, userKey);

  if (!result.winner && result.parseSkipCount === 0 && result.vanishedCount > 0) {
    result = await scan(dir, userKey);
  }

  const value = result.winner && !result.winner.isDeletion ? result.winner.value : null;

  if (result.parseSkipCount > 0) {
    const damage = `Could not read ${result.parseSkipCount} of ${result.relevantCount} LevelDB file(s) in ${dir}`;
    // No value *and* damage: absence is indistinguishable from a file we
    // could not read, including when the newest surviving record is a
    // deletion that an unreadable file may itself have superseded. Throwing
    // routes this to keep-last-known-good instead of "the key is gone".
    if (value === null) {
      throw new Error(`${damage}; the key's value could not be determined`, {
        cause: result.firstParseError,
      });
    }
    return { value, parseFailure: `${damage}; the host list may be out of date` };
  }

  return { value, parseFailure: null };
}
