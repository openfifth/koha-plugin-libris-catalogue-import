use Modern::Perl;

use Test::More tests => 6;
use Test::MockModule;

use C4::Context;
use Koha::BackgroundJobs;
use Koha::Database;
use Koha::DateUtils qw( dt_from_string );

use t::lib::Mocks;

use Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport;
use Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport::Job;

t::lib::Mocks::mock_config( 'enable_plugins', 1 );

my $schema = Koha::Database->new->schema;

# install() runs CREATE TABLE, which implicitly commits: do it before any
# test transaction so nothing leaks past a rollback.
my $plugin = Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport->new( { enable_plugins => 1 } );
$plugin->install;

# No message broker in tests: enqueue just stores the row.
my $bj = Test::MockModule->new('Koha::BackgroundJob');
$bj->redefine( connect => sub { return } );

my $job_type = Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport::Job->job_type;

subtest 'plugin registers its job type' => sub {
    plan tests => 2;

    my $tasks = $plugin->background_tasks;
    is( $tasks->{run}{class}, 'Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport::Job', 'class registered' );
    is( $job_type, 'plugin_' . $plugin->get_metadata->{namespace} . '_run', 'job_type matches the key Koha derives from the namespace' );
};

subtest 'job detail template is findable' => sub {
    plan tests => 4;

    my $paths = $plugin->template_include_paths;
    my ($file) = grep { -f $_ } map { "$_/background_jobs/$job_type.inc" } @$paths;
    ok( $file, 'background_jobs/<job_type>.inc exists in a template include path' );

    my $inc = do { local ( @ARGV, $/ ) = ($file); <> };
    like( $inc, qr/BLOCK report/, 'has the report block' );
    like( $inc, qr/BLOCK detail/, 'has the detail block' );
    like( $inc, qr/BLOCK js/,     'has the js block' );
};

subtest 'enqueue_run queues one job and refuses a second' => sub {
    plan tests => 5;
    $schema->storage->txn_begin;

    ok( !$plugin->active_job, 'nothing active to begin with' );

    my $first = $plugin->enqueue_run;
    ok( $first->{job_id}, 'first run queued' );
    is( $plugin->active_job->id, $first->{job_id}, 'queued job is the active one' );

    my $second = $plugin->enqueue_run;
    is( $second->{already_running}, $first->{job_id}, 'second run refused, pointing at the first' );
    is( Koha::BackgroundJobs->search( { type => $job_type } )->count, 1, 'only one job row' );

    $schema->storage->txn_rollback;
};

subtest 'a finished job does not block a new run' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    my $first = $plugin->enqueue_run;
    Koha::BackgroundJobs->find( $first->{job_id} )->status('finished')->store;

    ok( !$plugin->active_job, 'finished job is not active' );
    ok( $plugin->enqueue_run->{job_id}, 'new run queued' );

    $schema->storage->txn_rollback;
};

subtest 'a stale job does not block a new run forever' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    my $first = $plugin->enqueue_run;
    Koha::BackgroundJobs->find( $first->{job_id} )
        ->enqueued_on( dt_from_string->subtract( hours => 24 ) )->store;

    ok( !$plugin->active_job, 'job older than the stale limit is ignored' );
    isnt( $plugin->enqueue_run->{job_id}, $first->{job_id}, 'new run queued' );

    $schema->storage->txn_rollback;
};

subtest 'run_export is skipped while another run holds the lock' => sub {
    plan tests => 4;
    $schema->storage->txn_begin;

    # A second connection stands in for another worker or the nightly cron.
    my $other = C4::Context->dbh->clone;
    my ($got) = $other->selectrow_array( 'SELECT GET_LOCK(?, 0)', undef, $plugin->_lock_name('run') );
    ok( $got, 'other connection holds the run lock' );

    my $run = $plugin->run_export;
    is( $run->{outcome}, 'skipped', 'run skipped' );
    like( $run->{error_message}, qr/already in progress/, 'reason given' );

    $other->do( 'SELECT RELEASE_LOCK(?)', undef, $plugin->_lock_name('run') );
    my ($free) = C4::Context->dbh->selectrow_array( 'SELECT IS_FREE_LOCK(?)', undef, $plugin->_lock_name('run') );
    ok( $free, 'lock is free again (and run_export did not leave it held)' );

    $schema->storage->txn_rollback;
};
