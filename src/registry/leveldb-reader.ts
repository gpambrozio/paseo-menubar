import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { findInTable, type InternalRecord } from "./sstable.js";
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
 */
export async function readLevelDbValue(
  dir: string,
  userKey: Uint8Array,
): Promise<Uint8Array | null> {
  const names = await readdir(dir);

  let winner: InternalRecord | null = null;
  for (const name of names) {
    const isTable = name.endsWith(".ldb");
    const isLog = name.endsWith(".log");
    if (!isTable && !isLog) continue;

    let bytes: Buffer;
    try {
      bytes = await readFile(path.join(dir, name));
    } catch {
      // Compacted away between listing and reading. Nothing to recover.
      continue;
    }

    let records: InternalRecord[];
    try {
      records = isTable ? findInTable(bytes, userKey) : findInLog(bytes, userKey);
    } catch (error) {
      // A corrupt or half-written file must not hide a good record in a
      // sibling file, but an unsupported compression type means the format
      // moved under us and every file is suspect -- that one propagates.
      if (error instanceof Error && error.message.includes("Unsupported LevelDB compression")) {
        throw error;
      }
      continue;
    }

    for (const record of records) {
      if (!winner || record.sequence > winner.sequence) winner = record;
    }
  }

  if (!winner || winner.isDeletion) return null;
  return winner.value;
}
