# Contributing

Open a pull request into `main`. Use a Conventional Commit title because the repository squash merges PRs and uses that title to decide the release version.

| Title | Release |
| --- | --- |
| `fix(reader): restore reading position` | Patch |
| `perf(reader): reduce layout work` | Patch |
| `feat(library): import EPUB files` | Minor |
| `feat!: replace the storage format` | Major |
| `docs: explain importing` | None |
| `ci: update the workflow` | None |

A `BREAKING CHANGE:` footer in the PR body also triggers a major release. Squash merges include the PR body in the commit message. Use `npm run hooks` to enable local commit message validation. Individual branch commits can be cleaned up before merging; CI checks the PR title.

Run these before requesting review:

```sh
npm ci
npm test
python3 -m unittest discover -s scripts -p 'test_*.py'
actionlint
```

On a Mac, `gala test --host local` checks the simulator build. `gala deliver --host local --json` builds, signs, and publishes a private device install. Open the delivered build on a device to check app behavior.

CI builds simulator and device targets. Download the `ios-unsigned` artifact for the IPA, checksum, and build metadata. Successful PR builds also publish a `pr-<number>` prerelease on the Releases page. Open its Autoloader link to sign and install the preview. Previews use the latest stable marketing version; the build number and source commit distinguish them.

After checks pass, squash merge. A release-relevant commit on `main` automatically publishes the next stable release, with the chosen version embedded in the IPA. Release history and changelogs live in GitHub Releases. There are no version-only commits to merge back.

GitHub Actions uses its repository-scoped token. No signing key or personal access token is needed for unsigned IPA releases. Keep certificate and provisioning-profile secrets out of this repository. App Store and TestFlight distribution need a separate signing workflow.
