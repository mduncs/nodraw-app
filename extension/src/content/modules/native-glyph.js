// Site-native glyphs sit in a site's own action row, always visible, dressed as that site's
// buttons. Only the icon carries capture state: orange while saving or kept, red when not saved.
const ORANGE = '#d87d0b';
const RED = '#e5484d';

export function renderNativeGlyph(button, state, { mode = 'full', error } = {}, { getIcon, modes, size = 20 }) {
  const active = state === 'idle' || state === 'hover';
  const icon = active ? modes[mode]?.icon || 'download'
    : state === 'saving' ? 'loading'
    : state === 'failed' ? 'error' : 'success';
  button.innerHTML = getIcon(icon, size);
  // Page CSS that spins the loader does not reach into a shadow root (Reddit's action row).
  if (icon === 'loading') {
    button.querySelector('svg')?.animate?.(
      [{ transform: 'rotate(0deg)' }, { transform: 'rotate(360deg)' }],
      { duration: 1000, iterations: Infinity });
  }
  button.style.color = active ? '' : state === 'failed' ? RED : ORANGE;
  const hint = ['full', 'quick', 'text']
    .map(key => `${{ full: 'click', quick: '⇧', text: '⌥' }[key]} ${modes[key]?.label || key}`)
    .join(' · ');
  button.title = active ? `Save to NoDraw — ${hint}`
    : state === 'saving' ? 'Saving to NoDraw'
    : state === 'failed' ? `Not saved: ${error || 'archive failed'}` : 'Kept in NoDraw';
  button.setAttribute('aria-label', button.title);
}
