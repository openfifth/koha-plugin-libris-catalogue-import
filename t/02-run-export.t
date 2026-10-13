use Modern::Perl;

use Test::More tests => 6;
use Test::MockModule;
use HTTP::Response;

use C4::Biblio qw( AddBiblio );
use C4::Context;
use Koha::Biblios;
use Koha::Database;
use Koha::ImportBatches;
use MARC::Field;
use MARC::Record;

use t::lib::TestBuilder;

use Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

# install() runs CREATE TABLE, which implicitly commits: do it once, up front,
# before any test transaction is opened, so no test data leaks past a rollback.
my $setup_plugin = Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport->new( { enable_plugins => 1 } );
$setup_plugin->install;

my $marcxml = sub {
    my ($control_number) = @_;
    my $record = MARC::Record->new;
    $record->leader('00000nam a22000007a 4500');
    $record->append_fields(
        MARC::Field->new( '001', $control_number ),
        MARC::Field->new( '245', ' ', ' ', a => "Libris title $control_number" ),
    );
    return $record->as_xml_record('MARC21');
};

my $collection = sub { '<collection xmlns="http://www.loc.gov/MARC21/slim">' . join( '', map { s/<\?xml[^>]*\?>//r } @_ ) . '</collection>' };

my $respond_with = sub {
    my ( $code, $body ) = @_;
    my $ua = Test::MockModule->new('LWP::UserAgent');
    $ua->redefine( post => sub { HTTP::Response->new( $code, undef, [], $body ) } );
    return $ua;
};

my $new_plugin = sub {
    my (%settings) = @_;
    my $plugin = Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport->new( { enable_plugins => 1 } );
    $plugin->store_data( { import_profile_id => $settings{profile}->id, initial_from => '2026-10-01T00:00:00Z', last_until => '', deleted_mode => 'log', export_profile => "format=MARCXML\nlocations=S\n", %{ $settings{extra} // {} } } );
    return $plugin;
};

my $new_profile = sub {
    $builder->build_object(
        {
            class => 'Koha::ImportBatchProfiles',
            value => {
                matcher_id     => undef,
                template_id    => undef,
                record_type    => 'biblio',
                format         => 'MARCXML',
                encoding       => 'UTF-8',
                parse_items    => 0,
                overlay_action => 'replace',
                nomatch_action => 'create_new',
                item_action    => 'always_add',
            }
        }
    );
};

my $run_count = sub { my ($p) = @_; my $t = $p->_log_table_name; C4::Context->dbh->selectrow_array("SELECT COUNT(*) FROM $t") };

subtest 'successful run stages a batch and advances the window' => sub {
    plan tests => 7;
    $schema->storage->txn_begin;

    my $profile = $new_profile->();
    my $plugin  = $new_plugin->( profile => $profile );

    my $mock = $respond_with->( 200, $collection->( $marcxml->('LIBRISTEST1'), $marcxml->('LIBRISTEST2') ) );
    my $run  = $plugin->run_export;

    is( $run->{outcome},     'success', 'run succeeded' ) or diag $run->{error_message};
    is( $run->{num_records}, 2,         'two records staged' );
    ok( $run->{batch_id}, 'batch id recorded' );
    my $batch = Koha::ImportBatches->find( $run->{batch_id} );
    is( $batch->import_status, 'staged', 'batch is staged, not committed' );
    is( $batch->profile_id, $profile->id, 'profile attached to batch' );
    is( $plugin->retrieve_data('last_until'), $run->{until}, 'window advanced' );
    is( $run_count->($plugin), 1, 'run logged' );

    $schema->storage->txn_rollback;
};

subtest 'HTTP failure does not advance the window' => sub {
    plan tests => 4;
    $schema->storage->txn_begin;

    my $profile = $new_profile->();
    my $plugin  = $new_plugin->( profile => $profile );

    my $mock = $respond_with->( 500, 'boom' );
    my $run  = $plugin->run_export;

    is( $run->{outcome}, 'failure', 'run failed' );
    like( $run->{error_message}, qr/500/, 'status in error' );
    ok( !$plugin->retrieve_data('last_until'), 'window not advanced' );
    is( $run_count->($plugin), 1, 'failure logged' );

    $schema->storage->txn_rollback;
};

subtest 'empty export succeeds without a batch' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    my $profile = $new_profile->();
    my $plugin  = $new_plugin->( profile => $profile );

    my $mock = $respond_with->( 200, '' );
    my $run  = $plugin->run_export;

    is( $run->{outcome}, 'success', 'nothing changed is a success' );
    ok( !$run->{batch_id}, 'no batch created' );
    ok( $plugin->retrieve_data('last_until'), 'window advanced' );

    $schema->storage->txn_rollback;
};

subtest 'first run needs a start date' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    my $profile = $new_profile->();
    my $plugin  = $new_plugin->( profile => $profile, extra => { initial_from => '' } );

    my $run = $plugin->run_export;
    is( $run->{outcome}, 'failure', 'refuses to run without a start date' );
    like( $run->{error_message}, qr/No start date/, 'says why' );

    $schema->storage->txn_rollback;
};

subtest 'deleted_mode=delete removes records without items only' => sub {
    plan tests => 6;
    $schema->storage->txn_begin;

    my $add = sub {
        my ($cn) = @_;
        my $record = MARC::Record->new;
        $record->append_fields( MARC::Field->new( '001', $cn ), MARC::Field->new( '245', ' ', ' ', a => "title $cn" ) );
        my ($biblionumber) = AddBiblio( $record, '' );
        return $biblionumber;
    };
    my $gone     = $add->('DELGONE1');
    my $has_item = $add->('DELITEM1');
    $builder->build_sample_item( { biblionumber => $has_item } );

    my $profile = $new_profile->();
    my $plugin  = $new_plugin->( profile => $profile, extra => { deleted_mode => 'delete' } );

    my $mock = $respond_with->( 200, "\0DELGONE1\nDELITEM1\nNOSUCHID\n" );
    my $run  = $plugin->run_export;

    is( $run->{outcome},     'partial', 'item-bearing record makes the run partial' );
    is( $run->{num_deleted}, 1,         'one record deleted' );
    ok( !Koha::Biblios->find($gone), 'record without items deleted' );
    ok( Koha::Biblios->find($has_item), 'record with items kept' );
    like( $run->{error_message}, qr/still has items/, 'item-bearing record reported' );
    ok( $plugin->retrieve_data('last_until'), 'window advanced despite partial' );

    $schema->storage->txn_rollback;
};

subtest 'deleted_mode=log changes nothing' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    my $record = MARC::Record->new;
    $record->append_fields( MARC::Field->new( '001', 'LOGONLY1' ), MARC::Field->new( '245', ' ', ' ', a => 'keep me' ) );
    my ($biblionumber) = AddBiblio( $record, '' );

    my $profile = $new_profile->();
    my $plugin  = $new_plugin->( profile => $profile );

    my $mock = $respond_with->( 200, "\0LOGONLY1\n" );
    my $run  = $plugin->run_export;

    is( $run->{num_deleted}, 0, 'nothing deleted' );
    ok( Koha::Biblios->find($biblionumber), 'record still present' );

    $schema->storage->txn_rollback;
};

$setup_plugin->uninstall;
