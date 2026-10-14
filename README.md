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
