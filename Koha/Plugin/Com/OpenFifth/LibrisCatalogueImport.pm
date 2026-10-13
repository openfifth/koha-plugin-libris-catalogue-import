package Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

# Core Perl modules
use File::Temp qw(tempfile);
use Try::Tiny qw(catch try);

# CPAN modules
use LWP::UserAgent;

# Koha modules
use C4::Biblio qw( DelBiblio );
use C4::Context;
use C4::ImportBatch
    qw( RecordsFromISO2709File RecordsFromMARCXMLFile BatchStageMarcRecords BatchCommitRecords SetImportBatchMatcher SetImportBatchOverlayAction SetImportBatchNoMatchAction SetImportBatchItemAction BatchFindDuplicates );
use C4::Matcher;
use Koha::BiblioFrameworks;
use Koha::Biblios;
use Koha::Database;
use Koha::ImportBatches;
use Koha::ImportBatchProfiles;
use Koha::Logger;

use Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport::Export
    qw( profile_format build_uri split_payload iso8601_utc default_url default_profile );

our $VERSION = '0.1.0';

our $metadata = {
    name            => 'Libris Catalogue Import',
    author          => 'Open Fifth',
    date_authored   => '2026-10-13',
    date_updated    => '2026-10-13',
    minimum_version => '25.11.00',
    maximum_version => '26.05.00',
    version         => $VERSION,
    license         => 'GPL-3.0',
    description     => 'Nightly import of new and changed bibliographic records from the National Library of Sweden (Libris) MARC21 export API. Records are staged as a normal import batch, so your record matching rules, overlay rules and MARC modification templates all apply.',
};

# IMPLEMENTED PLUGIN HOOKS

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);
    $self->{cgi}    = CGI->new();
    $self->{logger} = Koha::Logger->get;

    return $self;
}

sub install {
    my ($self) = @_;

    my $table = $self->_log_table_name;
    C4::Context->dbh->do(qq{
        CREATE TABLE IF NOT EXISTS $table (
            id             INT(11) NOT NULL AUTO_INCREMENT,
            started_on     DATETIME NOT NULL,
            from_ts        VARCHAR(20) NOT NULL,
            until_ts       VARCHAR(20) NOT NULL,
            outcome        VARCHAR(10) NOT NULL,
            batch_id       INT(11) DEFAULT NULL,
            num_records    INT(11) NOT NULL DEFAULT 0,
            num_deleted    INT(11) NOT NULL DEFAULT 0,
            error_message  TEXT DEFAULT NULL,
            PRIMARY KEY (id)
        )
    });

    return 1;
}

sub upgrade {
    my ($self) = @_;
    return 1;
}

sub uninstall {
    my ($self) = @_;
    C4::Context->dbh->do( 'DROP TABLE IF EXISTS ' . $self->_log_table_name );
    return 1;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi      = $self->{cgi};
    my $template = $self->get_template( { file => 'configure.tt' } );

    if ( $cgi->param('save') ) {
        my $result = $self->_validate_settings( $self->_settings_from_cgi );
        if ( $result->{error} ) {
            $template->param( error_message => $result->{error} );
        } else {
            $self->store_data( $result->{settings} );
            $template->param( success_message => 'Configuration saved successfully.' );
        }
    }

    $template->param(
        settings           => $self->_settings,
        available_profiles => Koha::ImportBatchProfiles->search(),
        frameworks         => Koha::BiblioFrameworks->search( {}, { order_by => ['frameworktext'] } ),
        last_until         => $self->retrieve_data('last_until'),
    );

    $self->output_html( $template->output() );
}

sub tool {
    my ( $self, $args ) = @_;
    my $cgi      = $self->{cgi};
    my $template = $self->get_template( { file => 'tool.tt' } );

    if ( $cgi->param('run_now') ) {
        my $run = $self->run_export;
        $template->param( run_result => $run );
    }

    my $table = $self->_log_table_name;
    my $runs  = C4::Context->dbh->selectall_arrayref(
        "SELECT * FROM $table ORDER BY id DESC LIMIT 50",
        { Slice => {} }
    );

    $template->param(
        runs       => $runs,
        last_until => $self->retrieve_data('last_until'),
        configured => $self->_is_configured ? 1 : 0,
    );

    $self->output_html( $template->output() );
}

