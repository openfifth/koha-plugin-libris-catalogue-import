package Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport::ProfileSummary;

# Pure helpers that turn an import profile, its record matching rule and its
# MARC modification template into plain data for display on the configuration
# page. Nothing here touches Koha, so it can be unit tested without a database.

use Modern::Perl;

use Exporter qw( import );
our @EXPORT_OK = qw( summarise_profile describe_matcher describe_template_action describe_component );

my %OVERLAY_ACTION = (
    replace      => 'Replace existing record with incoming record',
    create_new   => 'Create new record',
    use_template => 'Update existing record using the MARC modification template',
    ignore       => 'Ignore incoming record',
);

my %NOMATCH_ACTION = (
    create_new => 'Import the incoming record as new',
    ignore     => 'Ignore incoming record',
);

my %ITEM_ACTION = (
    always_add           => 'Always add items',
    add_only_for_matches => 'Add items only if their biblio record matches an existing record',
    add_only_for_new     => 'Add items only if their biblio record does not match an existing record',
    replace              => 'Replace items if the record matches an existing record',
    ignore               => 'Ignore items',
);

my %TEMPLATE_ACTION = (
    delete_field            => 'Delete',
    add_field               => 'Add',
    update_field            => 'Update',
    move_field              => 'Move',
    copy_field              => 'Copy',
    copy_and_replace_field  => 'Copy and replace',
);

sub _label {
    my ( $map, $key ) = @_;
    return '' unless defined $key && length $key;
    return $map->{$key} // $key;
}

=head2 describe_component

    my $text = describe_component( { tag => '020', subfields => 'a', offset => 0, length => 0, norms => ['isbn'] } );

One-line description of a matchpoint component: C<020$a>, with offset/length
and normalisation routines appended when set.

=cut

sub describe_component {
    my ($c) = @_;

    # C4::Matcher stores subfields as a hash of letters; accept a plain string too.
    my $subfields = ref $c->{subfields} eq 'HASH' ? join( '', sort keys %{ $c->{subfields} } ) : $c->{subfields};

    my $text = $c->{tag} // '';
    $text .= '$' . $subfields if defined $subfields && length $subfields;

    # offset is -1 when unset; it only matters alongside a length or a start past 0
    my ( $offset, $length ) = ( $c->{offset} // -1, $c->{length} // 0 );
    $text .= " offset $offset" if $offset > 0 || ( $offset == 0 && $length );
    $text .= " length $length" if $length;

    my @norms = grep { defined && length } @{ $c->{norms} // [] };
    $text .= ' (' . join( ', ', @norms ) . ')' if @norms;
    return $text;
}

sub _describe_components {
    my ($point) = @_;
    return join( ' + ', map { describe_component($_) } @{ $point->{components} // [] } );
}

=head2 describe_matcher

    my $summary = describe_matcher( $matcher->dump );

Takes the hashref returned by C<C4::Matcher-E<gt>dump> and returns the code,
description, threshold and a readable list of match points and required
checks.

=cut

sub describe_matcher {
    my ( $dump, $threshold ) = @_;
    return undef unless $dump;

    return {
        id          => $dump->{matcher_id},
        code        => $dump->{code},
        description => $dump->{description},
        record_type => $dump->{record_type},
        threshold   => $threshold,
        matchpoints => [
            map { { index => $_->{index}, score => $_->{score}, source => _describe_components($_) } }
                @{ $dump->{matchpoints} // [] }
        ],
        matchchecks => [
            map { { source => _describe_components( $_->{source_matchpoint} ), target => _describe_components( $_->{target_matchpoint} ) } }
                @{ $dump->{matchchecks} // [] }
        ],
    };
}

=head2 describe_template_action

    my $text = describe_template_action($mmta_row);

Readable one-line description of a MARC modification template action row.

=cut

sub describe_template_action {
    my ($a) = @_;

    my $from = $a->{from_field} // '';
    $from .= '$' . $a->{from_subfield} if defined $a->{from_subfield} && length $a->{from_subfield};
    my $to = $a->{to_field} // '';
    $to .= '$' . $a->{to_subfield} if defined $a->{to_subfield} && length $a->{to_subfield};

    my $text = _label( \%TEMPLATE_ACTION, $a->{action} ) . " $from";
    $text .= " = '$a->{field_value}'" if defined $a->{field_value} && length $a->{field_value};
    $text .= " to $to"                if length $to;
    $text .= " (replace /$a->{to_regex_search}/ with '" . ( $a->{to_regex_replace} // '' ) . "')"
        if defined $a->{to_regex_search} && length $a->{to_regex_search};

    if ( $a->{conditional} ) {
        my $cond = $a->{conditional_field} // '';
        $cond .= '$' . $a->{conditional_subfield} if defined $a->{conditional_subfield} && length $a->{conditional_subfield};
        my $cmp = join ' ', split /_/, ( $a->{conditional_comparison} // '' );
        $text .= " $a->{conditional} $cond $cmp";
        $text .= " '$a->{conditional_value}'" if defined $a->{conditional_value} && length $a->{conditional_value};
    }

    return $text;
}

=head2 summarise_profile

    my $summary = summarise_profile( {
        profile  => { name => ..., overlay_action => ..., ... },   # profile columns
        matcher  => $matcher_summary,                              # from describe_matcher, or undef
        template => { name => ..., actions => [ $mmta_row, ... ] } # or undef
    } );

Returns the flat structure the configuration page renders.

=cut

sub summarise_profile {
    my ($args) = @_;
    my $p = $args->{profile};

    my $template = $args->{template};

    return {
        id             => $p->{id},
        name           => $p->{name},
        comments       => $p->{comments},
        record_type    => $p->{record_type},
        encoding       => $p->{encoding},
        format         => $p->{format},
        parse_items    => $p->{parse_items} ? 1 : 0,
        overlay_action => _label( \%OVERLAY_ACTION, $p->{overlay_action} // 'replace' ),
        nomatch_action => _label( \%NOMATCH_ACTION, $p->{nomatch_action} // 'create_new' ),
        item_action    => _label( \%ITEM_ACTION,    $p->{item_action}    // 'always_add' ),
        matcher        => $args->{matcher},
        template       => $template
        ? {
            name    => $template->{name},
            actions => [ map { describe_template_action($_) } @{ $template->{actions} // [] } ],
            }
        : undef,
    };
}

1;
