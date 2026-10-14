<img src="assets/icon.svg" width="64" height="64" alt="">

# MB Books

SwiftUI workspace for an iPhone and iPad EPUB reader. This initial setup contains only a placeholder screen. EPUB import, reading, themes, and customization are not implemented yet.

Requires Xcode 16 or newer, XcodeGen, and iOS 18 or newer. The project has no third-party dependencies.

Open `MBBooks.xcodeproj` and run the shared `MBBooks` scheme on a simulator. `project.yml` is the source of truth for project settings. Run `xcodegen generate` after changing it. For direct device runs in Xcode, select your development team and enable signing in your local build settings.

Gala Engine provides private device delivery and signing:

```sh
gala doctor --host local
gala test --host local
gala deliver --host local --json
```

`ios-test.sh` compiles the simulator app and checks its bundle identity. It does not run UI or behavior tests. `ios-build.sh` builds an unsigned device IPA under `GALA_ARTIFACT_DIR`, which Gala signs and publishes. Both recipes keep build output under `GALA_BUILD_DIR`. On a Linux client, omit `--host local` to use the configured Mac worker.

The bundle ID is `com.mbbooks.MBBooks`. Keep it stable so future deliveries update the same app. Generated Gala logs and artifacts are ignored under `.gala/`.

## CI and releases

GitHub Actions checks Conventional Commit PR titles, release tooling, workflow syntax, generated project consistency, and the simulator build. It also builds and validates an unsigned iPhone/iPad IPA. Each run stores the IPA, SHA-256 checksum, and build metadata in an `ios-unsigned` artifact for 14 days.

Successful PR builds publish a public `pr-<number>` prerelease with an Autoloader install link. The publisher uses default-branch code and never executes PR code with a write token. Superseded PR builds are skipped. Preview assets are replaced on the next successful build.

Merges to `main` use semantic-release to choose the next version and publish a GitHub Release with notes, an unsigned IPA, checksum, metadata, and an Autoloader link. `fix:` and `perf:` bump the patch version, `feat:` bumps the minor version, and `!` or a `BREAKING CHANGE:` footer bumps the major version. Documentation, refactoring, dependency, and CI-only changes do not publish a release unless marked as breaking. Release tags are the version source of truth. Builds inject the version into `CFBundleShortVersionString`; GitHub's run number becomes `CFBundleVersion`. Gala applies its own increasing build number when signing.

The bootstrap tag is `v0.1.0`. For local builds, the newest stable version tag supplies the marketing version. To override it, pass `APP_VERSION=0.2.0 APP_BUILD_NUMBER=42` to the build recipe. The value in `project.yml` is the initial Xcode fallback, not the published release version.

Autoloader requires a public GitHub Release asset. Actions artifact pages cannot be used as install URLs. Release IPAs are unsigned and need Autoloader signing; Gala remains the private signed delivery path. App Store/TestFlight signing is not configured.

Node 24.10 or newer is needed for release tooling. Run `npm ci`, `npm test`, and `npm run hooks` to enable the optional local Conventional Commit hook. Tooling dependencies are locked, workflow actions are pinned to commits, and Dependabot checks both weekly.
