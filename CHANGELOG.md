# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add user-visible changes under the `[Unreleased]` heading below as you work.
On the next `npm run release:*`, `increment_version.js` promotes `[Unreleased]`
to a dated `[X.Y.Z]` section and inserts a fresh empty `[Unreleased]` above it
along with the comparison links — do not edit the heading or the links by hand.

## [Unreleased]

### Added
- The configuration page now shows the contents of the selected import profile: its options, the record matching rule (match points, required checks, threshold) and the MARC modification template actions.

## [0.1.2] - 2026-10-13

## [0.1.1] - 2026-10-13

### Added
- Initial plugin: nightly fetch of changed bibliographic records from the Libris MARC21 export API, staged as a normal Koha import batch (using an import profile's matcher, overlay, no-match and item actions) with optional auto-commit.
- Deleted-record handling (`ignore`, `log`, or `delete` when the Koha record has no items), driven by the `deleted=append` ID list and matched on field 001.
- Run history and "Run now" on the tool page; the fetch window only advances after a successful staging run.
