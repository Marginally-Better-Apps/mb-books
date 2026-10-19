import js from '@eslint/js';
import globals from 'globals';

export default [
  js.configs.recommended,
  {
    // Injected into book pages by the reader. Native code supplies __MB_CONFIG__ and __MB_VERSION__.
    files: ['Books/Reader/Web/**/*.js'],
    languageOptions: {
      ecmaVersion: 2024,
      sourceType: 'script',
      globals: { ...globals.browser, __MB_CONFIG__: 'readonly', __MB_VERSION__: 'readonly' },
    },
  },
  {
    files: ['scripts/**/*.cjs'],
    languageOptions: { ecmaVersion: 2024, sourceType: 'commonjs', globals: globals.node },
  },
  {
    rules: {
      'no-unused-vars': ['error', { caughtErrors: 'none', argsIgnorePattern: '^_' }],
    },
  },
  { ignores: ['node_modules/', '.ci-build/', 'scripts/pocket-tts/'] },
];
