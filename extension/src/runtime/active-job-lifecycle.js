/** A tiny FIFO executor for storage-backed read/modify/write sections. */
export function createSerializedExecutor() {
  let tail = Promise.resolve();
  return operation => {
    const run = tail.catch(() => {}).then(operation);
    tail = run.then(() => undefined, () => undefined);
    return run;
  };
}

/**
 * Commit terminal inbox truth before removing its reconciliation pointer.
 * Callers serialize this operation with job replacement mutations.
 */
export async function commitTerminalGeneration({
  isCurrent,
  markTerminal,
  removePointer,
  persistPointers,
  restorePointer,
  pointerExists
}) {
  if (!isCurrent()) return { committed: false, reason: 'stale-generation' };

  let stored;
  try {
    stored = await markTerminal();
  } catch (error) {
    return { committed: false, reason: 'terminal-write-failed', error };
  }
  if (!isCurrent()) return { committed: false, reason: 'stale-generation' };
  if (!stored) return { committed: false, reason: 'capture-record-missing' };

  removePointer();
  try {
    await persistPointers();
  } catch (error) {
    if (!pointerExists()) restorePointer();
    return { committed: false, reason: 'pointer-write-failed', error };
  }
  if (pointerExists()) return { committed: false, reason: 'replacement-generation' };
  return { committed: true, reason: 'committed' };
}
