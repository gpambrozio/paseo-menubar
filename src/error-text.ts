/**
 * The message to show for a thrown value.
 *
 * Everything that reports a failure to the user needs this — the tray's
 * configuration-error row, the fleet's per-entry failures, the dialogs — and a
 * `catch` binding is `unknown`, so each of them would otherwise carry its own
 * copy of the same three-line narrowing.
 */
export function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
