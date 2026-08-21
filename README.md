# BookNexus

A personal book library manager for iPhone and iPad. Catalog by scanning an
ISBN or searching OpenLibrary/Google Books, organize with AI-assisted tags and
shelves, sync your library to iCloud, and keep full control of your data.

> **Status:** active personal project. The app is currently private; this
> repository documents the codebase, build, and feature set.

## Features

- **Catalog your books** — scan a barcode, search OpenLibrary/Google Books, or
  import a result with full metadata and covers (camera or photo library).
- **Organize, not just store** — free-form **tags**, AI-suggested **shelves**
  (Fiction / Non-fiction → library-specific categories), fiction/non-fiction
  classification with human approval.
- **Scan safely** — scans are cached instantly and looked up in the background;
  a crash never loses your place. Duplicate scans are detected by normalized
  ISBN and can be added as another copy.
- **Copies & loans** — the library shows one master per title; every copy's
  detail lists location and loan status.
- **Ask AI** — chat about your library, grounded in a snapshot of your
  collection; works with on-device **Apple Intelligence** or any
  **OpenAI-compatible endpoint** (including self-hosted local models).
- **Privacy-first sync** — optional iCloud synchronization; the rest of your
  data stays on-device or in apps you already trust.
- **Export / import** — backup as a readable zip (books, notes, lists, covers),
  and restore later.

## Building

Requirements: Xcode 26.x, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
and an iOS 17+ simulator or device.

```sh
xcodegen generate          # generate BookNexus.xcodeproj from project.yml
open BookNexus.xcodeproj   # then build & run from Xcode
```

Automated checks (unit + UI tests) run on the booted simulator:

```sh
xcodebuild \
  -project BookNexus.xcodeproj -scheme BookNexus \
  -destination 'platform=iOS Simulator,OS=27.0,name=iPhone 17 Pro' \
  test
```

## AI setup

The AI features need an engine configured in **Settings → AI**:

- **On-device (Apple Intelligence):** available automatically on iOS 26+
  devices with Apple Intelligence enabled.
- **Custom endpoint:** point the app at any OpenAI-compatible `/v1` endpoint
  (hosted or self-hosted, key optional, plain HTTP allowed). A short
  connectivity test and request logs are available in Settings.

## Third-party software

BookNexus uses the following open-source software. We are grateful to their
maintainers:

| Project | Use | License |
| --- | --- | --- |
| [MarkdownUI](https://github.com/gonzalezreal/MarkdownUI) (2.4.1) | Rendering AI chat and changelog content | [MIT](https://github.com/gonzalezreal/MarkdownUI/blob/main/LICENSE) |

Apple frameworks (SwiftUI, SwiftData, Foundation Models, NaturalLanguage) are
governed by Apple's terms.

## Roadmap

See the "Coming in the future" section inside the app's **About** screen. In
short: additional AI providers (multi-model selection), web-search grounding
for Ask AI, streaming chat, and deeper iCloud-synced metadata.

## Versioning

Public/GitHub releases start at **0.1**. Patch-level fixes increment the last
component (`0.1.1`, `0.1.2`, …), new features raise the minor version
(`0.2.0`), and major milestones raise the major version (`1.0`). The current
version is shown in the app under Settings → About & Feedback.

## Feedback

Found a bug or want a feature? Open an issue:

<https://github.com/scottklettke/booknexus/issues/new>

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for every notable change, newest first.