sub cronjob_nightly {
    my ($self) = @_;

    unless ( $self->_is_configured ) {
        $self->{logger}->info('Libris Catalogue Import is not configured, skipping');
        return;
    }

    $self->run_export;
    return;
}

# CORE

=head2 run_export

Fetches everything changed in Libris since the last successful run, stages it
as an import batch (optionally committing it) and processes deletions.
Returns a hashref describing the run; never dies.

The "last successful run" marker only advances once staging has succeeded, so
a failed run is retried from the same point next time.

=cut

sub run_export {
    my ( $self, %args ) = @_;

    my $settings = $self->_settings;
    my $until    = iso8601_utc(time);
    my $from     = $args{from} || $self->retrieve_data('last_until') || $settings->{initial_from};

    my $run = {
        started_on  => $self->_now,
        from        => $from,
        until       => $until,
        outcome     => 'failure',
        num_records => 0,
        num_deleted => 0,
    };

    try {
        die "No start date: set 'First run: fetch changes since' in the plugin configuration\n"
            unless $from;

        my ( $marc, $deleted_ids ) = $self->_fetch( $settings, $from, $until );

        if ( $marc =~ /\S/ ) {
            my $batch = $self->_stage( $settings, $marc, $until );
            $run->{batch_id}    = $batch->{batch_id};
            $run->{num_records} = $batch->{num_records};
        } else {
            $self->{logger}->info("Libris returned no changed records between $from and $until");
        }

        # Staging succeeded (or there was nothing to stage): from here the
        # window is consumed, even if individual deletions fail.
        $self->store_data( { last_until => $until } );
        $run->{outcome} = 'success';

        if (@$deleted_ids) {
            my $del = $self->_process_deletions( $settings, $deleted_ids );
            $run->{num_deleted} = $del->{deleted};
            if ( @{ $del->{errors} } ) {
                $run->{outcome}       = 'partial';
                $run->{error_message} = join( "\n", @{ $del->{errors} } );
            }
        }
    } catch {
        my $error = "$_";
        chomp $error;
        $self->{logger}->error("Libris export run failed: $error");
        $run->{error_message} = $error;
    };

    $self->_log_run($run);
    return $run;
}

sub _fetch {
    my ( $self, $settings, $from, $until ) = @_;

    my $uri = build_uri(
        {
            base_url       => $settings->{base_url},
            from           => $from,
            until          => $until,
            deleted_mode   => $settings->{deleted_mode},
            virtual_delete => $settings->{virtual_delete},
        }
    );

    my $ua = LWP::UserAgent->new(
        timeout => 600,
        agent   => $settings->{user_agent},
    );

    $self->{logger}->info("Requesting Libris export: $uri");

    # Libris wants the export profile as the raw POST body, like
    # `curl --data-binary @profile`.
    my $response = $ua->post(
        $uri,
        'Content-Type' => 'application/x-www-form-urlencoded',
        Content        => $settings->{export_profile},
    );
    die "Libris export request failed: " . $response->status_line . "\n" unless $response->is_success;

    return split_payload( $response->content );
}

