function installLinks(repository, tag, filename = 'MBBooks-unsigned.ipa') {
  const ipa = `https://github.com/${repository}/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(filename)}`;
  const encoded = encodeURIComponent(ipa);
  return { ipa, autoloader: `autoloader://install?url=${encoded}`,
    web: `https://marginally-better-apps.github.io/Autoloader/?url=${encoded}` };
}
function installNotes(repository, tag) {
  const links = installLinks(repository, tag);
  return `### Install on iPhone or iPad\n\n[Open in Autoloader](${links.web}) · [Download IPA](${links.ipa})\n\nThe IPA is unsigned. Autoloader signs it on your device. For private development installs, use Gala Engine.\n`;
}
module.exports = { installLinks, installNotes };
