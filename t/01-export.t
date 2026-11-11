use Modern::Perl;
use Test::More tests => 38;

use FindBin;
use lib "$FindBin::Bin/..";

use Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport::Export
    qw( profile_format build_uri split_payload parse_deleted_ids iso8601_utc clamp_from default_url default_profile normalise_timestamp error_detail has_records );

is( profile_format("name=x\nformat=ISO2709\n"), 'ISO2709', 'format read from profile' );
is( profile_format("format = marcxml\n"),       'MARCXML', 'format is case-insensitive and tolerates spaces' );
is( profile_format("name=x\n"),                 'MARCXML', 'format defaults to MARCXML' );
is( profile_format(undef),                      'MARCXML', 'undef profile defaults to MARCXML' );

my $uri = build_uri( { from => '2026-10-01T00:00:00Z', until => '2026-10-02T00:00:00Z', deleted_mode => 'log', virtual_delete => 1 } );
like( $uri, qr{^\Q@{[default_url()]}\E\?}, 'default base URL used' );
my %q = $uri->query_form;
is( $q{deleted},       'append', 'log mode asks Libris to append deleted IDs' );
is( $q{virtualDelete}, 'true',   'virtualDelete flag passed' );
is( $q{from},          '2026-10-01T00:00:00Z', 'from passed through' );

my $ignore = build_uri( { from => 'a', until => 'b', deleted_mode => 'ignore' } );
my %i = $ignore->query_form;
is( $i{deleted}, 'ignore', 'ignore mode' );
is( $i{virtualDelete}, 'false', 'virtualDelete defaults to false' );

my ( $marc, $ids ) = split_payload( "<record/>\0abc123\r\n\"def456\",extra\n\n" );
is( $marc, '<record/>', 'MARC part split from CSV at NUL' );
is_deeply( $ids, [ 'abc123', 'def456' ], 'IDs taken from first CSV column' );

my ( $m2, $i2 ) = split_payload('<record/>');
is_deeply( $i2, [], 'no NUL means no deleted IDs' );

is( iso8601_utc(0), '1970-01-01T00:00:00Z', 'epoch formatted as UTC ISO-8601' );

is( normalise_timestamp('2026-11-04'),           '2026-11-04T00:00:00Z', 'bare date expanded to midnight UTC' );
is( normalise_timestamp('2026-11-04T01:02:03Z'), '2026-11-04T01:02:03Z', 'full timestamp unchanged' );
is( normalise_timestamp(undef),                  undef,                  'undef unchanged' );

my %d = build_uri( { from => '2026-11-04', until => '2026-11-05', deleted_mode => 'log' } )->query_form;
is( $d{from},  '2026-11-04T00:00:00Z', 'build_uri expands bare from date' );
is( $d{until}, '2026-11-05T00:00:00Z', 'build_uri expands bare until date' );

is( error_detail('<html><head><title>Error 400 Valid &quot;from&quot; required</title></head><body>x</body></html>'),
    'Error 400 Valid "from" required', 'title extracted and entities decoded' );
is( error_detail("<p>Something\n  went <b>wrong</b></p>"), 'Something went wrong', 'tags stripped when no title' );
is( error_detail(''),    '', 'empty body gives empty detail' );
is( error_detail(undef), '', 'undef body gives empty detail' );
like( error_detail( 'x' x 2000 ), qr/^x{497}\.\.\.$/, 'long body truncated' );

like( $uri->as_string, qr/[?&]from=2026-10-01T00:00:00Z&until=2026-10-02T00:00:00Z&/,
    'timestamp colons are sent literally, not as %3A (Libris rejects %3A)' );
unlike( $uri->as_string, qr/%3A/i, 'no percent-encoded colons in the request URL' );

my $empty_collection = qq{<?xml version="1.0" encoding="utf-8"?>\n<collection xmlns="http://www.loc.gov/MARC21/slim">\n</collection>};
ok( !has_records( '',                'MARCXML' ), 'blank is no records' );
ok( !has_records( undef,             'MARCXML' ), 'undef is no records' );
ok( !has_records( $empty_collection, 'MARCXML' ), 'empty MARCXML collection is no records' );
ok(  has_records( '<collection><record><leader>x</leader></record></collection>', 'MARCXML' ), 'MARCXML with a record' );
ok(  has_records( '<marc:collection><marc:record/></marc:collection>', 'MARCXML' ), 'namespace-prefixed record' );
ok(  has_records( "00026nam a2200025 a 4500\x1e\x1d", 'ISO2709' ), 'ISO2709 data counts as records' );

my $now = 1_793_000_000;    # arbitrary fixed 'now'
my $earliest = iso8601_utc( $now - 20 * 86400 );
is_deeply( [ clamp_from( undef, $now ) ], [ $earliest, 0 ], 'no from: start 20 days back, not clamped' );
is_deeply( [ clamp_from( '', $now ) ],    [ $earliest, 0 ], 'empty from treated as none' );
my $recent = iso8601_utc( $now - 86400 );
is_deeply( [ clamp_from( $recent, $now ) ], [ $recent, 0 ], 'recent from kept as is' );
is_deeply( [ clamp_from( iso8601_utc( $now - 40 * 86400 ), $now ) ], [ $earliest, 1 ], 'from older than the limit is clamped' );
is_deeply( [ clamp_from( $earliest, $now ) ], [ $earliest, 0 ], 'from exactly at the limit is not clamped' );
is_deeply( [ clamp_from( '2001-01-01', $now ) ], [ $earliest, 1 ], 'bare date is normalised then clamped' );
