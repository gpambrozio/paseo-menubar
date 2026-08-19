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
 * One pass over the directory: list it, and best-effort read every `.ldb`/
 * `.log` in that listing.
 *
 * Two kinds of failure are tracked separately because they mean different
 * things. A file that disappears between `readdir` and `readFile` almost
 * always means Chromium's compaction wrote its replacement and then unlinked
 * this one — the data migrated, it did not vanish, so `vanishedCount` alone
 * is not evidence anything is wrong. A file that is still there but fails to
 * parse means the bytes are unintelligible, which is exactly the condition
 * the design doc's failure table wants surfaced — so only that case sets
 * `firstParseError`.
 */
async function scan(dir: string, userKey: Uint8Array): Promise<ScanResult> {
  const names = await readdir(dir);

  let winner: InternalRecord | null = null;
  let relevantCount = 0;
  let parseSkipCount = 0;
  let vanishedCount = 0;
  let firstParseError: unknown;

  for (const name of names) {
    const isTable = name.endsWith(".ldb");
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
      records = isTable ? findInTable(bytes, userKey) : findInLog(bytes, userKey);
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
 * "No winner" is ambiguous by itself: it means either the key was never
 * written, or a file that could have held it failed to parse. The design
 * doc's failure table gives those two states different behaviour downstream
 * (zero hosts + pairing prompt vs. keep-last-known-good + error detail), so
 * this function must not collapse them into the same `null`. If the scan
 * ends with no winner and at least one file that failed to *parse*, that is
 * reported as a real failure rather than absence.
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
): Promise<Uint8Array | null> {
  let result = await scan(dir, userKey);

  if (!result.winner && result.parseSkipCount === 0 && result.vanishedCount > 0) {
    result = await scan(dir, userKey);
  }

  if (result.winner) return result.winner.isDeletion ? null : result.winner.value;

  if (result.parseSkipCount > 0) {
    throw new Error(
      `Failed to read ${result.parseSkipCount} of ${result.relevantCount} LevelDB file(s) in ${dir}; the key's value could not be determined`,
      { cause: result.firstParseError },
    );
  }

  return null;
}
