/* A stand-in for the design canvas's runtime, which is not in this repo: it renders the .dc.html artboards in any browser.
 * It reads what the files use and nothing more: {{path}} in text and attributes, <sc-for list as>, <sc-if value>, <dc-import name ...props>,
 * <helmet><style> and `class Component extends DCLogic` with renderVals() and this.props (defaults from data-props).
 * Open an artboard with `?` nothing: it renders on load. To screenshot them all: scripts/render-artboards.sh. Serve over file:// with
 * --allow-file-access-from-files (the script does), because an imported artboard is fetched.
 * It is a reconstruction: if the canvas draws something this does not, the canvas is right. */
(() => {
  const here = document.currentScript.src.replace(/[^/]*$/, '');
  class DCLogic { constructor(props) { this.props = props || {}; } }
  window.DCLogic = DCLogic;

  const docs = {};
  const loadDoc = (name) => (docs[name] ??= fetch(here + name + '.dc.html').then(async (r) => {
    if (!r.ok) throw new Error('no artboard ' + name);
    return new DOMParser().parseFromString(await r.text(), 'text/html');
  }));

  const unwrap = (s) => { const m = /^\s*\{\{([\s\S]*)\}\}\s*$/.exec(s || ''); return m ? m[1] : s; };
  const get = (expr, scope) => {
    const e = String(expr).trim();
    if (e === 'true') return true;
    if (e === 'false') return false;
    return e.split('.').reduce((o, k) => (o == null ? undefined : o[k]), scope);
  };
  const interp = (s, scope) => s.replace(/\{\{([^}]*)\}\}/g, (_, e) => { const v = get(e, scope); return v == null ? '' : String(v); });

  const styled = new Set();
  const addStyle = (css) => {
    if (styled.has(css)) return;
    styled.add(css);
    const el = document.createElement('style');
    el.textContent = css;
    document.head.append(el);
  };

  async function node(n, dest, scope) {
    if (n.nodeType === 3) { dest.append(document.createTextNode(interp(n.nodeValue, scope))); return; }
    if (n.nodeType !== 1) return;
    const tag = n.localName;
    if (tag === 'helmet') { n.querySelectorAll('style').forEach((s) => addStyle(s.textContent)); return; }
    if (tag === 'sc-for') {
      const list = get(unwrap(n.getAttribute('list')), scope) || [];
      for (const item of list) await children(n, dest, { ...scope, [n.getAttribute('as')]: item });
      return;
    }
    if (tag === 'sc-if') {
      if (get(unwrap(n.getAttribute('value')), scope)) await children(n, dest, scope);
      return;
    }
    if (tag === 'dc-import') {
      const props = {};
      for (const a of n.attributes) if (a.name !== 'name' && !a.name.startsWith('hint-')) props[a.name] = interp(a.value, scope);
      dest.append(await instantiate(await loadDoc(n.getAttribute('name')), props));
      return;
    }
    const el = document.createElementNS(n.namespaceURI, n.localName);
    for (const a of n.attributes) el.setAttribute(a.name, interp(a.value, scope));
    await children(n, el, scope);
    dest.append(el);
  }
  const children = async (src, dest, scope) => { for (const n of [...src.childNodes]) await node(n, dest, scope); };

  async function instantiate(doc, overrides) {
    const root = doc.querySelector('x-dc');
    const script = doc.querySelector('script[data-dc-script]');
    const declared = JSON.parse(script.dataset.props || '{}');
    const props = {};
    for (const k of Object.keys(declared)) if (k[0] !== '$' && declared[k].default !== undefined) props[k] = declared[k].default;
    Object.assign(props, overrides);
    const Component = new Function('DCLogic', script.textContent + '\nreturn Component;')(DCLogic);
    const frag = document.createDocumentFragment();
    await children(root, frag, new Component(props).renderVals());
    return frag;
  }

  const ready = async () => {
    const root = document.querySelector('x-dc');
    if (!root) return;
    const frag = await instantiate(document, {});
    root.replaceWith(frag);
    document.documentElement.setAttribute('data-dc-ready', '');
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready); else ready();
})();
