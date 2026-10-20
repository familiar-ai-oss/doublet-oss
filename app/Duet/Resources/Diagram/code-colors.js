// Duet's colors for a file's page: highlight.js (bundled beside this) colors the whole file at once, so a docstring or
// a block comment that runs over many lines is colored as one, then each line's colored text goes back into its own row.
// The rows, their text and their sizes stay as they are: notes, marks and ink are tagged to them.
(() => {
  // Each line's colored HTML: a span still open at a line's end is closed there and opened again on the next line.
  // A doc comment (///, /**, //!) and a Python docstring (a triple-quoted string starting its line) are marked as docs.
  function split(html, docstrings) {
    const out = [];
    const open = [];
    let line = '';
    // Only spaces on this line so far.
    let blank = true;
    const re = /<span class="([^"]*)">|<\/span>|\n/g;
    let at = 0;
    for (let m = re.exec(html); m; m = re.exec(html)) {
      const text = html.slice(at, m.index);
      line += text;
      if (blank && /\S/.test(text)) blank = false;
      at = re.lastIndex;
      if (m[0] === '\n') {
        out.push(line + '</span>'.repeat(open.length));
        line = open.join('');
        blank = open.length === 0;
      } else if (m[0] === '</span>') {
        open.pop();
        line += m[0];
      } else {
        let cls = m[1];
        if (open.length === 0) {
          const next = html.slice(at, at + 24);
          if (cls === 'hljs-comment' && /^(\/\/\/(?!\/)|\/\/!|\/\*\*(?![*/])|\/\*!)/.test(next)) cls += ' hljs-doc';
          else if (docstrings && blank && cls === 'hljs-string' && /^[rRuUbB]{0,2}(&quot;&quot;&quot;|&#x27;&#x27;&#x27;)/.test(next)) cls += ' hljs-doc';
        }
        const tag = '<span class="' + cls + '">';
        open.push(tag);
        line += tag;
        blank = false;
      }
    }
    out.push(line + html.slice(at) + '</span>'.repeat(open.length));
    return out;
  }

  function color() {
    const lang = document.body?.dataset.lang;
    if (!lang || !window.hljs?.getLanguage(lang)) return;
    const rows = document.querySelectorAll('.ln > .cd');
    if (!rows.length) return;
    let html;
    try {
      html = hljs.highlight(Array.from(rows, (r) => r.textContent).join('\n'), { language: lang, ignoreIllegals: true }).value;
    } catch {
      return;
    }
    const lines = split(html, lang === 'python');
    if (lines.length !== rows.length) return;
    for (let i = 0; i < rows.length; i++) rows[i].innerHTML = lines[i];
  }

  // A long file (~1,000 lines and up, 25 ms or more to color on a Mac) shows plain first and is colored just after, so
  // it opens as fast as before.
  if ((document.body?.dataset.size || 0) > 40000) setTimeout(color, 30);
  else color();
})();
