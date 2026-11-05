# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright 2026 Open Fifth
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
# for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

package Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport::Job;

use Modern::Perl;

use base 'Koha::BackgroundJob';

=head1 NAME

Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport::Job - background job that runs a Libris export

Registered through the plugin's C<background_tasks> hook, so the Koha worker
runs it instead of the staff client's web request (a large export can take
longer than the browser or proxy will wait).

=head2 job_type

Koha stores plugin jobs as C<plugin_E<lt>namespaceE<gt>_E<lt>taskE<gt>>.

=cut

sub job_type { return 'plugin_libris_catalogue_import_run' }

=head2 enqueue

    Koha::Plugin::...::Job->new->enqueue( { from => $optional_iso_timestamp } );

Callers should go through the plugin's C<enqueue_run>, which refuses to queue
a second run while one is pending or running.

=cut

sub enqueue {
    my ( $self, $args ) = @_;
    $args //= {};

    return $self->SUPER::enqueue(
        {
            job_size  => 1,
            job_args  => { $args->{from} ? ( from => $args->{from} ) : () },
            job_queue => 'default',
        }
    );
}

=head2 process

Runs the export through the plugin's C<run_export>, which never dies and logs
every run to the plugin's own table.

=cut

sub process {
    my ( $self, $args ) = @_;

    $self->start;

    require Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport;
    my $plugin = Koha::Plugin::Com::OpenFifth::LibrisCatalogueImport->new( { enable_plugins => 1 } );
    my $run    = $plugin->run_export( $args->{from} ? ( from => $args->{from} ) : () );

    $self->status('failed') if $run->{outcome} eq 'failure';
    $self->progress(1);

    return $self->finish( { report => $run, messages => [] } );
}

=head2 additional_report

Nothing beyond the generic job view; the plugin's tool page has the run log.

=cut

sub additional_report { return {} }

1;
