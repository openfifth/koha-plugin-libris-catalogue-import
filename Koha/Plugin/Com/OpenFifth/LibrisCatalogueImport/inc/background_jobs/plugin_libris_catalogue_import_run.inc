[%# Job detail blocks for the Libris catalogue import background job. Koha's
    admin/background_jobs.tt PROCESSes this file by job type and then the
    report, detail and js blocks. %]

[% BLOCK report %]
    [% SET report = job.report %]
    [% IF report %]
        [% IF report.outcome == 'success' %]
            <div class="alert alert-info">Import finished.</div>
        [% ELSIF report.outcome == 'partial' %]
            <div class="alert alert-warning">Import finished with problems.</div>
        [% ELSIF report.outcome == 'skipped' %]
            <div class="alert alert-warning">Import skipped.</div>
        [% ELSE %]
            <div class="alert alert-danger">Import failed.</div>
        [% END %]
        <table>
            <tr>
                <td>Records changed since</td>
                <td>[% report.from | html %]</td>
            </tr>
            <tr>
                <td>Until</td>
                <td>[% report.until | html %]</td>
            </tr>
            <tr>
                <td>Records staged</td>
                <td>[% report.num_records | html %]</td>
            </tr>
            <tr>
                <td>Records deleted</td>
                <td>[% report.num_deleted | html %]</td>
            </tr>
        </table>
        [% IF report.error_message %]
            <pre>[% report.error_message | html %]</pre>
        [% END %]
        [% IF report.batch_id %]
            <p><a href="/cgi-bin/koha/tools/manage-marc-import.pl?import_batch_id=[% report.batch_id | uri %]">Manage staged batch [% report.batch_id | html %]</a></p>
        [% END %]
    [% END %]
[% END %]

[% BLOCK detail %]
[% END %]

[% BLOCK js %]
[% END %]
