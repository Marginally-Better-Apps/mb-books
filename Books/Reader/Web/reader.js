// MB Books reading engine. Runs in an isolated content world inside each spine item.
// Native code wraps this file as `((__MB_CONFIG__) => { ... })(config)` and drives it via `MB.*`.
(() => {
  'use strict';
  if (window.MB) return;

  const OPS = 'http://www.idpf.org/2007/ops';
  const post = (type, body = {}) => {
    try { window.webkit.messageHandlers.mb.postMessage(Object.assign({ type }, body)); } catch (_) { /* detached */ }
  };

  window.addEventListener('error', (event) => post('log', { message: `${event.message} @${event.lineno}` }));
  window.addEventListener('unhandledrejection', (event) => post('log', { message: `rejection: ${event.reason}` }));

  const state = {
    config: typeof __MB_CONFIG__ === 'object' && __MB_CONFIG__ ? __MB_CONFIG__ : {},
    ready: false,
    anchor: null,
    highlights: [],
    textNodes: null,
    relocateTimer: null,
    layoutTimer: null,
  };

  // ---------------------------------------------------------------------------
  // Styles

  const sheet = new CSSStyleSheet();

  function attachSheet() {
    try {
      if (!document.adoptedStyleSheets.includes(sheet)) {
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      }
    } catch (_) { /* Very old documents only; styles are best-effort there. */ }
  }

  const isFixed = () => state.config.layout === 'pre-paginated' || state.config.layout === 'roll';
  const isPaginated = () => !isFixed() && state.config.mode !== 'scroll';

  function highlightCSS(dark) {
    const alpha = dark ? 0.38 : 0.42;
    const colors = {
      yellow: [255, 214, 51], green: [116, 217, 102], blue: [102, 178, 255], pink: [255, 128, 166], purple: [184, 140, 255],
    };
    let css = Object.entries(colors)
      .map(([name, [r, g, b]]) => `::highlight(mb-${name}){background-color:rgba(${r},${g},${b},${alpha});}`)
      .join('');
    css += '::highlight(mb-underline){text-decoration:underline;text-decoration-color:#ff3b30;text-decoration-thickness:2px;}';
    css += '::highlight(mb-search){background-color:rgba(255,159,10,.55);}';
    // Read aloud: boxes over the sentence being spoken and the word within it (see `drawSpeech`).
    css += '#mb-speech-layer{position:absolute;left:0;top:0;width:0;height:0;pointer-events:none;z-index:2147483646;}';
    css += '#mb-speech-layer>div{position:absolute;border-radius:3px;}';
    css += `#mb-speech-layer>.sentence{background-color:rgba(10,132,255,${dark ? 0.2 : 0.12});}`;
    css += `#mb-speech-layer>.word{background-color:rgba(10,132,255,${dark ? 0.38 : 0.26});}`;
    return css;
  }

  function reflowableCSS() {
    const c = state.config;
    const insets = c.insets || { top: 0, bottom: 0, side: 0 };
    const colors = c.colors || {};
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const columns = Math.max(1, c.columns || 1);
    const rules = [];

    // Footnotes open in a popover, so their asides stay out of the reading flow, as in Apple Books.
    rules.push(`@namespace epub "${OPS}";`);
    rules.push('aside:is([epub|type~="footnote"],[epub|type~="endnote"],[epub|type~="rearnote"]){display:none !important;}');
    rules.push(`:root{--mb-bg:${colors.background};--mb-text:${colors.text};--mb-link:${colors.link};}`);
    rules.push(`html{-webkit-text-size-adjust:${Math.round((c.fontScale || 1) * 100)}% !important;` +
      'margin:0 !important;background-color:var(--mb-bg) !important;-webkit-tap-highlight-color:transparent;}');

    if (isPaginated()) {
      const columnHeight = vh - insets.top - insets.bottom;
      rules.push('html{box-sizing:border-box !important;height:100vh !important;max-height:100vh !important;' +
        `padding:${insets.top}px 0 ${insets.bottom}px 0 !important;` +
        `column-width:${vw / columns}px !important;column-gap:0 !important;column-fill:auto !important;` +
        'overflow-x:auto !important;overflow-y:hidden !important;}');
      rules.push('body{box-sizing:border-box !important;margin:0 !important;' +
        `padding:0 ${insets.side}px !important;max-width:none !important;width:auto !important;` +
        'height:auto !important;min-height:0 !important;overflow:visible !important;}');
      rules.push(`img,svg,video,canvas,iframe,object,embed,table{max-height:${columnHeight}px !important;}`);
      rules.push('img,svg,video,canvas,figure,table,tr{break-inside:avoid;-webkit-column-break-inside:avoid;}');
      rules.push('html.mb-pad body::after{content:"";display:block;height:1px;' +
        'break-before:column;-webkit-column-break-before:always;}');
    } else {
      rules.push(`html{box-sizing:border-box !important;padding:${insets.top}px 0 ${insets.bottom}px 0 !important;` +
        'height:auto !important;columns:auto !important;}');
      rules.push(`body{box-sizing:border-box !important;margin:0 auto !important;padding:0 ${insets.side}px !important;` +
        `max-width:${Math.max(vw, 320)}px !important;}`);
      rules.push(`img,svg,video,canvas{max-height:${vh - insets.top - insets.bottom}px !important;}`);
    }
    rules.push('img,svg,video,canvas,iframe,object,embed{max-width:100% !important;box-sizing:border-box;}');
    rules.push('img,video{object-fit:contain;height:auto;}');

    if (colors.override) {
      rules.push('html,body{color:var(--mb-text) !important;}');
      rules.push('body :not(img):not(svg):not(svg *):not(video):not(math):not(math *):not(canvas){' +
        'color:inherit !important;background-color:transparent !important;border-color:currentColor;}');
      rules.push('body a:link,body a:visited,body a:link *,body a:visited *{color:var(--mb-link) !important;}');
    } else {
      rules.push('body{color:var(--mb-text);}');
    }

    const skip = ':not(code):not(pre):not(kbd):not(samp):not(tt):not(var):not(math):not(math *):not(svg):not(svg *)';
    if (c.fontFamily) {
      rules.push(`:root{--mb-font:${c.fontFamily};}`);
      rules.push(`body,body *${skip}{font-family:var(--mb-font) !important;}`);
    }
    if (c.bold) {
      rules.push(`body,body *${skip}{font-weight:600 !important;}`);
      rules.push('body :is(h1,h2,h3,h4,h5,h6,b,strong,th),body :is(h1,h2,h3,h4,h5,h6,b,strong,th) *{font-weight:800 !important;}');
    }
    if (c.lineHeight) rules.push(`body,body *${skip}{line-height:${c.lineHeight} !important;}`);
    if (c.letterSpacing) rules.push(`body *${skip}{letter-spacing:${c.letterSpacing}em !important;}`);
    if (c.wordSpacing) rules.push(`body *${skip}{word-spacing:${c.wordSpacing}em !important;}`);
    if (c.justify) {
      rules.push('body :is(p,li,blockquote,dd){text-align:justify !important;-webkit-hyphens:auto;hyphens:auto;}');
    }
    rules.push(highlightCSS(c.dark));
    return rules.join('\n');
  }

  // ---------------------------------------------------------------------------
  // Fixed layouts (pre-paginated and roll)

  function intrinsicSize() {
    if (state.config.fixedSize) return state.config.fixedSize;
    const meta = document.querySelector('meta[name="viewport"]');
    if (meta) {
      const content = meta.getAttribute('data-mb-original') || meta.getAttribute('content') || '';
      const width = /width\s*=\s*(\d+(?:\.\d+)?)/.exec(content);
      const height = /height\s*=\s*(\d+(?:\.\d+)?)/.exec(content);
      if (width && height) return { width: parseFloat(width[1]), height: parseFloat(height[1]) };
    }
    const root = document.documentElement;
    if (root.localName === 'svg' && root.viewBox && root.viewBox.baseVal && root.viewBox.baseVal.width) {
      return { width: root.viewBox.baseVal.width, height: root.viewBox.baseVal.height };
    }
    return { width: 1024, height: 1366 };
  }

  function neutralizeViewport() {
    const meta = document.querySelector('meta[name="viewport"]');
    if (meta && !meta.hasAttribute('data-mb-original')) {
      meta.setAttribute('data-mb-original', meta.getAttribute('content') || '');
      meta.setAttribute('content', 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no');
    }
  }

  function fixedCSS() {
    const c = state.config;
    const size = intrinsicSize();
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const roll = c.layout === 'roll';
    const scale = roll ? vw / size.width : Math.min(vw / size.width, vh / size.height);
    const x = roll ? 0 : (vw - size.width * scale) / 2;
    const y = roll ? 0 : (vh - size.height * scale) / 2;
    const background = (c.colors && c.colors.background) || '#fff';
    if (document.documentElement.localName === 'svg') {
      return `svg:root{width:100vw !important;height:100vh !important;background:${background};}`;
    }
    return `html{margin:0 !important;padding:0 !important;width:100vw !important;height:100vh !important;` +
      `overflow:hidden !important;background-color:${background} !important;-webkit-tap-highlight-color:transparent;}` +
      `body{position:absolute !important;left:0 !important;top:0 !important;margin:0 !important;` +
      `width:${size.width}px !important;height:${size.height}px !important;overflow:hidden !important;` +
      `transform-origin:0 0 !important;transform:translate(${x}px,${y}px) scale(${scale}) !important;}` +
      highlightCSS(c.dark);
  }

  // ---------------------------------------------------------------------------
  // Layout

  function applyStyles() {
    if (isFixed()) neutralizeViewport();
    sheet.replaceSync(isFixed() ? fixedCSS() : reflowableCSS());
    attachSheet();
  }

  const scroller = () => document.scrollingElement || document.documentElement;
  // A web view can briefly be zero-sized while it moves between views; never divide by zero.
  const pageWidth = () => Math.max(1, window.innerWidth);
  const isRTL = () => getComputedStyle(document.documentElement).direction === 'rtl' ||
    (document.body && getComputedStyle(document.body).direction === 'rtl');

  function pageCount() {
    if (!isPaginated()) return 1;
    const count = Math.round(scroller().scrollWidth / pageWidth());
    return Number.isFinite(count) ? Math.max(1, count) : 1;
  }

  /// Keeps the scroll width a whole number of pages when multiple columns leave a half page.
  function padColumns() {
    const root = document.documentElement;
    if (!isPaginated() || (state.config.columns || 1) < 2) { root.classList.remove('mb-pad'); return; }
    root.classList.remove('mb-pad');
    const remainder = scroller().scrollWidth % pageWidth();
    if (remainder > 1 && remainder < pageWidth() - 1) root.classList.add('mb-pad');
  }

  function currentPage() {
    if (!isPaginated()) return 0;
    const x = Math.abs(window.scrollX);
    return Math.min(pageCount() - 1, Math.round(x / pageWidth()));
  }

  function layoutInfo() {
    return {
      pageCount: pageCount(),
      rtl: isRTL(),
      contentHeight: scroller().scrollHeight,
      viewportHeight: window.innerHeight,
    };
  }

  function relayout(reason) {
    if (window.innerWidth === 0 || window.innerHeight === 0) return layoutInfo();
    state.textNodes = null;
    applyStyles();
    padColumns();
    // Text moved: put the read-aloud boxes back over it.
    if (state.speech) drawSpeech();
    const info = layoutInfo();
    if (state.ready) {
      info.reason = reason;
      info.anchorPosition = state.anchor ? positionFor({ cfi: state.anchor }) : null;
      post('layout', info);
    }
    return info;
  }

  function scheduleRelayout(reason) {
    clearTimeout(state.layoutTimer);
    state.layoutTimer = setTimeout(() => relayout(reason), 60);
  }

  // ---------------------------------------------------------------------------
  // Text nodes and positions

  const SKIP_TEXT = new Set(['script', 'style', 'noscript', 'template', 'head', 'title']);

  function textNodes() {
    if (state.textNodes) return state.textNodes;
    const nodes = [];
    if (document.body) {
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
          for (let parent = node.parentNode; parent && parent !== document.body; parent = parent.parentNode) {
            if (SKIP_TEXT.has(parent.localName)) return NodeFilter.FILTER_REJECT;
          }
          return NodeFilter.FILTER_ACCEPT;
        },
      });
      while (walker.nextNode()) nodes.push(walker.currentNode);
    }
    state.textNodes = nodes;
    return nodes;
  }

  function rangeRects(node, start, end) {
    const range = document.createRange();
    range.setStart(node, start);
    range.setEnd(node, end === undefined ? node.length : end);
    return range.getClientRects();
  }

  /// Whether a client rect lies at or beyond the start of the viewport in reading order.
  function reachesViewport(rect) {
    if (!isPaginated()) return rect.bottom > (state.config.insets ? state.config.insets.top : 0);
    return isRTL() ? rect.left < pageWidth() : rect.right > 0;
  }

  function firstVisiblePosition() {
    const nodes = textNodes().filter((node) => node.nodeValue.trim().length);
    let low = 0;
    let high = nodes.length - 1;
    let found = -1;
    while (low <= high) {
      const mid = (low + high) >> 1;
      const rects = rangeRects(nodes[mid], 0);
      const last = rects[rects.length - 1];
      if (last && reachesViewport(last)) { found = mid; high = mid - 1; } else { low = mid + 1; }
    }
    if (found < 0) return firstVisibleElement();
    const node = nodes[found];
    let lo = 0;
    let hi = node.length - 1;
    let offset = 0;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      const rects = rangeRects(node, mid, mid + 1);
      const rect = rects[rects.length - 1];
      if (!rect || reachesViewport(rect)) { offset = mid; hi = mid - 1; } else { lo = mid + 1; }
    }
    return { node, offset };
  }

  function firstVisibleElement() {
    const media = document.body ? document.body.querySelectorAll('img, svg, video, audio, canvas, figure') : [];
    for (const element of media) {
      const rect = element.getBoundingClientRect();
      if (rect.width && reachesViewport(rect)) return { node: element, offset: null };
    }
    return document.body ? { node: document.body, offset: null } : null;
  }

  // ---------------------------------------------------------------------------
  // EPUB CFI (document-local part, e.g. "/4/2/3:10")

  const isElement = (node) => node && node.nodeType === Node.ELEMENT_NODE;
  const isText = (node) => node && (node.nodeType === Node.TEXT_NODE || node.nodeType === Node.CDATA_SECTION_NODE);
  const elementChildren = (node) => Array.from(node.childNodes).filter(isElement);

  function cfiFor(node, offset) {
    if (!node) return null;
    const steps = [];
    let characterOffset = null;
    if (isElement(node) && offset !== null && offset !== undefined) {
      // A range boundary inside an element: point at the child it precedes.
      const child = node.childNodes[offset];
      if (child) return cfiFor(child, isText(child) ? 0 : null);
      offset = null;
    }
    if (isText(node)) {
      let chunkOffset = offset || 0;
      let elementsBefore = 0;
      let inChunk = true;
      for (let sibling = node.previousSibling; sibling; sibling = sibling.previousSibling) {
        if (isElement(sibling)) { elementsBefore += 1; inChunk = false; } else if (inChunk && isText(sibling)) {
          chunkOffset += sibling.length;
        }
      }
      steps.unshift(elementsBefore * 2 + 1);
      characterOffset = chunkOffset;
      node = node.parentNode;
    }
    while (node && node !== document.documentElement && node.parentNode) {
      const index = elementChildren(node.parentNode).indexOf(node);
      steps.unshift((index + 1) * 2);
      node = node.parentNode;
    }
    return '/' + steps.join('/') + (characterOffset !== null ? ':' + characterOffset : '');
  }

  function resolveCFI(cfi) {
    if (!cfi) return null;
    const local = String(cfi).replace(/^epubcfi\(/, '').replace(/\)$/, '').split('!').pop().split(',')[0];
    const match = /^((?:\/\d+(?:\[[^\]]*\])?)+)(?::(\d+))?/.exec(local);
    if (!match) return null;
    const steps = match[1].split('/').filter(Boolean).map((step) => parseInt(step, 10));
    const characterOffset = match[2] !== undefined ? parseInt(match[2], 10) : null;
    let node = document.documentElement;
    for (let i = 0; i < steps.length; i += 1) {
      const step = steps[i];
      if (step % 2 === 0) {
        const child = elementChildren(node)[step / 2 - 1];
        if (!child) return { node, offset: null };
        node = child;
      } else {
        const wanted = (step - 1) / 2;
        let elements = 0;
        const chunk = [];
        for (const child of node.childNodes) {
          if (isElement(child)) { elements += 1; if (elements > wanted) break; continue; }
          if (elements === wanted && isText(child)) chunk.push(child);
        }
        if (!chunk.length) return { node, offset: null };
        let remaining = characterOffset || 0;
        for (const text of chunk) {
          if (remaining <= text.length) return { node: text, offset: remaining };
          remaining -= text.length;
        }
        const last = chunk[chunk.length - 1];
        return { node: last, offset: last.length };
      }
    }
    return { node, offset: null };
  }

  function rangeFromCFIs(start, end) {
    const a = resolveCFI(start);
    const b = resolveCFI(end);
    if (!a || !b) return null;
    const range = document.createRange();
    try {
      if (isText(a.node)) range.setStart(a.node, Math.min(a.offset || 0, a.node.length)); else range.setStartBefore(a.node);
      if (isText(b.node)) range.setEnd(b.node, Math.min(b.offset || 0, b.node.length)); else range.setEndAfter(b.node);
    } catch (_) { return null; }
    return range;
  }

  // ---------------------------------------------------------------------------
  // Positions: pages (paginated) or y offsets (scroll)

  function pageOfRect(rect) {
    const width = pageWidth();
    if (isRTL()) {
      const fromStart = width - (rect.right + window.scrollX);
      return Math.max(0, Math.min(pageCount() - 1, Math.floor((fromStart + 1) / width)));
    }
    return Math.max(0, Math.min(pageCount() - 1, Math.floor((rect.left + window.scrollX + 1) / width)));
  }

  function rectOf(position) {
    if (!position) return null;
    if (isText(position.node)) {
      const node = position.node;
      const offset = Math.min(position.offset || 0, Math.max(0, node.length - 1));
      const rects = rangeRects(node, offset, Math.min(node.length, offset + 1));
      if (rects.length) return rects[0];
      const parent = node.parentNode;
      return parent && parent.getBoundingClientRect ? parent.getBoundingClientRect() : null;
    }
    return position.node.getBoundingClientRect ? position.node.getBoundingClientRect() : null;
  }

  /// Returns `{page}` in paginated mode or `{y}` in scroll mode.
  function positionFor(target) {
    if (!target) return null;
    if (target.position === 'end') {
      return isPaginated() ? { page: pageCount() - 1 } : { y: Math.max(0, scroller().scrollHeight - window.innerHeight) };
    }
    let rect = null;
    if (target.cfi) rect = rectOf(resolveCFI(target.cfi));
    if (!rect && target.fragment) {
      const element = document.getElementById(target.fragment) ||
        document.querySelector(`[name="${CSS.escape(target.fragment)}"]`);
      if (element) rect = element.getBoundingClientRect();
    }
    if (!rect && typeof target.progression === 'number') {
      if (isPaginated()) return { page: Math.round(target.progression * (pageCount() - 1)) };
      return { y: Math.round(target.progression * Math.max(0, scroller().scrollHeight - window.innerHeight)) };
    }
    if (!rect) return isPaginated() ? { page: 0 } : { y: 0 };
    if (isPaginated()) return { page: pageOfRect(rect) };
    const top = state.config.insets ? state.config.insets.top : 0;
    return { y: Math.max(0, rect.top + window.scrollY - top) };
  }

  function progression() {
    if (isPaginated()) {
      const count = pageCount();
      return count <= 1 ? 0 : currentPage() / (count - 1);
    }
    const max = scroller().scrollHeight - window.innerHeight;
    return max <= 0 ? 0 : Math.min(1, Math.max(0, window.scrollY / max));
  }

  function location() {
    const position = isFixed() ? null : firstVisiblePosition();
    const cfi = position ? cfiFor(position.node, position.offset) : null;
    return { cfi, progression: progression(), page: currentPage(), pageCount: pageCount(), text: snippet(position) };
  }

  function snippet(position) {
    if (!position || !isText(position.node)) return '';
    const nodes = textNodes();
    let index = nodes.indexOf(position.node);
    let text = position.node.nodeValue.slice(position.offset || 0);
    while (text.length < 160 && index >= 0 && index < nodes.length - 1) {
      index += 1;
      text += nodes[index].nodeValue;
    }
    return text.replace(/\s+/g, ' ').trim().slice(0, 160);
  }

  function scheduleRelocate() {
    clearTimeout(state.relocateTimer);
    state.relocateTimer = setTimeout(() => {
      if (!state.ready) return;
      const info = location();
      state.anchor = info.cfi;
      post('relocated', info);
    }, 140);
  }

  // ---------------------------------------------------------------------------
  // Highlights (CSS Custom Highlight API: no DOM mutation, so CFIs stay stable)

  function setHighlights(list) {
    state.highlights = (list || []).map((item) => Object.assign({}, item, { range: rangeFromCFIs(item.start, item.end) }));
    renderHighlights();
  }

  function renderHighlights() {
    if (!window.CSS || !CSS.highlights) return;
    for (const name of ['yellow', 'green', 'blue', 'pink', 'purple', 'underline']) CSS.highlights.delete(`mb-${name}`);
    const groups = {};
    for (const item of state.highlights) {
      if (!item.range) continue;
      (groups[item.color] = groups[item.color] || []).push(item.range);
    }
    for (const [color, ranges] of Object.entries(groups)) CSS.highlights.set(`mb-${color}`, new Highlight(...ranges));
  }

  function highlightAt(x, y) {
    for (const item of state.highlights) {
      if (!item.range) continue;
      for (const rect of item.range.getClientRects()) {
        if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
          return { id: item.id, rect: boundingRect(item.range) };
        }
      }
    }
    return null;
  }

  function boundingRect(range) {
    const rect = range.getBoundingClientRect();
    return { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
  }

  // ---------------------------------------------------------------------------
  // Selection

  function normalizedBoundary(container, offset) {
    if (isText(container)) return { node: container, offset };
    const child = container.childNodes[offset];
    if (child && isText(child)) return { node: child, offset: 0 };
    return { node: container, offset };
  }

  function selection() {
    const selected = window.getSelection();
    if (!selected || selected.isCollapsed || !selected.rangeCount) return null;
    const range = selected.getRangeAt(0);
    const start = normalizedBoundary(range.startContainer, range.startOffset);
    const end = normalizedBoundary(range.endContainer, range.endOffset);
    return {
      text: selected.toString(),
      start: cfiFor(start.node, start.offset),
      end: cfiFor(end.node, end.offset),
      rect: boundingRect(range),
      progression: progression(),
    };
  }

  // ---------------------------------------------------------------------------
  // Search

  function find(query, offsetHint, occurrence) {
    const nodes = textNodes();
    let text = '';
    const starts = [];
    for (const node of nodes) { starts.push(text.length); text += node.nodeValue; }
    const needle = query.toLowerCase();
    const haystack = text.toLowerCase();
    let index = -1;
    if (typeof offsetHint === 'number' && haystack.substr(offsetHint, needle.length) === needle) {
      index = offsetHint;
    } else {
      let from = 0;
      for (let n = 0; n <= (occurrence || 0); n += 1) {
        index = haystack.indexOf(needle, from);
        if (index < 0) break;
        from = index + 1;
      }
    }
    if (index < 0) return null;
    const locate = (absolute) => {
      let low = 0;
      let high = starts.length - 1;
      while (low < high) {
        const mid = (low + high + 1) >> 1;
        if (starts[mid] <= absolute) low = mid; else high = mid - 1;
      }
      return { node: nodes[low], offset: absolute - starts[low] };
    };
    const a = locate(index);
    const b = locate(index + needle.length);
    const range = document.createRange();
    range.setStart(a.node, a.offset);
    range.setEnd(b.node, Math.min(b.offset, b.node.length));
    if (window.CSS && CSS.highlights) {
      CSS.highlights.set('mb-search', new Highlight(range));
      setTimeout(() => CSS.highlights.delete('mb-search'), 2500);
    }
    const rect = range.getClientRects()[0] || range.getBoundingClientRect();
    if (isPaginated()) return { page: pageOfRect(rect) };
    const top = state.config.insets ? state.config.insets.top : 0;
    return { y: Math.max(0, rect.top + window.scrollY - top - 80) };
  }

  // ---------------------------------------------------------------------------
  // Read aloud. Native code addresses text by UTF-16 offset into the concatenated text nodes,
  // the same offsets `BookSearcher.bodyText` produces, so speech scripts built in Swift line up.

  /// Cached with the text nodes: highlighting asks for this on every spoken word.
  function textStarts() {
    const nodes = textNodes();
    if (state.textStarts && state.textStarts.nodes === nodes) return state.textStarts;
    const starts = [];
    let total = 0;
    for (const node of nodes) { starts.push(total); total += node.length; }
    state.textStarts = { nodes, starts, total };
    return state.textStarts;
  }

  function locateOffset(index, absolute) {
    const { nodes, starts } = index;
    if (!nodes.length) return null;
    let low = 0;
    let high = starts.length - 1;
    while (low < high) {
      const mid = (low + high + 1) >> 1;
      if (starts[mid] <= absolute) low = mid; else high = mid - 1;
    }
    return { node: nodes[low], offset: Math.max(0, Math.min(nodes[low].length, absolute - starts[low])) };
  }

  function offsetOf(node, offset) {
    const { nodes, starts } = textStarts();
    const index = isText(node) ? nodes.indexOf(node) : -1;
    if (index >= 0) return starts[index] + (offset || 0);
    // An element boundary: the first text node at or after it.
    for (let i = 0; i < nodes.length; i += 1) {
      const position = node.compareDocumentPosition(nodes[i]);
      if (position & Node.DOCUMENT_POSITION_FOLLOWING || position & Node.DOCUMENT_POSITION_CONTAINED_BY) return starts[i];
    }
    return null;
  }

  function rangeForOffsets(index, start, end) {
    const a = locateOffset(index, start);
    const b = locateOffset(index, Math.max(start, end));
    if (!a || !b) return null;
    const range = document.createRange();
    try {
      range.setStart(a.node, a.offset);
      range.setEnd(b.node, b.offset);
    } catch (_) { return null; }
    return range;
  }

  /// The page (or scroll offset) showing the character at `absolute`, skipping characters without boxes.
  function placeOfOffset(index, absolute, limit) {
    for (let at = absolute; at < Math.min(limit, absolute + 64); at += 1) {
      const position = locateOffset(index, at);
      if (!position || position.offset >= position.node.length) continue;
      const rects = rangeRects(position.node, position.offset, position.offset + 1);
      const rect = rects[0];
      if (rect && (rect.width || rect.height)) return rect;
    }
    return null;
  }

  function pageAt(index, absolute, limit) {
    const rect = placeOfOffset(index, absolute, limit);
    return rect ? pageOfRect(rect) : null;
  }

  // The sentence and word are drawn as boxes over the text rather than with CSS highlights: iOS doesn't always
  // repaint a changed highlight, which left earlier words lit until the page scrolled.
  function speechLayer() {
    let layer = document.getElementById('mb-speech-layer');
    if (!layer) {
      layer = document.createElement('div');
      layer.id = 'mb-speech-layer';
      layer.setAttribute('aria-hidden', 'true');
      // Outside <body>, so it never counts as text.
      document.documentElement.appendChild(layer);
    }
    return layer;
  }

  /// A range's boxes, one per line: inline elements inside a line would otherwise overlap and double the tint.
  function lineBoxes(range) {
    const lines = [];
    for (const rect of range.getClientRects()) {
      if (!rect.width || !rect.height) continue;
      const line = lines.find((l) => Math.abs(l.top - rect.top) < 3 && Math.abs(l.bottom - rect.bottom) < 3 &&
        rect.left <= l.right + 2 && rect.right >= l.left - 2);
      if (line) {
        line.left = Math.min(line.left, rect.left);
        line.right = Math.max(line.right, rect.right);
      } else {
        lines.push({ left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom });
      }
    }
    return lines;
  }

  /// Draws `state.speech` (or nothing), in document coordinates so the boxes scroll with the text.
  function drawSpeech() {
    const layer = speechLayer();
    const boxes = [];
    const speech = state.speech;
    if (speech) {
      const index = textStarts();
      const sentence = rangeForOffsets(index, speech.start, speech.end);
      if (sentence) for (const box of lineBoxes(sentence)) boxes.push(['sentence', box]);
      if (typeof speech.wordStart === 'number') {
        const word = rangeForOffsets(index, speech.wordStart, speech.wordEnd);
        if (word) for (const box of lineBoxes(word)) boxes.push(['word', box]);
      }
    }
    while (layer.children.length < boxes.length) layer.appendChild(document.createElement('div'));
    while (layer.children.length > boxes.length) layer.lastChild.remove();
    boxes.forEach(([kind, box], i) => {
      const div = layer.children[i];
      div.className = kind;
      div.style.left = `${box.left + window.scrollX - 1}px`;
      div.style.top = `${box.top + window.scrollY}px`;
      div.style.width = `${box.right - box.left + 2}px`;
      div.style.height = `${box.bottom - box.top}px`;
    });
    return !!speech && boxes.length > 0;
  }

  /// Marks the sentence (and word) being read. `sequence` orders the calls: native code may send them out of
  /// order, and an older mark must never replace a newer one.
  function speechMark(start, end, wordStart, wordEnd, sequence) {
    if (typeof sequence === 'number') {
      if (sequence < (state.speechSequence || 0)) return null;
      state.speechSequence = sequence;
    }
    state.speech = { start, end, wordStart, wordEnd };
    const drawn = drawSpeech();
    if (!drawn || isFixed()) return null;
    const index = textStarts();
    if (!isPaginated()) {
      const rect = placeOfOffset(index, typeof wordStart === 'number' ? wordStart : start, end);
      if (!rect) return null;
      const top = state.config.insets ? state.config.insets.top : 0;
      // The listening controls float over the bottom of the screen, so reading stays above them: once the voice
      // reaches the bottom quarter, the text scrolls up to put it a third of the way down.
      const bottom = window.innerHeight * 0.75;
      return {
        visible: rect.top >= top && rect.bottom <= bottom,
        y: Math.max(0, rect.top + window.scrollY - Math.max(top + 40, window.innerHeight / 3)),
      };
    }
    const startPage = pageAt(index, start, end);
    if (startPage === null) return null;
    const endPage = pageAt(index, Math.max(start, end - 1), end) ?? startPage;
    // Where a sentence that runs onto the next page crosses over, so the page can turn mid-sentence.
    let breakOffset = null;
    if (endPage !== startPage) {
      let low = start;
      let high = end - 1;
      while (low < high) {
        const mid = (low + high) >> 1;
        const page = pageAt(index, mid, end);
        if (page !== null && page > startPage) high = mid; else low = mid + 1;
      }
      breakOffset = low;
    }
    const wordPage = typeof wordStart === 'number' ? pageAt(index, wordStart, end) : null;
    return { startPage, endPage, breakOffset, wordPage, currentPage: currentPage() };
  }

  function speechClear(sequence) {
    if (typeof sequence === 'number') {
      if (sequence < (state.speechSequence || 0)) return;
      state.speechSequence = sequence;
    }
    state.speech = null;
    drawSpeech();
  }

  function positionForOffset(absolute) {
    const index = textStarts();
    const rect = placeOfOffset(index, absolute, index.total);
    if (!rect) return isPaginated() ? { page: 0 } : { y: 0 };
    if (isPaginated()) return { page: pageOfRect(rect) };
    const top = state.config.insets ? state.config.insets.top : 0;
    return { y: Math.max(0, rect.top + window.scrollY - top - 80) };
  }

  function firstVisibleOffset() {
    if (isFixed()) return 0;
    const position = firstVisiblePosition();
    if (!position) return 0;
    return offsetOf(position.node, isText(position.node) ? position.offset : null) || 0;
  }

  function selectionOffset() {
    const selected = window.getSelection();
    if (!selected || !selected.rangeCount) return null;
    const range = selected.getRangeAt(0);
    const start = normalizedBoundary(range.startContainer, range.startOffset);
    return offsetOf(start.node, isText(start.node) ? start.offset : null);
  }

  // ---------------------------------------------------------------------------
  // Taps, links, and footnotes

  const INTERACTIVE = 'video, audio, button, input, select, textarea, label, summary, details, iframe, object, embed, ' +
    '[onclick], [contenteditable], [role="button"], [tabindex]';

  function linkHref(link) {
    const raw = link.href;
    if (typeof raw === 'string') return raw;
    if (raw && typeof raw.baseVal === 'string') return new URL(raw.baseVal, document.baseURI).href;
    return link.getAttribute('href');
  }

  function footnoteFor(link, href) {
    let url;
    try { url = new URL(href, document.baseURI); } catch (_) { return null; }
    if (!url.hash || url.href.split('#')[0] !== document.URL.split('#')[0]) return null;
    const target = document.getElementById(decodeURIComponent(url.hash.slice(1)));
    if (!target) return null;
    const types = (element) => ((element && element.getAttributeNS && element.getAttributeNS(OPS, 'type')) || '').split(/\s+/);
    const isNoteRef = types(link).includes('noteref');
    const container = target.closest('aside, li, dd, section, p, div') || target;
    const isNote = ['footnote', 'endnote', 'rearnote', 'note'].some((t) => types(target).includes(t) || types(container).includes(t));
    if (!isNoteRef && !isNote) return null;
    let note = isNote && types(container).some((t) => ['footnote', 'endnote', 'rearnote', 'note'].includes(t)) ? container : target;
    if (note.textContent.trim().length < 2 && note.parentElement) note = note.parentElement;
    return note.textContent.replace(/\s+/g, ' ').trim();
  }

  document.addEventListener('click', (event) => {
    const target = event.target && event.target.nodeType === Node.ELEMENT_NODE ? event.target : event.target && event.target.parentElement;
    if (!target) return;
    const link = target.closest('a[href], area[href]') ||
      (target.closest && target.closest('a') && target.closest('a').hasAttributeNS('http://www.w3.org/1999/xlink', 'href')
        ? target.closest('a') : null);
    if (link) {
      if (event.defaultPrevented) return;
      const href = link.hasAttribute('href') ? linkHref(link)
        : new URL(link.getAttributeNS('http://www.w3.org/1999/xlink', 'href'), document.baseURI).href;
      if (!href || href.startsWith('javascript:')) return;
      event.preventDefault();
      const note = footnoteFor(link, href);
      if (note) {
        post('footnote', { text: note, rect: boundingRect(rangeAround(link)) });
      } else {
        post('link', { href });
      }
      return;
    }
    const x = event.clientX;
    const y = event.clientY;
    setTimeout(() => {
      if (event.defaultPrevented || target.closest(INTERACTIVE)) return;
      const selected = window.getSelection();
      if (selected && !selected.isCollapsed) { selected.removeAllRanges(); return; }
      const hit = highlightAt(x, y);
      if (hit) { post('highlightTap', hit); return; }
      post('tap', { x, y });
    }, 0);
  });

  function rangeAround(element) {
    const range = document.createRange();
    range.selectNode(element);
    return range;
  }


  // ---------------------------------------------------------------------------
  // Wrapper documents: fixed-layout spreads and rolls hosted in scaled iframes

  const wrapperKind = window.location.pathname.includes('/.mbbooks/')
    ? (window.location.pathname.includes('/roll') ? 'roll' : 'fixed') : null;

  function layoutWrapper() {
    const background = (state.config.colors && state.config.colors.background) || '#fff';
    sheet.replaceSync(`html,body{background-color:${background} !important;}`);
    attachSheet();
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const pages = Array.from(document.querySelectorAll('.mb-page'));
    const size = (page) => ({ width: +page.dataset.width || 1024, height: +page.dataset.height || 1366 });
    const place = (page, x, y, scale) => {
      const { width, height } = size(page);
      Object.assign(page.style, {
        width: `${width}px`, height: `${height}px`, left: `${x}px`, top: `${y}px`, transform: `scale(${scale})`,
      });
    };
    if (wrapperKind === 'fixed') {
      const total = pages.reduce((sum, page) => sum + size(page).width, 0) || 1;
      const tallest = Math.max(1, ...pages.map((page) => size(page).height));
      const scale = Math.min(vw / total, vh / tallest);
      let x = (vw - total * scale) / 2;
      for (const page of pages) {
        place(page, x, (vh - size(page).height * scale) / 2, scale);
        x += size(page).width * scale;
      }
    } else {
      for (const page of pages) {
        const scale = vw / size(page).width;
        page.parentElement.style.height = `${size(page).height * scale}px`;
        place(page, 0, 0, scale);
      }
    }
  }

  function rollLocation() {
    const slots = Array.from(document.querySelectorAll('.mb-slot'));
    const y = window.scrollY + 1;
    for (const slot of slots) {
      const top = slot.offsetTop;
      if (y < top + slot.offsetHeight) {
        return { spineIndex: +slot.dataset.index, progression: Math.max(0, (y - top) / slot.offsetHeight) };
      }
    }
    return { spineIndex: Math.max(0, slots.length - 1), progression: 1 };
  }

  function scrollToItem(index, fraction) {
    const slot = document.querySelector(`.mb-slot[data-index="${index}"]`);
    if (slot) window.scrollTo(0, slot.offsetTop + (fraction || 0) * slot.offsetHeight);
  }

  function startWrapper() {
    layoutWrapper();
    const media = Array.from(document.querySelectorAll('.mb-page')).filter((page) => page.loading !== 'lazy');
    const loaded = media.map((page) => new Promise((resolve) => {
      if (page.localName === 'img' && page.complete) { resolve(); return; }
      page.addEventListener('load', resolve, { once: true });
      page.addEventListener('error', resolve, { once: true });
    }));
    const timeout = new Promise((resolve) => setTimeout(resolve, 1500));
    Promise.race([Promise.all(loaded), timeout]).then(() => {
      state.ready = true;
      post('ready', { pageCount: 1, rtl: false, wrapper: wrapperKind });
    });
  }

  // ---------------------------------------------------------------------------
  // Lifecycle

  function ensureViewport() {
    if (isFixed() || !document.head || document.querySelector('meta[name="viewport"]')) return;
    const meta = document.createElementNS('http://www.w3.org/1999/xhtml', 'meta');
    meta.setAttribute('name', 'viewport');
    meta.setAttribute('content', 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no');
    document.head.appendChild(meta);
  }

  function start() {
    if (state.ready) return;
    ensureViewport();
    applyStyles();
    const fonts = document.fonts && document.fonts.ready ? document.fonts.ready : Promise.resolve();
    const timeout = new Promise((resolve) => setTimeout(resolve, 400));
    Promise.race([fonts, timeout]).then(() => {
      applyStyles();
      padColumns();
      state.ready = true;
      const info = layoutInfo();
      post('ready', info);
    });
    if (window.ResizeObserver && document.body) {
      new ResizeObserver(() => scheduleRelayout('content')).observe(document.body);
    }
    document.addEventListener('load', (event) => {
      if (event.target && event.target.localName === 'img') scheduleRelayout('image');
    }, true);
    if (document.fonts) document.fonts.addEventListener('loadingdone', () => scheduleRelayout('fonts'));
  }

  if (wrapperKind) {
    window.addEventListener('resize', layoutWrapper);
    window.addEventListener('message', (event) => {
      if (!event.data || event.data.mbFrameTap !== true) return;
      const frame = Array.from(document.querySelectorAll('iframe.mb-page'))
        .find((element) => element.contentWindow === event.source);
      if (!frame) return;
      const rect = frame.getBoundingClientRect();
      post('tap', { x: rect.left + event.data.x * rect.width, y: rect.top + event.data.y * rect.height });
    });
    window.addEventListener('scroll', () => {
      if (wrapperKind !== 'roll') return;
      clearTimeout(state.relocateTimer);
      state.relocateTimer = setTimeout(() => post('relocated', rollLocation()), 120);
    }, { passive: true });
  } else {
    window.addEventListener('scroll', scheduleRelocate, { passive: true });
    window.addEventListener('resize', () => scheduleRelayout('resize'));
    // Native page turns stay out of the way while text is selected.
    let selectionActive = false;
    document.addEventListener('selectionchange', () => {
      const selected = window.getSelection();
      const active = !!selected && !selected.isCollapsed;
      if (active === selectionActive) return;
      selectionActive = active;
      post('selection', { active });
    });
    // Styles go in before first paint; layout starts once the DOM exists.
    applyStyles();
  }
  const begin = () => (wrapperKind ? startWrapper() : start());
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', begin, { once: true });
  } else {
    begin();
  }

  window.MB = Object.freeze({
    configure(config) {
      state.config = Object.assign({}, state.config, config);
      if (wrapperKind) { layoutWrapper(); return { pageCount: 1, rtl: false }; }
      return relayout('configure');
    },
    goToPosition(position) {
      if (!position) return;
      if (typeof position.y === 'number') { window.scrollTo(0, position.y); return; }
      const x = (position.page || 0) * pageWidth();
      window.scrollTo(isRTL() ? -x : x, 0);
    },
    scrollToItem,
    rollLocation,
    layoutInfo,
    positionFor,
    location,
    setHighlights,
    selection,
    clearSelection() { const s = window.getSelection(); if (s) s.removeAllRanges(); },
    /// Whether a tap at (x, y) belongs to the page (a link, control, or highlight) rather than turning it.
    isInteractiveAt(x, y) {
      const element = document.elementFromPoint(x, y);
      if (element && element.closest && element.closest(`a, area, ${INTERACTIVE}`)) return true;
      return !!highlightAt(x, y);
    },
    find,
    speechMark,
    speechClear,
    positionForOffset,
    firstVisibleOffset,
    selectionOffset,
    cfiFor,
    resolveCFI: (cfi) => { const p = resolveCFI(cfi); return p ? cfiFor(p.node, p.offset) : null; },
  });
})();
