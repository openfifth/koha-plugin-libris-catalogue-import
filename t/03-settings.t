use Modern::Perl;

use Test::More tests => 7;

use Koha::Database;

use t::lib::TestBuilder;

use Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

$schema->storage->txn_begin;

my $plugin  = Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport->new( { enable_plugins => 1 } );
my $profile = $builder->build_object( { class => 'Koha::ImportBatchProfiles' } );

my %good = (
    import_profile_id => $profile->id,
    deleted_mode      => 'log',
    export_profile    => "format=MARCXML\nlocations=S NB\n",
    base_url          => 'https://libris.kb.se/api/marc_export/',
    initial_from      => '2026-10-01T00:00:00Z',
);

ok( !$plugin->_validate_settings( {%good} )->{error}, 'good settings validate' );

like( $plugin->_validate_settings( { %good, import_profile_id => '' } )->{error}, qr/import profile/i, 'import profile required' );
like( $plugin->_validate_settings( { %good, deleted_mode => 'nuke' } )->{error}, qr/deleted/i, 'unknown deleted mode rejected' );
like( $plugin->_validate_settings( { %good, export_profile => "format=MARCXML\nlocations=CHANGEME\n" } )->{error}, qr/CHANGEME/, 'placeholder sigel rejected' );
like( $plugin->_validate_settings( { %good, base_url => 'http://libris.kb.se/' } )->{error}, qr/https/, 'plain http rejected' );
like( $plugin->_validate_settings( { %good, initial_from => 'yesterday' } )->{error}, qr/ISO-8601/, 'bad start date rejected' );
ok( !$plugin->_validate_settings( { %good, initial_from => '' } )->{error}, 'start date optional at save time' );

$schema->storage->txn_rollback;
