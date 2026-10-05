import { extractPageContext } from './extract-page.js';
import { CaptureMetadataEditor, createMetadataEditorView, metadataStatusText } from './capture-metadata-editor.js';
import { attachMarks } from './ui/marks.js';
import { findCaptureHint } from './ui/capture-target-hint.js';
import { captureSkin, xTheme, X_CARD_CSS } from './ui/card-skins.js';

// Site scripts draw only hover marks and the capture plan; the page agent alone
// draws saving, kept, already and failed marks.
export function installPageAgent({ document, browserAPI, window = globalThis, marks = attachMarks }) {
  let root = null;
  let shadow = null;
  let current = null;
  let closeTimer = null;
  let noteTimer = null;
  let metadataEditor = null;
  let metadataView = null;
  let editorOpen = false;
  let frame = null;
  let frameTarget = null;
  let contextTarget = null;
  let selectionRange = null;
  let dismissed = false;
  const skin = captureSkin(document.location?.hostname || window.location?.hostname);

  function node(tag, className, text) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  }

  function button(text, action, className = '') {
    const element = node('button', className, text);
    element.addEventListener('click', action);
    return element;
  }

  function editable() {
    return ['completed', 'saved', 'duplicate'].includes(current?.state);
  }

  function removePresentation() {
    frame?.destroy();
    frame = null;
    frameTarget = null;
    root?.remove();
    root = null;
    shadow = null;
  }

  function scheduleClose(delay = 6000) {
    clearTimeout(closeTimer);
    if (metadataEditor?.unsettled) return;
    closeTimer = setTimeout(() => {
      dismissed = true;
      removePresentation();
    }, delay);
  }

  function updateMetadataStatus(editor) {
    if (editor !== metadataEditor || !metadataView || dismissed) return;
    const status = metadataView.querySelector('[data-metadata-status]');
    const retry = metadataView.querySelector('[data-metadata-retry]');
    status.textContent = metadataStatusText(editor.state);
    status.classList.toggle('error', editor.state.phase === 'failed');
    retry.hidden = !editor.unsettled || editor.state.phase === 'saving';
    if (editor.unsettled) {
      clearTimeout(closeTimer);
      editorOpen = true;
      metadataView.hidden = false;
    } else if (editable()) scheduleClose();
  }

  function closeCard() {
    clearTimeout(closeTimer);
    clearTimeout(noteTimer);
    if (metadataEditor?.unsettled) void metadataEditor.flush();
    dismissed = true;
    removePresentation();
  }

  function syncFields() {
    if (!metadataView || !metadataEditor) return;
    const tags = metadataView.querySelector('[data-tags]');
    const note = metadataView.querySelector('[data-note]');
    if (!metadataEditor.touched.has('tags')) tags.value = metadataEditor.draft.tags.join(', ');
    if (!metadataEditor.touched.has('note')) note.value = metadataEditor.draft.note;
  }

  const viewport = { getBoundingClientRect: () => ({
    left: 9, top: 9, width: Math.max(0, window.innerWidth - 18), height: Math.max(0, window.innerHeight - 18)
  }) };

  function target() {
    if (current.element?.isConnected) return current.element;
    const intent = current.intent;
    // Site buttons leave the post or media they saved; a page capture matches only its own target.
    const hinted = findCaptureHint(current.kind === 'media'
      ? [intent?.media?.url, intent?.targetUrl, intent?.sourcePageUrl]
      : [intent?.targetUrl], { take: true });
    if (hinted) {
      current.element = hinted.element;
      current.avoid = hinted.avoid;
      return hinted.element;
    }
    if (current.kind === 'media') {
      const url = current.intent?.media?.url || current.targetUrl;
      if (url) {
        const media = [...document.querySelectorAll('img, video, audio')].find(element =>
          [element.currentSrc, element.src, element.poster].includes(url));
        if (media) return media;
      }
      if (contextTarget?.isConnected && /^(IMG|VIDEO|AUDIO)$/.test(contextTarget.tagName)) return contextTarget;
    }
    if (current.kind === 'selection' && selectionRange) return selectionRange;
    return viewport;
  }

  function showEditor() {
    editorOpen = true;
    clearTimeout(closeTimer);
    metadataView.hidden = false;
    metadataView.querySelector('[data-tags]')?.focus();
  }

  async function saveAgain() {
    const intent = current.intent;
    if (!intent) return;
    const session = metadataEditor;
    const sourceId = current.captureId;
    const { captureId, fingerprint, createdAt, ...input } = intent;
    const options = { ...input.options, captureAgain: true };
    try {
      if (options.saveMode !== 'quick') {
        const response = await browserAPI.runtime.sendMessage({ action: 'captureScreenshot' });
        if (metadataEditor !== session || dismissed) return;
        if (!response?.screenshot) throw new Error('Could not capture screenshot. Retry when the page is ready.');
        options.screenshot = response.screenshot;
      }
      const response = await browserAPI.runtime.sendMessage({ action: 'capture.submit', intent: { ...input, options } });
      if (response?.success === false) throw new Error(response.error || 'Could not save a fresh copy.');
    } catch (error) {
      if (metadataEditor === session && current.captureId === sourceId && !dismissed) {
        current = { ...current, state: 'failed', freshCopyFailed: true, error: error?.message || String(error) };
        present();
      }
    }
  }

  function present() {
    if (dismissed) return;
    const state = current.state;
    // The runtime reports a repeat capture as saved with a duplicate disposition.
    const duplicate = state === 'duplicate' || (current.disposition === 'duplicate' && ['saved', 'completed'].includes(state));
    const open = () => browserAPI.runtime.sendMessage({ action: 'capture.open' });
    const retry = () => current.freshCopyFailed ? saveAgain()
      : browserAPI.runtime.sendMessage({ action: 'capture.retry', captureId: current.captureId });
    const canRetry = ['queued', 'failed', 'stalled'].includes(state);
    metadataView.hidden = !editorOpen;
    if (skin === 'marks') {
      const nextTarget = target();
      if (!frame || frameTarget !== nextTarget) {
        frame?.destroy();
        frameTarget = nextTarget;
        frame = marks(nextTarget, { kind: nextTarget === viewport ? 'page' : current.kind === 'page' ? 'post' : current.kind,
          avoid: nextTarget === current.element ? current.avoid : null });
      }
      frame.set(duplicate ? 'already' : editable() ? 'kept' : canRetry ? 'failed' : 'saving', {
        caption: current.caption || current.title,
        progress: current.progress,
        savedAt: current.savedAt,
        error: current.error || (state === 'queued' ? 'Saved to capture inbox. Retry when the server is available.' : ''),
        onOpen: open, onTag: showEditor, onRetry: retry, onSaveAgain: saveAgain,
        onDismiss: closeCard,
        onEnter: () => clearTimeout(closeTimer),
        onLeave: () => editable() && scheduleClose(3000),
        editor: editable() ? metadataView : null
      });
    } else {
      if (!root?.isConnected) {
        root = node('div');
        root.id = 'nodraw-capture-card-host';
        shadow = root.attachShadow({ mode: 'closed' });
        document.documentElement.append(root);
      }
      const focused = shadow.activeElement;
      const selectionStart = focused?.selectionStart;
      const selectionEnd = focused?.selectionEnd;
      const style = node('style', '', X_CARD_CSS);
      const card = node('section', `card ${xTheme(document, window.getComputedStyle?.bind(window))}`);
      card.setAttribute('role', 'status');
      card.setAttribute('aria-live', 'polite');
      const labels = { saving: 'Saving…', accepted: 'Downloading…', processing: 'Downloading…',
        completed: 'Saved to NoDraw', saved: 'Saved to NoDraw', duplicate: 'Already in NoDraw',
        queued: 'Saved to capture inbox', failed: 'Needs attention', stalled: 'Needs attention' };
      const head = node('div', 'head');
      const close = button('×', closeCard, 'close');
      close.setAttribute('aria-label', 'Close');
      head.append(node('div', 'status', labels[duplicate ? 'duplicate' : state] || state), close);
      card.append(head, node('div', 'title', current.title || ''));
      if (current.error) card.append(node('div', 'error', current.error));
      if (editable()) {
        const tags = node('div', 'tags');
        for (const tag of metadataEditor.draft.tags) tags.append(node('span', 'tag', tag));
        tags.append(button('Add tag', showEditor, 'add-tag'));
        card.append(tags, metadataView);
      }
      const actions = node('div', 'actions');
      if (canRetry) actions.append(button('Retry', retry));
      if (editable()) actions.append(button('Open in NoDraw', open, 'primary'));
      if (duplicate) actions.append(button('Save a fresh copy', saveAgain));
      actions.append(button('Done', closeCard));
      card.append(actions);
      card.onmouseenter = () => clearTimeout(closeTimer);
      card.onmouseleave = () => editable() && scheduleClose(3000);
      shadow.replaceChildren(style, card);
      if (focused && metadataView.contains?.(focused)) {
        focused.focus();
        if (selectionStart !== undefined) focused.setSelectionRange?.(selectionStart, selectionEnd);
      }
    }
    if (editable()) scheduleClose();
    else clearTimeout(closeTimer);
    updateMetadataStatus(metadataEditor);
  }

  function render(update) {
    if (update.captureId && update.captureId !== current?.captureId) {
      clearTimeout(closeTimer);
      clearTimeout(noteTimer);
      if (metadataEditor?.unsettled) void metadataEditor.flush();
      removePresentation();
      metadataEditor = null;
      metadataView = null;
      editorOpen = false;
      dismissed = false;
      current = null;
    }
    if (update.state !== current?.state && ['failed', 'stalled', 'queued'].includes(update.state)) dismissed = false;
    // Job polls don't repeat the receipt's disposition; keep it so a duplicate stays a duplicate.
    current = { ...current, ...update, disposition: update.disposition ?? current?.disposition,
      savedAt: update.savedAt ?? current?.savedAt };
    if (!metadataEditor) {
      const editor = new CaptureMetadataEditor({
        captureId: current.captureId,
        user: { tags: current.tags || [], note: current.note || '' },
        persist: async (captureId, fields) => {
          const response = await browserAPI.runtime.sendMessage({ action: 'capture.metadata.stage', captureId, fields });
          if (!response?.success) throw new Error(response?.error || 'Could not preserve metadata draft');
        },
        send: (captureId, patch) => browserAPI.runtime.sendMessage({ action: 'capture.patch', captureId, ...patch }),
        onState: () => updateMetadataStatus(editor)
      });
      metadataEditor = editor;
      metadataView = createMetadataEditorView(document, { editor, skin,
        onInput: () => clearTimeout(closeTimer),
        onNote: session => {
          clearTimeout(noteTimer);
          noteTimer = setTimeout(() => void session.flush(), 1000);
        }
      });
      if (current.captureId) void browserAPI.runtime.sendMessage({ action: 'capture.get', captureId: current.captureId }).then(response => {
        if (metadataEditor !== editor) return;
        current.intent = response?.capture?.intent;
        current.savedAt ||= response?.capture?.receipt?.savedAt || current.intent?.createdAt;
        if (current.kind === 'selection' && !selectionRange) {
          const selection = window.getSelection?.();
          selectionRange = selection?.rangeCount && !selection.isCollapsed ? selection.getRangeAt(0).cloneRange() : null;
        }
        editor.restore(response?.capture);
        syncFields();
        present();
      }).catch(error => editor.setState('failed', error?.message || String(error)));
    }
    metadataEditor.updateSource({ tags: current.tags, note: current.note });
    syncFields();
    present();
  }

  function onMessage(message, _sender, sendResponse) {
    if (message.action === 'captureMetadata.update' && message.captureId === current?.captureId) {
      metadataEditor?.restore({ metadata: message.metadata, intent: { user: { tags: message.tags, note: message.note } } });
      syncFields();
      present();
      return false;
    }
    if (message.action === 'capture.extract') {
      const selection = window.getSelection?.();
      selectionRange = selection?.rangeCount && !selection.isCollapsed ? selection.getRangeAt(0).cloneRange() : null;
      sendResponse(extractPageContext(document, selection));
      return false;
    }
    if (message.action === 'captureCard.update') render(message);
    if (message.action === 'archiveJobStatus' && current && (!message.captureId || message.captureId === current.captureId)) {
      render({ ...message, state: message.status, error: message.error || message.message });
    }
    return false;
  }

  const onKey = event => { if (event.key === 'Escape' && (frame || root?.isConnected)) closeCard(); };
  const onContext = event => {
    contextTarget = event.target;
    const selection = window.getSelection?.();
    selectionRange = selection?.rangeCount && !selection.isCollapsed ? selection.getRangeAt(0).cloneRange() : null;
  };
  browserAPI.runtime.onMessage.addListener(onMessage);
  document.addEventListener('keydown', onKey);
  document.addEventListener('contextmenu', onContext, true);
  return { destroy() {
    closeCard();
    browserAPI.runtime.onMessage.removeListener?.(onMessage);
    document.removeEventListener('keydown', onKey);
    document.removeEventListener('contextmenu', onContext, true);
  } };
}

const browserAPI = globalThis.browser || globalThis.chrome;
if (browserAPI?.runtime && globalThis.document && !globalThis.__nodrawCaptureAgent) {
  globalThis.__nodrawCaptureAgent = true;
  installPageAgent({ document: globalThis.document, browserAPI });
}
