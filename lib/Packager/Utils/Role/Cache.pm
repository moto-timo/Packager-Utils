package Packager::Utils::Role::Cache;

use strict;
use warnings FATAL => 'all';

our $VERSION = "0.001";

use Moo::Role;
use MooX::Options;

use Hash::MoreUtils qw(slice_exists_map);
use List::MoreUtils qw(zip);

use Data::Dumper;

require Packager::Utils::Cache::Schema;

option connect_info => (
                is       => 'ro',
                doc      => 'How to connect to database',
                required => 1,
                json     => 1,
                long_doc => "Database connection info as json formatted string\n\n"
                  . "Example: --connect-info "
                  . "'{\"dsn\":\"dbi:SQLite:dbname=packages.db\",\"user\":\"\",\"password\":\"\"}'",
);

has schema => (
                is       => 'lazy',
                init_arg => undef,
              );

sub _build_schema
{
    my $self = $_[0];

    Packager::Utils::Cache::Schema->connect( $self->connect_info );
}

requires "packages";

has cached_packages => ( is => "lazy" );

my @pkg_cols = (
                 qw(pkg_name pkg_version pkg_maintainer pkg_installed),
                 qw(pkg_location pkg_homepage pkg_license pkg_master_sites),
               );
my %pkg_cols = map { $_    => uc $_ } @pkg_cols;
my %PKG_COLS = map { uc $_ => $_ } @pkg_cols;

my @dist_cols = ( qw(dist_name dist_version dist_file), );

my %dist_cols = map { $_    => uc $_ } @dist_cols;
my %DIST_COLS = map { uc $_ => $_ } @dist_cols;

my @upstream_cols = (qw(upstream_name upstream_version upstream_state upstream_comment));

my %upstream_cols = map { $_    => uc $_ } @upstream_cols;
my %UPSTREAM_COLS = map { uc $_ => $_ } @upstream_cols;

sub _build_cached_packages
{
    my $self   = shift;
    my $schema = $self->schema;

    my $cached_pkgs;
    my $deployed = 0;
    eval {
        my $rs = $schema->resultset('Package')->search(
                              {},
                              {
                                join    => [ { distribution => "upstream" }, "package_types" ],
                                columns => [
                                             'me.pkg_name',
                                             'me.pkg_version',
                                             'me.pkg_maintainer',
                                             'me.pkg_installed',
                                             'me.pkg_location',
                                             'me.pkg_homepage',
                                             'me.pkg_license',
                                             'me.pkg_master_sites',
                                             { 'pkg_type'      => 'package_types.pkg_type_name' },
                                             { 'dist_name'     => 'distribution.dist_name' },
                                             { 'dist_version'  => 'distribution.dist_version' },
                                             { 'dist_file'     => 'distribution.dist_file' },
                                             { 'upstream_name' => 'upstream.upstream_name' },
                                             { 'upstream_version' => 'upstream.upstream_version' },
                                             { 'upstream_state'   => 'upstream.upstream_state' },
                                             { 'upstream_comment' => 'upstream.upstream_comment' },
                                           ],
                                cache => 1,
                              }
        );

        my @map_cols = ( @pkg_cols, @dist_cols, @upstream_cols );

        while ( my $pkg_detail = $rs->next )
        {
            my %pkg_det_item = (
                map {
                    my $col = $_;
                    my $COL = uc $col;
                    $COL => $pkg_detail->get_column($col);
                  } @map_cols
            );
            my $pkg_type = $pkg_detail->get_column('pkg_type');
            $cached_pkgs->{$pkg_type}->{ $pkg_det_item{PKG_LOCATION} } = \%pkg_det_item;
        }
    };
    $@ and !$deployed++ and eval { $schema->deploy; $schema->init; };
    $@ and die $@;

    return $cached_pkgs;
}

has cache_timestamp => (
                         is        => "lazy",
                         predicate => 1
                       );

sub _build_cache_timestamp
{
    my $self   = shift;
    my $schema = $self->schema;

    my $res = $schema->resultset('PkgUtilInfo')->find( { name => "cache_timestamp" } );
    $res and return 0 + $res->get_column("value");

    return;
}

has cache_modified => (
                        is        => "rw",
                        predicate => 1
                      );

sub cache_packages
{
    my $self     = shift;
    my $schema   = $self->schema;
    my $packages = $self->packages;

    $self->has_cache_modified or return;
    $self->cache_modified > $self->cache_timestamp or return if $self->cache_timestamp;

    foreach my $pkg_system ( keys %$packages )
    {
        my $pkg_type =
          $schema->resultset('PackageType')->find_or_create( { pkg_type_name => $pkg_system } );

        my $old_pkgs =
          $schema->resultset('Package')
          ->search( { pkg_type_id => $pkg_type->get_column('pkg_type_id') } );
        my $old_upstream =
          $schema->resultset('Upstream')
          ->search( { pkg_type_id => $pkg_type->get_column('pkg_type_id') },
                    { join => "packages" } );

        $old_upstream->delete_all;
        $old_pkgs->delete_all;

        foreach my $pkg_detail ( values %{ $packages->{$pkg_system} } )
        {
            eval {
                # XXX according to riba don't use find_or_create
                #     ==> work hard to improve!
                my %dist_info = slice_exists_map( $pkg_detail, %DIST_COLS );
                my $dist = $schema->resultset('Distribution')->find_or_create( \%dist_info );
                defined( $pkg_detail->{UPSTREAM_NAME} )
                  and $pkg_detail->{UPSTREAM_NAME}
                  and my $upstream = $schema->resultset('Upstream')->find_or_create(
                                                 {
                                                   slice_exists_map( $pkg_detail, %UPSTREAM_COLS ),
                                                   dist_id => $dist->get_column('dist_id')
                                                 }
                  );
                $schema->resultset('Package')->create(
                         {
                           slice_exists_map( $pkg_detail, %PKG_COLS ),
                           pkg_type_id => $pkg_type->get_column('pkg_type_id'),
                           upstream_id => $upstream ? $upstream->get_column('upstream_id') : undef,
                           dist_id     => $dist->get_column('dist_id')
                         }
                );
            };
            $@ and print STDERR "$@\n", Dumper($pkg_detail);
        }
    }
    $schema->resultset('PkgUtilInfo')->update_or_create(
                                                         {
                                                           name  => "cache_timestamp",
                                                           value => "" . $self->cache_modified
                                                         }
                                                       );

    return;
}

=head1 AUTHOR

Jens Rehsack, C<< <rehsack at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-packager-utils at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Packager-Utils>.
I will be notified, and then you'll automatically be notified of progress
on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Packager::Utils

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Packager-Utils>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Packager-Utils>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Packager-Utils>

=item * Search CPAN

L<http://search.cpan.org/dist/Packager-Utils/>

=back

=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2013,2014 Jens Rehsack.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See L<http://dev.perl.org/licenses/> for more information.

=cut

1;
