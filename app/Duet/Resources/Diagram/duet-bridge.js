// Duet's side of a diagram page: render Mermaid (or wrap Claude's HTML, or a diff), then tell the app where every
// element is, so a tap, a Pencil hover or a handwritten note can be tagged to the element under it.
(() => {
  const post = (m) => window.webkit?.messageHandlers?.duet?.postMessage(m);
  // Mermaid's element groups: flowchart nodes and subgraphs, sequence actors, classes, states, ER entities,
  // mindmap and timeline nodes, gantt tasks, journey tasks, pie slices, git commits.
  const MERMAID = [
    'g.node', 'g.cluster', 'g.actor', 'rect.actor', 'g.classGroup', 'g.statediagram-state', 'g.stateGroup',
    'g.mindmap-node', 'g.timeline-node', 'g[id^="entity-"]', 'rect.task', 'g.task', 'path.pieCircle', 'g.commit-bullets circle',
  ].join(',');
  let mode = 'mermaid';
  const selector = () => (mode === 'mermaid' ? MERMAID : mode === 'diff' ? '.ln' : '[id], [data-duet]');

  const clean = (s) => (s || '').replace(/\s+/g, ' ').trim().slice(0, 140);
  // The words as shown: a label's lines (<br>, tspans) are separate text nodes, so they're joined with spaces.
  function words(el) {
    const parts = [];
    const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let n = walk.nextNode(); n; n = walk.nextNode()) parts.push(n.data);
    return parts.join(' ');
  }
  function label(el) {
    if (mode === 'diff') return clean(el.dataset.code);
    const t = el.querySelector?.('.nodeLabel, .label, .actor, text, foreignObject');
    return clean(words(t || el)) || clean(el.getAttribute('aria-label')) || '';
  }
  // Keep the author's id: Mermaid renders node A as "duet-svg-flowchart-A-12" (the SVG's id first), state S as
  // "duet-svg-state-S-3".
  function anchorId(el) {
    if (mode === 'diff') return el.id;
    const raw = (el.id || el.getAttribute('data-duet') || el.getAttribute('data-id') || '').replace(/^duet-svg-/, '');
    const m = raw.match(/^flowchart-(.+)-\d+$/) || raw.match(/^(?:state|classId|entity|mindmap-node|commit)-(.+?)(?:-\d+)?$/);
    return (m ? m[1] : raw) || label(el);
  }
  function anchors() {
    const out = [];
    const seen = new Set();
    for (const el of document.querySelectorAll(selector())) {
      if (el.id === 'duet-svg' || el.closest('#err')) continue;
      const r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2) continue;
      const id = anchorId(el);
      if (!id || seen.has(id)) continue;
      seen.add(id);
      const a = { id, label: label(el) || id, x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height };
      if (mode === 'diff') Object.assign(a, { file: el.dataset.file, line: Number(el.dataset.line) || null, kind: el.dataset.kind });
      out.push(a);
      if (out.length >= 4000) break;
    }
    return out;
  }
  // After the current task, once the new content is in: measuring forces layout, so no animation frame is needed
  // (and WebKit pauses those for a view it thinks is hidden).
  function report() {
    setTimeout(() => post({
      type: 'layout',
      width: Math.ceil(document.documentElement.scrollWidth),
      height: Math.ceil(document.documentElement.scrollHeight),
      anchors: anchors(),
      notes: [...document.querySelectorAll('.nc')].map((el) => {
        const r = el.getBoundingClientRect();
        return { ids: el.dataset.ids || '', x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height };
      }),
      // A code page's diagram marks and element chips, then the cards they sit in.
      diagrams: [...document.querySelectorAll('.dx, .dm'), ...document.querySelectorAll('.dc')].map((el) => {
        const r = el.getBoundingClientRect();
        return { id: el.dataset.diagram || '', el: el.dataset.el || '', x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height };
      }),
    }), 0);
  }
  function find(id) {
    for (const el of document.querySelectorAll(selector())) if (anchorId(el) === id) return el;
    return null;
  }

  window.duet = {
    async render(source, dark, fit) {
      mode = 'mermaid';
      document.body.classList.toggle('fit', !!fit);
      const out = document.getElementById('d');
      const err = document.getElementById('err');
      try {
        mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default', fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif' });
        const { svg } = await mermaid.render('duet-svg', source);
        out.innerHTML = svg;
        err.textContent = '';
      } catch (e) {
        out.innerHTML = '';
        err.textContent = String(e?.message || e);
        post({ type: 'error', message: String(e?.message || e) });
      }
      report();
    },
    // Claude's HTML page or a diff: the page is already loaded; just index it.
    index(kind) {
      mode = kind;
      report();
    },
    highlight(id, cls) {
      document.querySelectorAll('.' + cls).forEach((e) => e.classList.remove(cls));
      if (id) find(id)?.classList.add(cls);
    },
    report,
  };
  // A tap on a note's marker opens the note; on a diagram's card, chip or mark opens the diagram; on an element picks
  // it; anywhere else clears the pick.
  document.addEventListener('click', (ev) => {
    const mark = ev.target.closest?.('.mk, .nc');
    if (mark) { post({ type: 'mark', ids: (mark.dataset.ids || '').split(',').filter(Boolean) }); return; }
    const diagram = ev.target.closest?.('[data-diagram]');
    if (diagram) { post({ type: 'diagram', id: diagram.dataset.diagram, el: diagram.dataset.el || '' }); return; }
    const el = ev.target.closest?.(selector());
    post(el ? { type: 'tap', id: anchorId(el), label: label(el) } : { type: 'tap', id: null });
  }, true);
  new ResizeObserver(() => report()).observe(document.documentElement);
  // Ready once the body exists: the app renders into it, or indexes Claude's page.
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => post({ type: 'ready' }));
  else post({ type: 'ready' });
})();
