use Modern::Perl;

use Test::More tests => 14;

use Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport::ProfileSummary
    qw( summarise_profile describe_matcher describe_template_action describe_component );

is( describe_component( { tag => '020', subfields => 'a', offset => 0, length => 0, norms => ['isbn'] } ), '020$a (isbn)', 'simple component' );
is( describe_component( { tag => '245', subfields => 'a', offset => 2, length => 10, norms => [''] } ), '245$a offset 2 length 10', 'offset, length and empty norm' );
is( describe_component( { tag => '100', subfields => { b => 1, a => 1 }, offset => -1, length => 0, norms => [] } ), '100$ab', 'subfields hash as stored by C4::Matcher, unset offset hidden' );
is( describe_component( { tag => '008', subfields => {}, offset => 0, length => 4, norms => [] } ), '008 offset 0 length 4', 'fixed field slice from the start' );

my $matcher = describe_matcher(
    {
        matcher_id  => 3,
        code        => 'ISBN',
        description => 'Match on ISBN',
        record_type => 'biblio',
        matchpoints => [ { index => 'isbn', score => 1000, components => [ { tag => '020', subfields => 'a', norms => ['isbn'] } ] } ],
        matchchecks => [
            {
                source_matchpoint => { components => [ { tag => '245', subfields => 'a', norms => [] } ] },
                target_matchpoint => { components => [ { tag => '245', subfields => 'a', norms => [] } ] },
            }
        ],
    },
    1000
);
is( $matcher->{code},      'ISBN', 'matcher code' );
is( $matcher->{threshold}, 1000,   'matcher threshold' );
is_deeply( $matcher->{matchpoints}, [ { index => 'isbn', score => 1000, source => '020$a (isbn)' } ], 'matchpoints described' );
is_deeply( $matcher->{matchchecks}, [ { source => '245$a', target => '245$a' } ], 'required checks described' );
is( describe_matcher(undef), undef, 'no matcher' );

is(
    describe_template_action( { action => 'copy_field', from_field => '035', from_subfield => 'a', to_field => '999', to_subfield => 'z', conditional => 'if', conditional_field => '001', conditional_comparison => 'not_exists' } ),
    'Copy 035$a to 999$z if 001 not exists',
    'template action with condition'
);
is( describe_template_action( { action => 'delete_field', from_field => '9XX' } ), 'Delete 9XX', 'delete action' );

my $summary = summarise_profile(
    {
        profile  => { id => 7, name => 'Libris', record_type => 'biblio', encoding => 'UTF-8', format => 'MARCXML', parse_items => 1, overlay_action => 'replace', nomatch_action => 'create_new', item_action => undef },
        matcher  => $matcher,
        template => { name => 'Tidy', actions => [ { action => 'delete_field', from_field => '9XX' } ] },
    }
);
is_deeply(
    [ @$summary{qw( overlay_action nomatch_action item_action parse_items )} ],
    [ 'Replace existing record with incoming record', 'Import the incoming record as new', 'Always add items', 1 ],
    'actions labelled correctly, item action defaulted'
);
is_deeply( $summary->{template}, { name => 'Tidy', actions => ['Delete 9XX'] }, 'template summarised' );

my $bare = summarise_profile( { profile => { id => 8, name => 'Bare' } } );
ok( !$bare->{matcher} && !$bare->{template}, 'profile without matcher or template' );
