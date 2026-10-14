# Libris Catalogue Import

A Koha plugin that keeps your catalogue in step with the National Library of Sweden's [Libris](https://libris.kb.se) by importing new and changed bibliographic records every night.

It uses the Libris [MARC21 export API](https://libris.kb.se/api/docs/en/reference/marc21/). Each run asks Libris for everything that changed since the last successful run, stages it as a normal Koha import batch, and (optionally) commits it. Because it goes through import batches, your **record matching rules, overlay actions, item actions and MARC modification templates** all apply, via a Koha *import profile*.

This plugin only covers catalogue records. Other Libris services (ILL, patrons, ...) are deliberately out of scope and would be separate plugins.

## Setup

1. Create an import profile with the matching rule and overlay/no-match/item actions you want. Koha has no management page for profiles yet (see [bug 30800](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=30800)): on Tools → Stage MARC records for import, choose your options and use *Save profile*.
2. Install the plugin and enable the plugin cron job (`plugins_nightly` in your crontab; see the Koha plugins documentation).
3. Plugin → Configure: choose the import profile (the page then shows what it contains: matching rule, overlay/no-match/item actions and MARC modification template), set your Libris sigel(s) in the export profile (`locations=`), and set the date the first run should fetch from.
4. Try it against a Libris staging environment (change the API address) before pointing it at production.
5. On the plugin's tool page, use **Run now** for a first run and check the staged batch.

## How it works

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
