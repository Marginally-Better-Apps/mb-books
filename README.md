<img src="assets/icon.svg" width="64" height="64" alt="">

# MB Books

A personal EPUB library and reader for iPhone and iPad, modeled on Apple Books without the Book Store. Add books from Files (or open an `.epub` from any app), and read them with Apple Books' themes, typography controls, page turns, highlights, notes, bookmarks, and search.

The app icon is an Icon Composer document (`Books/Resources/AppIcon.icon`) with Liquid Glass layers.

## Features

- **Library:** Home with Continue, Reading Goals (daily minutes, streak, books per year), Want to Read, and Recently Added shelves. Library grid or list, sorting, collections, multi-select editing, book details, and search by title, author, series, subject, or publisher.
- **Reader:** six Apple Books themes (Original, Quiet, Paper, Bold, Calm, Focus) in light and dark, with per-theme customization: font, bold text, line, character, and word spacing, margins, justification, and multiple columns. Slide, Curl, Fast Fade, and Scroll page turns that follow your finger, with neighboring chapters preloaded so turning between them is instant. Font sizes, rotation lock, and keyboard arrows.
- **Annotations:** highlights in five colors or underline, notes, bookmarks, footnote popovers, and full-text search. Highlights use the CSS Custom Highlight API, so the book's DOM is never modified.
- **Settings:** light, dark, or system appearance, reading goals, and a link to this repository.

## Listening

Tap the headphones in the reader (or choose **Listen from Here** on a selection) to have the book read aloud from the page on screen. The sentence being read is highlighted, the page turns along with it, and turning pages by hand stops following until you tap **Return to Narration**. Listening continues with the screen locked and works with headphone and Lock Screen controls.

One voice list holds two kinds of voices, each with a sample button:

- **Natural voices** are Kyutai's [Pocket TTS](https://huggingface.co/kyutai/pocket-tts) (english_2026-09), run with Core ML a few sentences ahead of the listener: the transformer on the GPU, the audio decoder on the CPU, overlapping frame by frame. A few of the model's attention heads follow the text as it's spoken, which times each word, so the highlight moves word by word with the voice (about 50 ms from Whisper's word timings). The 152 MB download (models and 17 voices) happens once; samples are bundled, so voices can be heard first. On an M2 it renders about 7× faster than real time. They read English books.
- **Apple voices** (`AVSpeechSynthesizer`) need no download and read every language. Enhanced and Premium voices from Settings › Accessibility › Spoken Content appear when installed.

Choosing a voice never starts playback: a playing book switches voices at the current sentence, and a paused one stays paused.

Nothing you read leaves the device. Every component is permissively licensed (Apache 2.0 or MIT, see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)); espeak-ng, which is GPL, is deliberately not used.

### What gets read

`SpeechExtractor` decides what is the book. It uses the publisher's semantics first, then heuristics:

| Left out | How it's recognized |
| --- | --- |
| Cover, title page, copyright page, table of contents, index, endnotes, bibliography, colophon | `epub:type` and ARIA roles on the document, nav landmarks or EPUB 2 `<guide>` types, `linear="no"`; otherwise heuristics (mostly links, rights and ISBN text, index-style lines, only the title and author) |
| Print page numbers | `pagebreak` and `doc-pagebreak`, common page-number classes and IDs, and paragraphs that are only a number |
| Note markers and notes | `noteref`, short linked markers like `12`, `*`, or `[3]`, superscript markers, `footnote` and `endnote` asides, the notes they point to, and trailing "Notes" sections |
| Running heads | Short lines repeated through a chapter that name the book or author |
| Hidden or duplicated text | `hidden`, `aria-hidden`, inline and stylesheet `display: none`, pull quotes, ruby annotations |
| Tables of contents inside chapters | Blocks that are mostly links, and "Contents" headings |
| Illustrations and their captions | `figure`, `role="figure"`, figure and caption classes, and short blocks around an image |
| Code listings | `<pre>` and code-listing blocks; inline code stays in its sentence |
| Project Gutenberg license text and transcriber's notes | The `*** START`/`*** END` markers, license documents, eBook-number lines, and transcriber-note classes |

