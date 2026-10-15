// Forwards taps inside fixed-layout iframes to the wrapper page, which maps them to reader coordinates.
// File URLs are separate origins, so frames talk to the wrapper with postMessage.
(() => {
  'use strict';
  if (window === window.top) return;

  const INTERACTIVE = 'a[href], area[href], video, audio, button, input, select, textarea, label, summary, ' +
    'details, iframe, object, embed, [onclick], [contenteditable], [role="button"], [tabindex]';

  document.addEventListener('click', (event) => {
    const target = event.target && event.target.nodeType === Node.ELEMENT_NODE ? event.target : null;
    if (target && target.closest(INTERACTIVE)) return;
    const { clientX, clientY } = event;
    setTimeout(() => {
      if (event.defaultPrevented) return;
      window.parent.postMessage({
        mbFrameTap: true,
        x: clientX / Math.max(1, window.innerWidth),
        y: clientY / Math.max(1, window.innerHeight),
      }, '*');
    }, 0);
  });
})();