sub _stage {
    my ( $self, $settings, $marc, $until ) = @_;

    my $profile_id = $settings->{import_profile_id};
    my $profile    = Koha::ImportBatchProfiles->find($profile_id)
        or die "Import profile $profile_id not found\n";

    my $format      = profile_format( $settings->{export_profile} );
    my $record_type = 'biblio';
    my $display_name = 'libris-export-' . ( $until // '' ) . ( $format eq 'MARCXML' ? '.xml' : '.mrc' );
    my $encoding    = $profile->encoding;

    # The parsers take file paths
    my ( $fh, $path ) = tempfile( 'libris-XXXXXX', SUFFIX => $format eq 'MARCXML' ? '.xml' : '.mrc', TMPDIR => 1, UNLINK => 1 );
    binmode $fh;
    print {$fh} $marc;
    close $fh;

    my $batch_id;
    my $num_records = 0;

    Koha::Database->new->schema->txn_do(
        sub {
            my ( $errors, $records ) =
                $format eq 'MARCXML'
                ? RecordsFromMARCXMLFile( $path, $encoding )
                : RecordsFromISO2709File( $path, $record_type, $encoding );

            $self->{logger}->error("MARC parsing error: $_") for @{ $errors // [] };

            $num_records = $records ? scalar @$records : 0;
            die "Libris returned data but no valid MARC records could be read from it\n" unless $num_records;

            my ( $id, $num_valid, $num_items, @import_errors ) = BatchStageMarcRecords(
                $record_type, $encoding, $records, $display_name,
                $profile->template_id, $profile->comments, '', $profile->parse_items, 0, 100,
                sub { }
            );
            die "Failed to create import batch\n" unless $id;
            $self->{logger}->error("Import error: $_") for @import_errors;

            Koha::ImportBatches->find($id)->set( { profile_id => $profile_id } )->store;

            $self->_set_matching( $id, $profile );

            $batch_id = $id;
        }
    );

    $self->_commit_batch( $batch_id, $settings ) if $settings->{auto_commit};

    return { batch_id => $batch_id, num_records => $num_records };
}

sub _set_matching {
    my ( $self, $batch_id, $profile ) = @_;

    SetImportBatchOverlayAction( $batch_id, $profile->overlay_action // 'replace' );
    SetImportBatchNoMatchAction( $batch_id, $profile->nomatch_action // 'create_new' );
    SetImportBatchItemAction( $batch_id, $profile->item_action // 'always_add' );

    my $matcher_id = $profile->matcher_id or return 0;
    my $matcher    = C4::Matcher->fetch($matcher_id);
    unless ($matcher) {
        $self->{logger}->warn("Matcher $matcher_id not found, skipping matching");
        return 0;
    }
    SetImportBatchMatcher( $batch_id, $matcher_id );
    return BatchFindDuplicates( $batch_id, $matcher, 10, 100, sub { } );
}

sub _commit_batch {
    my ( $self, $batch_id, $settings ) = @_;

    my $overlay_framework = $settings->{overlay_framework};
    $overlay_framework = undef if defined $overlay_framework && ( $overlay_framework eq '_USE_ORIG_' || $overlay_framework eq '' );

    my ( $added, $updated, $items_added, $items_replaced, $items_errored, $ignored ) = BatchCommitRecords(
        {
            batch_id          => $batch_id,
            framework         => $settings->{framework} // '',
            overlay_framework => $overlay_framework,
        }
    );
    $self->{logger}->info("Batch $batch_id committed: $added added, $updated updated, $ignored ignored");
    return 1;
}

# Libris tells us deleted records by ID. We assume that ID is what ends up in
# the record's 001 (control number); records are looked up on that.
sub _process_deletions {
    my ( $self, $settings, $ids ) = @_;

    my $mode   = $settings->{deleted_mode};
    my $result = { deleted => 0, errors => [] };

    for my $id (@$ids) {
        my @biblionumbers = $self->_biblionumbers_for_control_number($id);

        unless (@biblionumbers) {
            $self->{logger}->info("Libris reports $id deleted; no matching record in Koha");
            next;
        }

        for my $biblionumber (@biblionumbers) {
            if ( $mode ne 'delete' ) {
                $self->{logger}->info("Libris reports $id deleted; Koha biblionumber $biblionumber (deleted_mode=$mode, not deleting)");
                next;
            }

            my $biblio = Koha::Biblios->find($biblionumber);
            if ( $biblio && $biblio->items->count ) {
                my $msg = "Not deleting biblionumber $biblionumber ($id): it still has items";
                $self->{logger}->warn($msg);
                push @{ $result->{errors} }, $msg;
                next;
            }

            my $error = DelBiblio($biblionumber);
            if ($error) {
                my $msg = "Could not delete biblionumber $biblionumber ($id): $error";
                $self->{logger}->warn($msg);
                push @{ $result->{errors} }, $msg;
            } else {
                $result->{deleted}++;
            }
        }
    }

    return $result;
}

sub _biblionumbers_for_control_number {
    my ( $self, $id ) = @_;

    my $rows = C4::Context->dbh->selectcol_arrayref(
        q{SELECT biblionumber FROM biblio_metadata
          WHERE format = 'marcxml' AND `schema` = ?
          AND ExtractValue(metadata, '//controlfield[@tag="001"]') = ?},
        undef, C4::Context->preference('marcflavour'), $id
    );
    return @{ $rows // [] };
}

# SETTINGS

sub _setting_keys {
    return qw(
        base_url export_profile deleted_mode virtual_delete user_agent
        import_profile_id auto_commit framework overlay_framework initial_from
    );
}

sub _settings {
    my ($self) = @_;

    my %settings = map { $_ => $self->retrieve_data($_) } _setting_keys();

    $settings{base_url}       ||= default_url();
    $settings{export_profile} ||= default_profile();
    $settings{deleted_mode}   ||= 'log';
    $settings{virtual_delete} //= 0;
    $settings{auto_commit}    //= 0;
    $settings{user_agent}     ||= 'Koha Libris Catalogue Import (set a contact address in the plugin configuration)';

    return \%settings;
}

sub _settings_from_cgi {
    my ($self) = @_;
    my $cgi = $self->{cgi};

    my %settings = map { $_ => scalar $cgi->param($_) } _setting_keys();
    $settings{virtual_delete} = $cgi->param('virtual_delete') ? 1 : 0;
    $settings{auto_commit}    = $cgi->param('auto_commit')    ? 1 : 0;
    $settings{export_profile} =~ s/\r\n/\n/g if defined $settings{export_profile};

    return \%settings;
}

sub _validate_settings {
    my ( $self, $settings ) = @_;

    return { error => 'An import profile is required: it supplies the record matching, overlay and MARC modification rules.' }
        unless $settings->{import_profile_id} && Koha::ImportBatchProfiles->find( $settings->{import_profile_id} );

    return { error => 'Unknown deleted-records mode.' }
        unless $settings->{deleted_mode} && grep { $_ eq $settings->{deleted_mode} } qw(ignore log delete);

    return { error => 'The export profile must not be empty.' }
        unless ( $settings->{export_profile} // '' ) =~ /\S/;

    return { error => 'The export profile still has locations=CHANGEME: set your Libris sigel(s).' }
        if $settings->{export_profile} =~ /^\s*locations\s*=\s*CHANGEME\s*$/mi;

    return { error => 'The API base URL must be an https:// address.' }
        unless ( $settings->{base_url} // '' ) =~ m{^https://};

    return { error => 'First-run start date must be ISO-8601, e.g. 2026-10-01T00:00:00Z.' }
        if length( $settings->{initial_from} // '' )
        && $settings->{initial_from} !~ /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}Z)?$/;

    return { settings => $settings };
}

sub _is_configured {
    my ($self) = @_;
    my $s = $self->_settings;
    return $s->{import_profile_id}
        && ( $self->retrieve_data('last_until') || $s->{initial_from} );
}

# LOGGING

sub _log_table_name {
    my ($self) = @_;
    $self->{log_table} //= $self->get_qualified_table_name('log');
    return $self->{log_table};
}

sub _now {
    my @t = localtime;
    return sprintf( '%04d-%02d-%02d %02d:%02d:%02d', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0] );
}

sub _log_run {
    my ( $self, $run ) = @_;

    my $table = $self->_log_table_name;
    C4::Context->dbh->do(
        "INSERT INTO $table (started_on, from_ts, until_ts, outcome, batch_id, num_records, num_deleted, error_message) VALUES (?,?,?,?,?,?,?,?)",
        undef,
        $run->{started_on}, $run->{from} // '', $run->{until}, $run->{outcome},
        $run->{batch_id}, $run->{num_records}, $run->{num_deleted}, $run->{error_message}
    );
    return 1;
}

1;
