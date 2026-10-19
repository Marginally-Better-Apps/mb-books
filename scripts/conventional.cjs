const fs = require('node:fs');
const pattern = /^(feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert)(\([a-zA-Z0-9_./-]+\))?!?: \S.*$/;
function valid(message) {
  return pattern.test(message.split(/\r?\n/)[0]);
}
module.exports = { valid };
if (require.main === module) {
  const message = process.argv[2] === '--file'
    ? fs.readFileSync(process.argv[3], 'utf8') : process.env.PR_TITLE || '';
  if (!valid(message)) {
    console.error('Use a Conventional Commit title, such as feat(reader): add EPUB import or fix: restore reading position.');
    process.exit(1);
  }
}
