module.exports = {
  branches: ['main'],
  tagFormat: 'v${version}',
  plugins: [
    ['@semantic-release/commit-analyzer', { preset: 'conventionalcommits' }],
    ['@semantic-release/release-notes-generator', { preset: 'conventionalcommits' }],
    './scripts/release-plugin.cjs',
    ['@semantic-release/github', {
      assets: ['artifacts/*.ipa', 'artifacts/*.sha256', 'artifacts/build-info.json'],
      successComment: false,
      failComment: false,
      failTitle: false,
      releasedLabels: false,
    }],
  ],
};
