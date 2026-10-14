const { execFileSync } = require('node:child_process');
const { installNotes } = require('./install-links.cjs');
module.exports = {
  generateNotes(_config, context) {
    return installNotes(process.env.GITHUB_REPOSITORY, context.nextRelease.gitTag);
  },
  prepare(_config, context) {
    const version = context.nextRelease.version;
    if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error('Expected a stable semantic version');
    execFileSync('bash', ['ios-build.sh'], {
      stdio: 'inherit', env: { ...process.env, APP_VERSION: version },
    });
  },
};
