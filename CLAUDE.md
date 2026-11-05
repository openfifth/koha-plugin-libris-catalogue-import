# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Koha plugin (`Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport`) that nightly pulls changed bibliographic records from the Libris (National Library of Sweden) MARC21 export API and stages them as a normal Koha import batch, so the user's import profile (matching rule, overlay/no-match/item actions, MARC modification template) applies. Catalogue records only. The README covers setup and behaviour from a user's perspective.

## Commands

The Perl tests need a Koha environment (they use `Koha::*`, `C4::*`, `t::lib::TestBuilder`, and a DB), so run them inside a KTD container, not on the host. The plugin directory must be mounted as a KTD plugin (CI uses `ktd --plugins`; the plugin lives at `/kohadevbox/plugins/<repo>`).

```bash
# inside KTD, from the plugin dir
export KOHA_PLUGIN_DIR=$(pwd) PERL5LIB=$PERL5LIB:.
prove -v t/                    # all tests
prove -v t/04-profile-summary.t  # one test file
```

`t/01-export.t` and `t/04-profile-summary.t` test pure helpers; `t/02-run-export.t`, `t/03-settings.t` need the DB. From this workspace, `kd shell <feature>` / `ktd --name "${KTD_INSTANCE:-kohadev}" --shell` gets you in (see parent `AGENTS.md`).

Release (maintainer only, pushes to origin): `npm run release:{patch,minor,major}`. It checks the tree is clean and on up-to-date `main`, bumps the version in `package.json` **and** `$VERSION` in the `.pm`, promotes `CHANGELOG.md`'s `[Unreleased]` section, commits, tags `vX.Y.Z` and pushes; the tag triggers CI to build the `.kpz` and a GitHub release. Add CHANGELOG entries under `[Unreleased]` as you work. There are no npm dependencies, so no `npm install` is needed.

## Architecture

Three modules under `Koha/Plugin/Com/OpenFifth/`:

- `LibrisCatalogueImport.pm`: the plugin class (Koha hooks `install`/`uninstall`/`configure`/`tool`/`cronjob_nightly`) and all Koha-touching logic.
- `LibrisCatalogueImport/Export.pm`: pure functions (no Koha deps) for building the Libris request URI, splitting the response, and parsing deleted IDs.
- `LibrisCatalogueImport/ProfileSummary.pm`: pure functions turning a profile/matcher/MARC modification template into human-readable text for the configure page.
- `LibrisCatalogueImport/{configure,tool}.tt`: Template Toolkit templates.

Keep new logic that doesn't need Koha in the pure modules so it can be unit-tested without a DB.

### Run flow (`run_export`)

`cronjob_nightly` (skips if not configured) and the tool page's "Run now" both call `run_export`, which never dies and always writes a row to the plugin's own log table (created in `install`, name from `get_qualified_table_name('log')`).

1. Window is `from` (arg, else stored `last_until`, else the `initial_from` setting) to `until` (now, UTC).
2. `_fetch` POSTs the export profile as the raw body to the Libris API; the response is one blob.
3. `split_payload` separates MARC data from the trailing deleted-ID list (`deleted=append`).
4. `_stage` creates an import batch via `C4::ImportBatch`, applies the chosen `Koha::ImportBatchProfile` (matcher, actions, modification template), optionally auto-commits.
5. Only after staging succeeds is `last_until` advanced, so a failed run is retried from the same point. Deletion failures give outcome `partial`, not a retry.
6. `_process_deletions` matches deleted IDs to biblios on **field 001** and logs or deletes them; a biblio that still has items is never deleted. Deletions are done by the plugin because Koha's stage/commit ignores the MARC leader deleted flag.

### Settings

Stored via `store_data`/`retrieve_data`; keys listed in `_setting_keys`, read with defaults in `_settings`, parsed from the CGI in `_settings_from_cgi` and checked in `_validate_settings`. Add a new setting in all of those places plus `configure.tt`. `configure` passes `profile_details` to the template as a JSON string (encoded with `JSON->new->canonical->encode`, characters not bytes) so the page can show a read-only summary of the selected profile client-side.

## Gotchas

- `install()` runs `CREATE TABLE`, which implicitly commits in MySQL. `t/02-run-export.t` calls it once before opening any test transaction so no data leaks past rollback; follow that pattern in new DB tests.
- `t/00-load.t` reads `package.json` (via `KOHA_PLUGIN_DIR`) for the module name and expected version, so the `.pm` `$VERSION` and `package.json` version must agree.
- `DEVELOPMENT.md` is inherited from the plugin template and partly stale (e.g. it mentions `npm ci` in CI, which was removed); trust `.github/workflows/main.yml` and `package.json`.
- CI tests against Koha 25.11.x only (stock import-batch APIs, community tree).
- Libris subtracts one second from `from` itself; the server clock must be on NTP.
- Licence is AGPL-3.0-or-later; keep it in the `.pm` metadata, `package.json` and `LICENSE`.
