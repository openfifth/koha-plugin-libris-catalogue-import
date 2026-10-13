package Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport::Export;

# Pure helpers for talking to the Libris MARC21 export API
# (https://libris.kb.se/api/marc_export/). Nothing here touches Koha, so it
# can be unit tested without a database.

use Modern::Perl;

use URI;

use Exporter qw( import );
our @EXPORT_OK = qw( profile_format build_uri split_payload parse_deleted_ids iso8601_utc default_url default_profile );

our $DEFAULT_URL = 'https://libris.kb.se/api/marc_export/';

our %DELETED_MODES = (
    ignore => 'ignore',     # drop deleted records
    log    => 'append',     # export IDs of deleted records, only log them
    delete => 'append',     # export IDs of deleted records, delete in Koha
);

our $DEFAULT_PROFILE = <<'PROFILE';
name=Koha
format=MARCXML
characterencoding=UTF-8
composestrategy=compose
locations=CHANGEME
bibcreate=on
bibupdate=on
authcreate=off
authupdate=off
holdcreate=off
holdupdate=off
holddelete=off
PROFILE

sub default_url     { return $DEFAULT_URL }
sub default_profile { return $DEFAULT_PROFILE }

=head2 profile_format

    my $format = profile_format($profile_text);

Returns C<ISO2709> or C<MARCXML>, taken from the C<format=> line of an export
profile. Defaults to C<MARCXML> when the profile does not say.

=cut

sub profile_format {
    my ($profile) = @_;
    return 'MARCXML' unless defined $profile;
    if ( $profile =~ /^\s*format\s*=\s*(ISO2709|MARCXML)\s*$/mi ) {
        return uc $1;
    }
    return 'MARCXML';
}

=head2 build_uri

    my $uri = build_uri( { base_url => ..., from => ..., until => ...,
                           deleted_mode => 'log', virtual_delete => 1 } );

Builds the export request URL. C<from> and C<until> must already be ISO-8601
strings (we always send UTC with a trailing C<Z>).

=cut

sub build_uri {
    my ($args) = @_;

    my $deleted = $DELETED_MODES{ $args->{deleted_mode} // 'ignore' }
        // die "Unknown deleted mode '$args->{deleted_mode}'";

    my $uri = URI->new( $args->{base_url} || $DEFAULT_URL );
    $uri->query_form(
        from          => $args->{from},
        until         => $args->{until},
        deleted       => $deleted,
        virtualDelete => $args->{virtual_delete} ? 'true' : 'false',
    );
    return $uri;
}

=head2 split_payload

    my ( $marc, $deleted_ids ) = split_payload( $body, $deleted_mode );

With C<deleted=append> Libris sends the MARC data, a NUL byte, then a CSV of the
IDs of deleted records. Returns the MARC part and an arrayref of IDs (empty
when there is no CSV part).

=cut

sub split_payload {
    my ($body) = @_;
    $body //= '';

    my ( $marc, $csv ) = split /\0/, $body, 2;
    $marc //= '';

    return ( $marc, parse_deleted_ids($csv) );
}

=head2 parse_deleted_ids

Takes the first comma-separated column of each non-empty CSV line.

=cut

sub parse_deleted_ids {
    my ($csv) = @_;
    return [] unless defined $csv && $csv =~ /\S/;

    my @ids;
    for my $line ( split /\r?\n/, $csv ) {
        next unless $line =~ /\S/;
        my ($id) = split /,/, $line;
        $id =~ s/^\s+|\s+$//g;
        $id =~ s/^"(.*)"$/$1/;
        push @ids, $id if length $id;
    }
    return \@ids;
}

=head2 iso8601_utc

    my $string = iso8601_utc($epoch);

=cut

sub iso8601_utc {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf( '%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0] );
}

1;
