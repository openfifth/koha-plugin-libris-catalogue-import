# Libris Catalogue Import

A Koha plugin that keeps your catalogue in step with the National Library of Sweden's [Libris](https://libris.kb.se) by importing new and changed bibliographic records every night.

It uses the [MARC21 export API](https://libris.kb.se/api/docs/en/reference/marc21/) that Libris provides: Libris exports its records, and this plugin imports them into Koha. Each run asks Libris for everything that changed since the last successful run, stages it as a normal Koha import batch, and (optionally) commits it. Because it goes through import batches, your **record matching rules, overlay actions, item actions and MARC modification templates** all apply, via a Koha *import profile*.

Two profiles are involved, and they are different things: the **Libris export profile** tells Libris which records to send you (set in this plugin's configuration), and the **Koha import profile** tells Koha what to do with them when they arrive (matching, overlay and item actions, MARC modification template).

This plugin only covers catalogue records, and only importing from Libris into Koha. Sending records the other way would be a separate plugin. Other Libris services (ILL, patrons, ...) are deliberately out of scope and would be separate plugins.

## Setup

1. Create an import profile with the matching rule and overlay/no-match/item actions you want. Koha has no management page for profiles yet (see [bug 30800](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=30800)): on Tools → Stage MARC records for import, choose your options and use *Save profile*.
2. Install the plugin and enable the plugin cron job (`plugins_nightly` in your crontab; see the Koha plugins documentation).
3. Plugin → Configure:
   - Choose the import profile (the page then shows what it contains: matching rule, overlay/no-match/item actions and MARC modification template).
   - **Set your Libris sigel(s) on the `locations=` line of the Libris export profile.** This is the one setting you must change: it tells Libris whose records to send, and it is pre-filled with `CHANGEME`, which the plugin refuses to run with. The other Libris export profile options are described in the [Libris MARC21 export documentation](https://libris.kb.se/api/docs/en/reference/marc21/).

   The API address is pre-filled with the production Libris endpoint, so you don't need to look it up; it is only editable in case Libris moves it.
4. Leave **auto-commit off** for the first runs, so each batch stays staged for you to review before anything changes in your catalogue.
5. On the plugin's tool page, use **Run now** for a first run and check the staged batch. The run is queued as a Koha background job (the Koha worker, `koha-worker`, must be running) because Libris can take several minutes to prepare a large set of records; the result appears under Recent runs when it finishes. Only one run can be active at a time.

## How it works

- The first run fetches the last 20 days of changes: Libris refuses requests reaching back more than 3 weeks, because the API is for staying up to date, not for full dumps. **To load your existing catalogue, ask Libris customer service for a full dump** and import it separately. If nightly runs stop for more than 3 weeks, the next run restarts from 20 days back and is logged as `partial`, since the changes in the gap can't be fetched.
- `from` is the end of the previous successful run; `until` is now (UTC). The marker only advances after staging succeeds, so a failed run is retried from the same point. Libris subtracts one second from `from` itself, so keep the server clock on NTP.
- Deleted records arrive as a list of IDs after the MARC data (`deleted=append`). The plugin matches them to Koha records on **field 001** and either logs them or deletes them. A record that still has items is never deleted.
- Staged batches follow the usual Koha workflow. Leave auto-commit off to have a cataloguer review each night's batch.

## Known limitations

- Deletion matching assumes the IDs Libris lists are the values held in 001. This needs confirming against live data.
- Bibliographic records only; authorities and holdings are not imported.
- Looking records up by 001 is a database search per deleted ID, so it is intended for nightly volumes, not bulk deletions.
- Deletions are handled by the plugin because Koha's stage/commit code doesn't act on a deleted flag (`d`) in the MARC leader. If it did, the ID list would not be needed.

## Development

```bash
export KOHA_PLUGIN_DIR=$(pwd) && prove t/
npm run release:patch   # bump version, tag, push (CI builds the .kpz)
```

## Licence

This plugin is licensed under the GNU Affero General Public License v3.0 or later (`AGPL-3.0-or-later`). See [LICENSE](LICENSE).
