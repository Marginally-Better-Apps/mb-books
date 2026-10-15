<img src="assets/icon.svg" width="64" height="64" alt="">

# MB Books

A personal EPUB library and reader for iPhone and iPad, modeled on Apple Books without the Book Store. Add books from Files (or open an `.epub` from any app), and read them with Apple Books' themes, typography controls, page turns, highlights, notes, bookmarks, and search.

The app icon is an Icon Composer document (`Books/Resources/AppIcon.icon`) with Liquid Glass layers.

## Features

- **Library:** Home with Continue, Reading Goals (daily minutes, streak, books per year), Want to Read, and Recently Added shelves. Library grid or list, sorting, collections, multi-select editing, book details, and search by title, author, series, subject, or publisher.
- **Reader:** six Apple Books themes (Original, Quiet, Paper, Bold, Calm, Focus) in light and dark, with per-theme customization: font, bold text, line, character, and word spacing, margins, justification, and multiple columns. Slide, Curl, Fast Fade, and Scroll page turns. Font sizes, rotation lock, and keyboard arrows.
- **Annotations:** highlights in five colors or underline, notes, bookmarks, footnote popovers, and full-text search. Highlights use the CSS Custom Highlight API, so the book's DOM is never modified.
- **Settings:** light, dark, or system appearance, reading goals, and a link to this repository.

## EPUB support

The engine targets [EPUB 3.4](https://www.w3.org/TR/epub-34/) and [EPUB Reading Systems 3.4](https://www.w3.org/TR/epub-rs-34/) (W3C Candidate Recommendation), and reads EPUB 3.0–3.3 and EPUB 2 books.

| Area | Support |
| --- | --- |
| Container | ZIP and ZIP64, stored and deflated entries, CRC checks, path traversal protection, unzipped `.epub` folders |
| Package | EPUB 3 `meta`/`refines` metadata, EPUB 2 `opf:` attributes, series (`belongs-to-collection` and Calibre), cover detection, manifest fallbacks |
| Navigation | Navigation document (TOC, page list, landmarks) with NCX fallback |
| Layouts | Reflowable (paginated with CSS columns or scrolled), pre-paginated with synthetic spreads and `page-spread-*`, and 3.4 roll layouts (including legacy `scrolled-continuous`), spine overrides, RTL page progression |
| Media | Everything WebKit plays: video and audio (inline, Picture in Picture, AirPlay), SVG, MathML, AVIF, JPEG XL, WebP, Opus, and AAC |
| Scripting | Scripted content runs with `navigator.epubReadingSystem` (`hasFeature` per Reading Systems 3.4, Appendix B) |
| Fonts | IDPF and Adobe font obfuscation. Other encryption (DRM) is rejected with a clear message. |
| Locations | Reading positions and highlights are stored as EPUB CFIs, so they survive font and layout changes |

Media overlays (read aloud) are parsed from the manifest but not played yet.

## Architecture

- `Books/EPUB`: platform-independent parsing (`ZipArchive`, `MarkupParser`, `EPUBParser`, `NavigationParser`, `FontDeobfuscator`). These types are `nonisolated` and run off the main actor.
- `Books/Library`: import pipeline (`BookImporter` extracts each book to `Application Support/Library/<id>/content`), SwiftData-backed library UI.
- `Books/Reader`: `ReaderModel` (state and annotations), `ReaderViewController` (a single `WKWebView`, page turning, and the JS bridge), and SwiftUI chrome and sheets. `Web/reader.js` paginates and handles locations, highlights, search, and taps in an isolated content world. Fixed layouts load generated wrapper pages that scale each page in an iframe.
- `Books/Models`: SwiftData models (`Book`, `BookCollection`, `Annotation`, `ReadingDay`) and `Locator`.

Requires Xcode 26 and iOS 26 or newer. The project has no third-party dependencies. `project.yml` is the source of truth for project settings. Run `xcodegen generate` after changing it. Open `MBBooks.xcodeproj` and run the shared `MBBooks` scheme. For direct device runs in Xcode, select your development team and enable signing in your local build settings.

## Testing

`ios-test.sh` runs the XCTest suites on the newest available iPhone simulator. Set `MB_TEST_DESTINATION` to choose another one.

- `BooksTests`: unit tests for ZIP, parsing, EPUB 2/3/3.4 layouts, fallbacks, DRM detection, font deobfuscation, import, deduplication, search offsets, spreads, progress, reading streaks, and preferences.
- `BooksUITests/LibraryFlowTests`: opens a generated EPUB 3.4 book, pages across chapters, follows nested TOC links, switches themes, bookmarks, reopens at the saved position, and checks Settings.
- `BooksUITests/ScreenshotTour`: a development aid, skipped by default. Run it with `TEST_RUNNER_MB_TOUR_OUTPUT=/tmp/shots` (and optionally `TEST_RUNNER_MB_TOUR_DIR=<folder of .epub files>`) to screenshot every book and the reader sheets.

For manual testing, launch the app with `-import-directory <folder>` to import every EPUB in a folder at startup. UI tests use `-ui-testing -seed-sample-book` for an isolated, in-memory library.

## Gala delivery

Gala Engine provides private device delivery and signing:

```sh
gala doctor --host local
gala test --host local
gala deliver --host local --json
```

`ios-build.sh` builds an unsigned device IPA under `GALA_ARTIFACT_DIR`, which Gala signs and publishes. Both recipes keep build output under `GALA_BUILD_DIR`. On a Linux client, omit `--host local` to use the configured Mac worker.

The bundle ID is `com.mbbooks.MBBooks`. Keep it stable so future deliveries update the same app. Generated Gala logs and artifacts are ignored under `.gala/`.

## CI and releases

GitHub Actions (macOS 26, Xcode 26.5) checks Conventional Commit PR titles, release tooling, workflow syntax, reader script syntax, and generated project consistency, and runs the unit and UI tests on a simulator. It also builds and validates an unsigned iPhone/iPad IPA, including its reader scripts, EPUB document type, and icon. Each run stores the IPA, SHA-256 checksum, and build metadata in an `ios-unsigned` artifact for 14 days.

Successful PR builds publish a public `pr-<number>` prerelease with an Autoloader install link. The publisher uses default-branch code and never executes PR code with a write token. Superseded PR builds are skipped. Preview assets are replaced on the next successful build.

Merges to `main` use semantic-release to choose the next version and publish a GitHub Release with notes, an unsigned IPA, checksum, metadata, and an Autoloader link. `fix:` and `perf:` bump the patch version, `feat:` bumps the minor version, and `!` or a `BREAKING CHANGE:` footer bumps the major version. Documentation, refactoring, dependency, and CI-only changes do not publish a release unless marked as breaking. Release tags are the version source of truth. Builds inject the version into `CFBundleShortVersionString`; GitHub's run number becomes `CFBundleVersion`. Gala applies its own increasing build number when signing.

The bootstrap tag is `v0.1.0`. For local builds, the newest stable version tag supplies the marketing version. To override it, pass `APP_VERSION=0.2.0 APP_BUILD_NUMBER=42` to the build recipe. The value in `project.yml` is the initial Xcode fallback, not the published release version.

Autoloader requires a public GitHub Release asset. Actions artifact pages cannot be used as install URLs. Release IPAs are unsigned and need Autoloader signing; Gala remains the private signed delivery path. App Store/TestFlight signing is not configured.

Node 24.10 or newer is needed for release tooling. Run `npm ci`, `npm test`, and `npm run hooks` to enable the optional local Conventional Commit hook. Tooling dependencies are locked, workflow actions are pinned to commits, and Dependabot checks both weekly.
