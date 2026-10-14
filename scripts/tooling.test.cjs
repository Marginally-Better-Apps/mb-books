const { test } = require('node:test');
const assert = require('node:assert/strict');
const { valid } = require('./conventional.cjs');
const { installLinks } = require('./install-links.cjs');

test('Conventional Commit validation accepts release-relevant messages and rejects malformed titles', () => {
  for (const message of ['feat(reader): import EPUB', 'fix: resume reading', 'feat!: change storage', 'chore(deps): update tooling']) {
    assert.equal(valid(message), true, message);
  }
  for (const message of ['Update stuff', 'feat: ', 'feature: import', 'feat(reader) import']) {
    assert.equal(valid(message), false, message);
  }
});

test('Autoloader query values round-trip to a public release asset', () => {
  const links = installLinks('Marginally-Better-Apps/mb-books', 'pr-12');
  assert.equal(new URL(links.web).searchParams.get('url'), links.ipa);
  assert.equal(new URL(links.autoloader).searchParams.get('url'), links.ipa);
  assert.match(links.ipa, /releases\/download\/pr-12\/MBBooks-unsigned\.ipa$/);
});

test('Conventional Commits map to semantic version bumps', async () => {
  const { analyzeCommits } = await import('@semantic-release/commit-analyzer');
  const context = (message) => ({ commits: [{ hash: 'abc', message }], cwd: process.cwd(), logger: { log() {} } });
  for (const [message, expected] of [
    ['fix: resume reading', 'patch'], ['feat: import EPUB', 'minor'],
    ['feat!: change storage', 'major'], ['refactor: storage\n\nBREAKING CHANGE: old data is incompatible', 'major'],
    ['docs: update readme', null], ['ci: update workflow', null],
  ]) {
    assert.equal(await analyzeCommits({ preset: 'conventionalcommits' }, context(message)), expected, message);
  }
});