Headings get longer pauses and read "Chapter IV" as "Chapter 4"; scene-break ornaments become pauses; soft hyphens, ligatures, URL paths, and inline markers like `¹` are cleaned up; language changes inside a paragraph switch voices. Pages that are only images (scans and image-based fixed layouts) are read with on-device OCR (Vision), which drops folios and running heads in the margins, orders two-column pages, and rejoins words hyphenated across lines.

**What's Read Aloud** in the Listen options lists every document, why it's read or skipped, and what was left out of it, with switches to override the choices per book.

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

Media overlays (publisher narration) are parsed from the manifest but not played yet; see Listening for generated narration.

## Architecture

- `Books/EPUB`: platform-independent parsing (`ZipArchive`, `MarkupParser`, `EPUBParser`, `NavigationParser`, `FontDeobfuscator`). These types are `nonisolated` and run off the main actor.
- `Books/Library`: import pipeline (`BookImporter` extracts each book to `Application Support/Library/<id>/content`), SwiftData-backed library UI.
- `Books/Reader`: `ReaderModel` (state and annotations), `ReaderViewController` (loading, the JS bridge, and chapter preloading across a few `ChapterView` web views), page-turn presenters in `PageTurn.swift` and `CurlPagePresenter.swift`, and SwiftUI chrome and sheets. `Web/reader.js` paginates and handles locations, highlights, search, and taps in an isolated content world. Fixed layouts load generated wrapper pages that scale each page in an iframe.
- `Books/Models`: SwiftData models (`Book`, `BookCollection`, `Annotation`, `ReadingDay`) and `Locator`.

- `Books/Speech`: read aloud. `SpeechExtractor` and `ScanReader` turn documents into utterances with text offsets that `reader.js` highlights; `ListeningSession` drives an Apple-voice or natural-voice backend and follows along in the reader. `Neural/` holds the Pocket TTS runner, its tokenizer, the English text normalizer, and the model download store. `scripts/pocket-tts` converts the model to Core ML and renders the bundled samples.

Requires Xcode 26 and iOS 26 or newer. There are no third-party code dependencies. `project.yml` is the source of truth for project settings. Run `xcodegen generate` after changing it. Open `MBBooks.xcodeproj` and run the shared `MBBooks` scheme. For direct device runs in Xcode, select your development team and enable signing in your local build settings.

## Testing

`ios-test.sh` runs the XCTest suites on the newest available iPhone simulator. Set `MB_TEST_DESTINATION` to choose another one.

- `BooksTests`: unit tests for ZIP, parsing, EPUB 2/3/3.4 layouts, fallbacks, DRM detection, font deobfuscation, import, deduplication, search offsets, spreads, progress, reading streaks, and preferences.
- `BooksTests/SpeechTests`: content extraction (page numbers, notes, front matter, hidden text, running heads), text offsets matching the reader, OCR layout, the Pocket TTS tokenizer (checked against Hugging Face `tokenizers`), number reading, and audiobook storage. `PocketIntegrationTests` renders real speech when `TEST_RUNNER_MB_VOICE_MODEL_DIR` points at a folder with the installed models (`FlowLM.mlmodelc`, `Mimi.mlmodelc`, and `voices/*.bin`).
- `BooksUITests/LibraryFlowTests`: opens a generated EPUB 3.4 book, pages across chapters, follows nested TOC links, switches themes, bookmarks, reopens at the saved position, and checks Settings.
- `BooksUITests/ScreenshotTour`: a development aid, skipped by default. Run it with `TEST_RUNNER_MB_TOUR_OUTPUT=/tmp/shots` (and optionally `TEST_RUNNER_MB_TOUR_DIR=<folder of .epub files>`) to screenshot every book and the reader sheets. `testNaturalVoiceTour` also needs `TEST_RUNNER_MB_VOICE_MODEL_DIR` (a folder with `FlowLM.mlmodelc`, `Mimi.mlmodelc`, and `voices/*.bin`) and points the app at that model in Debug builds. `testListenToImportedBooks` listens to the books in `TEST_RUNNER_MB_LISTEN_DIR`, and `SpeechReportTests` writes what would be read from them to `TEST_RUNNER_MB_SPEECH_REPORT`.

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
