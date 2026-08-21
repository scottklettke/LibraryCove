# Changelog

All notable changes to BookNexus are tracked here, newest first. This file is
intended to be updated with every meaningful change. Versioning follows the
scheme documented in the README: the earliest release is **0.1**; patch-level
fixes increment the last component (0.1.1, 0.1.2, …), new features raise the
minor version (0.2, 0.3, …), and major milestones raise the major version (1.0).

## [Unreleased]

### Added
- **Manual shelves and bulk tagging** (no AI): long-press any grid book to
  assign/edit shelves, edit tags, or delete; a **Select** mode in the grid
  enables bulk-editing tags/shelves or deleting many books at once. Assignment
  uses searchable multi-select sheets that can create new tags/shelves inline,
  and books can be grouped by shelf manually.
- **Re-versioning** of the release history: the earliest release is now 0.1 and
  each subsequent release group increments from there; the current release is
  **0.4** (shown in About).
- Author and Tag filter search fields got a clear (**X**) button to reset them.

### Changed
- **Removed the AI Tools menu** (clean-up tags / reorganize shelves /
  classify) as an in-app entry point; the underlying AI services remain in the
  codebase for a future return.

### Fixed
- **"Date added" showing 12/31/00** for recently added books: new books are now
  stamped with the real add date, and books created earlier with the unset
  (2001-01-01) sentinel are restored to a real date on launch.

## [0.4] — 2026-08-20

### Added
- Searchable **multi-select Author and Tag filters** (search field, selected
  items grouped at the top, clear button, "All" row, live filtering with
  removable chips).
- AI connection log is now **newest-first**.
- Ask AI chat shows a brief **chain-of-thought preview** (2–3 lines) that
  disappears once the reply renders (endpoints that expose reasoning only).
- **Master-copy listing:** the main grid/list shows one master per ISBN with an
  "N copies" badge; a book's detail page lists all copies with location, loan
  status, and per-copy navigation.
- **"Classify fiction / non-fiction"** AI tool: proposes labels for unclassified
  books with a review-and-approve list (never overwrites a manual label).
- **Fiction / Non-fiction field** on books: set when adding/editing, shown on
  the detail page, proposed by the AI shelf pass.
- **Two-tier shelf organization:** Group by tags shows Fiction / Non-fiction /
  Uncategorized top groups, each containing the AI-proposed shelves, with a
  single "Other" bucket.
- "Reorganize shelves" previews the two-tier layout, explains what shelves are,
  and proposes fiction/non-fiction labels per book. All AI sheets show live
  progress steps and outcome summaries.

### Changed
- "Genre" renamed to **"Tags"** throughout the app UI and Swift API (the
  underlying persistent field keeps its legacy name for CloudKit compatibility;
  exports use `tags`, imports accept both keys).
- AI requests run on a generous-timeout transport (previously `URLSession`
  default 60s aborted long local-model requests).
- Apple Intelligence successes no longer log a stale auto-discovered OpenAI
  model name.

### Fixed
- Catalog lookups are time-boxed so they never hang a scan; the background scan
  queue actually processes (a startup flag-ordering bug left scans "looking up"
  forever).
- Scanned duplicates can be added as an **additional copy** (the duplicate alert
  now offers it); duplicate alerts name the existing book.
- Duplicate "Other" shelves and the import-pager duplicate delete button.

## [0.3] — 2026-08-17

### Added
- **Ask AI** chat: grounded recommendations and answers, conversation memory,
  context-aware suggestion chips, Markdown rendering.
- **AI genre cleanup** ("Clean up tags") and **description improvement**.
- On-device **Apple Intelligence engine** (Foundation Models) and an
  SDK-agnostic AI layer with an **OpenAI-compatible provider** (keyless,
  plain-HTTP friendly, model discovery via `GET /v1/models`).
- OpenAI-compatible endpoint as the AI connection, plus a request/connection
  log in Settings.
- Retrieval-first AI context that sizes requests to the model's context window.

## [0.2] — 2026-08-13

### Added
- **Catalog scanning & import:** scan an ISBN, rescan with an in-library check,
  swipe-to-browse imported books, pending-scan resume.
- Optional **iCloud (CloudKit) sync** with pluggable store providers.
- Cover sync via the CloudKit record; cover crop tool; multiple cover options.
- **Export/import** (zip) with filesystem cover storage, import/delete options.
- Search by added-by member; editable library name; added-by attribution.
- Duplicate-ISBN detection (normalized digits-only) with add/delete-duplicate
  options.

### Fixed
- Cover rendering, the crop tool, the "cover never mutated" save warning,
  CloudKit startup errors (information property list), search result handling.

## [0.1] — 2026-08-12

### Added
- Library with cover grid, list, by-location, and dashboard views; author/genre
  grouping; date-added sorting; empty-state add.
- **Add Books** flow with OpenLibrary/Google search, ISBN scanning, camera and
  photo cover capture, book editing with delete.
- Import wizards with a remaining-count swipe hint and duplicate guards.
- Search history; multiple cover options.

### Fixed
- Crash when importing selected search results; stale-book display across the
  import pager; lingering search views after import/delete.
