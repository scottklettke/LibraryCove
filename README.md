# LibraryCove

A personal book library manager for iPhone and iPad. Catalog your shelf by
scanning an ISBN barcode or searching Open Library / Google Books, organize it
the way you think with tags, shelves, and AI assistance, and keep full control
of your data — on-device, in iCloud, or in exports you can read by hand.

> **Status:** active personal project. The app is currently private; this
> repository documents the codebase, build, and feature set — it doubles as
> the project website for now. Screenshots coming soon.

<!-- Screenshots: paste a table here once captured.
| Library | Book detail | Ask AI |
|---|---|---|
| <img src="docs/screenshots/library.png" width="200"> | ... | ... |
-->

## Features

- **Catalog your books** — scan a barcode (camera or photo library), search
  Open Library and Google Books, or add books by hand. Each lookup brings full
  metadata and multiple cover candidates.
- **Deterministic descriptions** — every catalog capture stores its Open
  Library *work key*, so "Fetch description" reads directly from the correct
  work record instead of guessing by title. Descriptions can come from Open
  Library, Wikipedia, or Google Books — pick your favorite from the
  description picker, or import one from the web with an in-app browser
  (source attributed automatically).
- **Organize, not just store** — free-form **tags**, AI-suggested **shelves**
  (Fiction / Non-fiction → library-specific categories), and
  fiction/non-fiction classification with human approval.
- **Scan safely** — scans are cached instantly and looked up in the background;
  a crash never loses your place. Duplicate scans are detected by normalized
  ISBN (10- and 13-digit forms match) and can be added as another copy.
- **Copies & loans** — the library shows one master per title; every copy's
  detail lists its physical location and loan status.
- **Notes & reading lists** — attach notes to books and track reading lists,
  all synced.
- **Ask AI** — chat about your library, grounded in a snapshot of your
  collection; works with on-device **Apple Intelligence** or any
  **OpenAI-compatible endpoint** (including self-hosted local models).
- **Privacy-first sync** — optional private iCloud (SwiftData + CloudKit)
  sync of your own devices, plus Notes-style **shared libraries**: invite
  family members to a shared shelf via link, with membership management and
  server-wins merging. The rest of your data stays on-device.
- **Export / import** — backup as a readable zip (`library.json`, cover
  JPEGs, a format guide), edit it by hand if you like, and restore later.
  Archives from the app's predecessor (BookNexus, `booknexus-library` format)
  import unchanged.

## Building

Requirements: Xcode 26.x, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
and an iOS 17+ simulator or device.

```sh
xcodegen generate            # generate LibraryCove.xcodeproj from project.yml
open LibraryCove.xcodeproj   # then build & run from Xcode
```

Automated checks (unit + UI tests) run on the booted simulator:

```sh
xcodebuild \
  -project LibraryCove.xcodeproj -scheme LibraryCove \
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

## Data sources & attribution

LibraryCove stands on the shoulders of open catalog data:

- **Open Library** (openlibrary.org) — book metadata, work records, and cover
  images. Bibliographic data is dedicated to the public domain (CC0); cover
  images carry the rights of their original sources.
- **Google Books** (books.google.com) — supplementary metadata, descriptions,
  and covers.
- **Wikipedia** (wikipedia.org) — description extracts, available under the
  Creative Commons Attribution-ShareAlike License.
- **Cindy's Books** (github.com/brainchillz/CindysBooks-IOS) — a kindred
  offline library app whose work-key approach inspired LibraryCove's
  deterministic Open Library description fetches.

Open-source software used by the app:

| Project | Use | License |
| --- | --- | --- |
| [MarkdownUI](https://github.com/gonzalezreal/MarkdownUI) (2.4.1) | Rendering AI chat and changelog content | [MIT](https://github.com/gonzalezreal/MarkdownUI/blob/main/LICENSE) |

Apple frameworks (SwiftUI, SwiftData, Foundation Models, NaturalLanguage) are
governed by Apple's terms. The same attributions are shown in-app under
**Settings → About & Feedback → Data sources**.

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

<https://github.com/aoeu10/LibraryCove/issues/new>

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for every notable change, newest first.
