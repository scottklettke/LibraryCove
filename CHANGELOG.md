# Changelog

Notable user-facing changes are described in release notes when LibraryCove
ships via TestFlight. Until then this file is not maintained.

## Unreleased

### Changed

- The app is renamed **LibraryCove** (bundle id `com.librarycove.app`, CloudKit
  container `iCloud.com.librarycove.app`). Exports still use the same
  `library.json` format; archives written by older BookNexus builds
  (`booknexus-library` format marker) import unchanged.

### Added

- Catalog lookups now capture the Open Library **work key** and store it on the
  book (`olKey`). "Fetch description" uses it to read the description directly
  from the correct work record — deterministic, no fuzzy title/author matching —
  and description pickers prefer it for their Open Library candidate. The key
  travels with exports and shared libraries, and backfills on later lookups.
- Catalog network requests identify themselves to Open Library with a
  descriptive User-Agent per its API etiquette.

### Attribution

- Added a "Data sources" section to About & Feedback crediting Open Library
  (CC0 bibliographic data), Google Books, and Wikipedia (CC BY-SA). A
  courtesy note covers Cindy's Books, an independently developed app
  discovered near release whose work-key storage idea informed the
  deterministic description fetches above; all code is original.
