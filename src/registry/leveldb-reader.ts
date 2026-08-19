import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { findInTable, UnsupportedCompressionError, type InternalRecord } from "./sstable.js";
import { findInLog } from "./wal.js";

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
 * Files are read best-effort. A compaction can delete a file between the
 * directory listing and the read, and a file being written can be torn; both
 * are normal here, so an unreadable file is skipped rather than failing the
 * whole read. A directory that cannot be listed at all is a real error and
 * does throw — that is the difference between "Paseo is busy" and "Paseo is
 * not installed".
 *
 * "No winner" is ambiguous by itself: it means either the key was never
 * written, or every file that could have held it failed to parse. The design
 * doc's failure table gives those two states different behaviour downstream
 * (zero hosts + pairing prompt vs. keep-last-known-good + error detail), so
 * this function must not collapse them into the same `null`. A skipped file
 * is remembered, and if no winner is found and at least one file was
 * skipped, that is reported as a real failure rather than absence.
 */
export async function readLevelDbValue(
  dir: string,
  userKey: Uint8Array,
): Promise<Uint8Array | null> {
  const names = await readdir(dir);

  let winner: InternalRecord | null = null;
  let relevantCount = 0;
  let skippedCount = 0;
  let firstSkipError: unknown = undefined;
  for (const name of names) {
    const isTable = name.endsWith(".ldb");
    const isLog = name.endsWith(".log");
    if (!isTable && !isLog) continue;
    relevantCount += 1;

    let bytes: Buffer;
    try {
      bytes = await readFile(path.join(dir, name));
    } catch (error) {
      // Compacted away between listing and reading. Nothing to recover.
      skippedCount += 1;
      firstSkipError ??= error;
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
      skippedCount += 1;
      firstSkipError ??= error;
      continue;
    }

    for (const record of records) {
      if (!winner || record.sequence > winner.sequence) winner = record;
    }
  }

  if (winner) return winner.isDeletion ? null : winner.value;

  if (skippedCount > 0) {
    throw new Error(
      `Failed to read ${skippedCount} of ${relevantCount} LevelDB file(s) in ${dir}; the key's value could not be determined`,
      { cause: firstSkipError },
    );
  }

  return null;
}
