# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add user-visible changes under the `[Unreleased]` heading below as you work.
On the next `npm run release:*`, `increment_version.js` promotes `[Unreleased]`
to a dated `[X.Y.Z]` section and inserts a fresh empty `[Unreleased]` above it
along with the comparison links — do not edit the heading or the links by hand.

## [Unreleased]

## [0.3.3] - 2026-11-05

### Fixed

- A run where nothing had changed in Libris failed with "Libris returned data but no valid MARC records could be read from it". Libris answers with an empty `<collection>` rather than an empty body, which was mistaken for data. It is now a successful run with no batch.
- When MARC parsing does fail, the error now includes Koha's parse errors.

## [0.3.2] - 2026-11-05

## [0.3.1] - 2026-11-05

### Fixed

- The background job's detail page in Koha returned a 500 because the plugin supplied no template for its job type. It now shows the run's outcome, window, record counts and batch link.

## [0.3.0] - 2026-11-05

### Changed

- "Run now" queues a Koha background job instead of running in the web request, so a large export no longer hits the browser or proxy timeout. The tool page links to the job and shows the result under Recent runs when it finishes. This needs the Koha worker (`koha-worker`) to be running.
- Only one export can run at a time. "Run now" is disabled while a job is queued or running, and a second run (including the nightly cron) is logged as `skipped` rather than fetching the same window twice.

### Fixed

- Every export request was rejected by Libris with `400 Bad Request` because the colons in the `from`/`until` timestamps were sent percent-encoded (`%3A`). They are now sent literally.

## [0.2.3] - 2026-11-05

## [0.2.2] - 2026-11-05

### Fixed

- A first-run start date entered as a bare date (`2026-11-04`) made Libris reject the export with `400 Bad Request`. Bare dates are now sent as midnight UTC.

### Changed

- A failed export now reports the time window requested and the explanation Libris returned, not just the HTTP status.

## [0.2.1] - 2026-11-05

### Changed

- Adopt the plugin template's CI and release tooling: `npm run release:*` scripts and preflight, `DEVELOPMENT.md`, a `t/00-load.t` smoke test and the GitHub Actions workflow (already current/customised, left as is).

- Relicensed under AGPL-3.0-or-later: added `LICENSE`, SPDX header, and `license`/`license_url` plugin metadata (the licence is also stated in the description, which is what Koha displays).

## [0.2.0] - 2026-10-14

### Added
- The configuration page now shows the contents of the selected import profile: its options, the record matching rule (match points, required checks, threshold) and the MARC modification template actions.

## [0.1.2] - 2026-10-13

## [0.1.1] - 2026-10-13

### Added
- Initial plugin: nightly fetch of changed bibliographic records from the Libris MARC21 export API, staged as a normal Koha import batch (using an import profile's matcher, overlay, no-match and item actions) with optional auto-commit.
- Deleted-record handling (`ignore`, `log`, or `delete` when the Koha record has no items), driven by the `deleted=append` ID list and matched on field 001.
- Run history and "Run now" on the tool page; the fetch window only advances after a successful staging run.

[Unreleased]: https://github.com/openfifth/koha-plugin-libris-catalogue-import/compare/v0.3.3...HEAD
[0.3.3]: https://github.com/openfifth/koha-plugin-libris-catalogue-import/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/openfifth/koha-plugin-libris-catalogue-import/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/openfifth/koha-plugin-libris-catalogue-import/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/openfifth/koha-plugin-libris-catalogue-import/compare/v0.2.3...v0.3.0
[0.2.3]: https://github.com/openfifth/koha-plugin-libris-catalogue-import/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/openfifth/koha-plugin-libris-catalogue-import/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/openfifth/koha-plugin-libris-catalogue-import/compare/v0.2.0...v0.2.1