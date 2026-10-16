// Exposes navigator.epubReadingSystem (EPUB Reading Systems 3.4, Appendix B) in every frame.
// Native code prepends `const __MB_VERSION__ = "x.y.z";`.
(() => {
  'use strict';
  if (navigator.epubReadingSystem) return;
  const features = new Set([
    'dom-manipulation', 'layout-changes', 'touch-events', 'mouse-events', 'keyboard-events', 'spine-scripting',
  ]);
  const readingSystem = Object.freeze({
    name: 'MB Books',
    version: typeof __MB_VERSION__ === 'string' ? __MB_VERSION__ : '1.0',
    hasFeature(feature, version) {
      if (typeof feature !== 'string') return undefined;
      // Features defined by the specification are versionless; unknown features return undefined.
      return features.has(feature) ? true : undefined;
    },
  });
  try {
    Object.defineProperty(Navigator.prototype, 'epubReadingSystem', {
      get: () => readingSystem, configurable: false, enumerable: true,
    });
  } catch (_) {
    navigator.epubReadingSystem = readingSystem;
  }
})();
