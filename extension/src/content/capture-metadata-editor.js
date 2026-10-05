/** A card's edit session. Capture status is separate from metadata save status. */
export class CaptureMetadataEditor {
  constructor({ captureId, user = {}, send, persist = null, onState = () => {} }) {
    this.captureId = captureId;
    this.draft = { tags: [...(user.tags || [])], note: user.note || '' };
    this.send = send;
    this.persist = persist;
    this.persisting = Promise.resolve();
    this.persistenceError = null;
    this.onState = onState;
    this.dirty = new Map();
    this.touched = new Set();
    this.revision = 0;
    this.needsProjectionRetry = false;
    this.state = { phase: 'idle', error: null };
    this.inFlight = null;
  }

  edit(field, value) {
    if (field !== 'tags' && field !== 'note') throw new TypeError('Unknown metadata field');
    this.draft[field] = field === 'tags' ? [...value] : value;
    this.touched.add(field);
    this.dirty.set(field, ++this.revision);
    this.setState('pending');
    if (this.persist) {
      const fields = { [field]: this.draft[field] };
      this.persisting = this.persisting.then(async () => {
        try {
          await this.persist(this.captureId, fields);
        } catch (error) {
          this.persistenceError = error;
          this.setState('failed', error?.message || String(error));
        }
      });
    }
  }

  restore(record) {
    if (!record) return;
    const metadata = record.metadata;
    this.updateSource({ ...(record.intent?.user || {}), ...(metadata?.pending?.fields || {}), ...(metadata?.draft || {}) });
    if (!metadata || this.inFlight || this.dirty.size) return;
    const projection = metadata.receipt?.metadataProjection;
    this.needsProjectionRetry = Boolean(metadata.pending || Object.keys(metadata.draft || {}).length
      || projection === 'failed' || projection === 'pending');
    const error = metadata.error || metadata.receipt?.metadataError;
    if (this.needsProjectionRetry) this.setState(error ? 'failed' : 'pending', error || null);
    else if (metadata.receipt) this.setState('saved');
  }

  updateSource(user) {
    if (!this.touched.has('tags') && Array.isArray(user.tags)) this.draft.tags = [...user.tags];
    if (!this.touched.has('note') && typeof user.note === 'string') this.draft.note = user.note;
  }

  get unsettled() {
    return this.dirty.size > 0 || this.needsProjectionRetry || this.state.phase === 'saving';
  }

  setState(phase, error = null) {
    this.state = { phase, error };
    this.onState(this.state);
  }

  flush() {
    if (this.inFlight) return this.inFlight;
    const operation = this.drain();
    this.inFlight = operation;
    void operation.finally(() => {
      if (this.inFlight === operation) this.inFlight = null;
    });
    return operation;
  }

  async drain() {
    while (this.dirty.size || this.needsProjectionRetry) {
      const revisions = new Map(this.dirty);
      const patch = Object.fromEntries([...revisions.keys()].map(field => [field,
        field === 'tags' ? [...this.draft.tags] : this.draft.note
      ]));
      this.setState('saving');
      let response;
      try {
        if (this.persist) {
          await this.persisting;
          if (this.persistenceError) {
            await this.persist(this.captureId, patch);
            this.persistenceError = null;
          }
        }
        response = await this.send(this.captureId, this.persist ? {} : patch);
        if (!response || (response.success === false && !response.metadata_pending)) {
          throw new Error(response?.error || 'Could not save changes. Retry when the server is available.');
        }
      } catch (error) {
        this.setState('failed', error?.message || String(error));
        return this.state;
      }
      // A server-side projection failure still durably accepted the edit. Retry that projection
      // with an empty patch; do not accidentally rebase a conflicting edit by submitting it again.
      for (const [field, revision] of revisions) {
        if (this.dirty.get(field) === revision) this.dirty.delete(field);
      }
      this.needsProjectionRetry = Boolean(response.metadata_pending);
      if (this.needsProjectionRetry) {
        this.setState(response.success === false ? 'failed' : 'pending', response.error || null);
        return this.state;
      }
    }
    this.setState('saved');
    return this.state;
  }
}

const METADATA_STATUS_LABELS = { idle: '', pending: 'Changes pending', saving: 'Saving changes…', saved: 'Changes saved' };

// Idle is intentionally blank; only unknown phases fall back to the failure text.
export function metadataStatusText(state) {
  return state.error || (METADATA_STATUS_LABELS[state.phase] ?? 'Changes could not be saved');
}

/** Both skins use the same edit session and durable field staging. */
export function createMetadataEditorView(document, { editor, skin = 'marks', onInput = () => {}, onNote = () => {} }) {
  const view = document.createElement('div');
  view.className = `metadata-editor ${skin}`;
  const style = document.createElement('style');
  style.textContent = `
    .metadata-editor { display:flex; flex-wrap:wrap; gap:0; max-width:min(420px, calc(100vw - 30px));
      color:#eeeae2; font:600 11px/1.4 "SF Mono",SFMono-Regular,Menlo,monospace; pointer-events:auto; }
    .metadata-editor input,.metadata-editor textarea,.metadata-editor button,.metadata-editor [data-metadata-status] {
      box-sizing:border-box; border:1px solid #3a3833; border-radius:0; background:#11110f;
      color:#eeeae2; padding:6px 8px; font:inherit; margin:0; }
    .metadata-editor input { width:100%; } .metadata-editor textarea { width:100%; min-height:42px; resize:vertical; }
    .metadata-editor[hidden] { display:none; }
    .metadata-editor button { cursor:pointer; } .metadata-editor [data-metadata-status]:empty { display:none; }
    .metadata-editor .error { color:#e5484d; } .metadata-editor [hidden] { display:none; }
    .metadata-editor.x { max-width:100%; gap:6px; font:inherit; color:inherit; }
    .metadata-editor.x input,.metadata-editor.x textarea,.metadata-editor.x button,.metadata-editor.x [data-metadata-status] {
      background:var(--bg); color:var(--fg); border-color:var(--line); border-radius:12px; }
    .metadata-editor.x [data-metadata-status].error { color:#f4212e; }
  `;
  view.append(style);
  const tags = document.createElement('input');
  tags.setAttribute('data-tags', '');
  tags.setAttribute('aria-label', 'Tags');
  tags.placeholder = 'tags, comma separated';
  tags.value = editor.draft.tags.join(', ');
  tags.addEventListener('input', () => {
    onInput();
    editor.edit('tags', tags.value.split(',').map(tag => tag.trim()).filter(Boolean));
  });
  tags.addEventListener('change', () => void editor.flush());
  const note = document.createElement('textarea');
  note.setAttribute('data-note', '');
  note.setAttribute('aria-label', 'Note');
  note.placeholder = 'Add a note';
  note.value = editor.draft.note;
  note.addEventListener('input', () => {
    onInput();
    editor.edit('note', note.value);
    onNote(editor);
  });
  const status = document.createElement('span');
  status.setAttribute('data-metadata-status', '');
  status.setAttribute('aria-live', 'polite');
  const retry = document.createElement('button');
  retry.setAttribute('data-metadata-retry', '');
  retry.textContent = 'Retry changes';
  retry.hidden = true;
  retry.addEventListener('click', () => void editor.flush());
  view.append(tags, note, status, retry);
  return view;
}
