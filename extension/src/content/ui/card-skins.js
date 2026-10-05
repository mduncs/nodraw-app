export function captureSkin(hostname = '') {
  return /(^|\.)(x\.com|twitter\.com)$/i.test(hostname) ? 'x' : 'marks';
}

export function xTheme(document, getStyle = globalThis.getComputedStyle) {
  for (const element of [document.body, document.documentElement]) {
    const color = getStyle?.(element)?.backgroundColor || '';
    const values = color.match(/[\d.]+/g)?.map(Number);
    if (!values || values.length < 3 || values[3] === 0) continue;
    if (values.slice(0, 3).every(value => value > 180)) return 'light';
    return values[2] > values[0] + 5 ? 'dim' : 'dark';
  }
  return 'light';
}

export const X_CARD_CSS = `
  :host { all:initial; }
  .card { position:fixed; z-index:2147483647; top:18px; right:18px; width:360px;
    box-sizing:border-box; padding:20px; border:1px solid var(--line); border-radius:18px;
    background:var(--bg); color:var(--fg); box-shadow:0 0 14px #8884;
    font:15px/1.4 TwitterChirp,-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    --bg:#000; --fg:#e7e9ea; --muted:#71767b; --line:#536471; }
  .card.dim { --bg:#15202b; --fg:#f7f9f9; --muted:#8b98a5; --line:#536471; }
  .card.light { --bg:#fff; --fg:#0f1419; --muted:#536471; --line:#cfd9de; }
  .head { display:flex; align-items:center; gap:12px; }
  .status { flex:1; font-size:20px; font-weight:700; }
  .title { margin:18px 0; overflow-wrap:anywhere; }
  button { color:inherit; background:transparent; border:1px solid var(--line); border-radius:999px;
    padding:8px 14px; font-family:inherit; font-size:14px; line-height:1.2; font-weight:700; cursor:pointer; }
  .close { border:0; padding:0 3px; font-size:24px; font-weight:400; }
  .tags { display:flex; gap:8px; flex-wrap:wrap; margin:14px 0; }
  .tag { border:1px solid var(--line); border-radius:999px; padding:5px 12px; font-weight:700; }
  .add-tag { border-style:dashed; color:var(--muted); font-weight:400; }
  .actions { display:flex; gap:10px; margin-top:16px; }
  .actions button { flex:1; }
  .primary { background:#eff3f4; color:#0f1419; border-color:#eff3f4; }
  .error { color:#f4212e; }
`;
