package Test::Mutation::Selection;
use v5.36;
use Moo;
use Digest::SHA     ();
use Types::Standard qw(ArrayRef Bool Dict HashRef InstanceOf Int Str Undef);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Types qw(ReportSelection);
use Test::Mutation::Source;

our $VERSION = '0.001';

with 'Test::Mutation::Value';

has project        => ( is => 'ro', isa => Str, required => 1 );
has perl           => ( is => 'ro', isa => Str, required => 1 );
has sources        => ( is => 'ro', isa => HashRef [ InstanceOf ['Test::Mutation::Source'] ], required => 1 );
has tests          => ( is => 'ro', isa => ArrayRef [Str], required => 1 );
has mutators       => ( is => 'ro', isa => ArrayRef [ InstanceOf ['Test::Mutation::Mutator'] ], required => 1 );
has mutants        => ( is => 'ro', isa => ArrayRef [ InstanceOf ['Test::Mutation::Mutant'] ],  required => 1 );
has selection      => ( is => 'ro', isa => ReportSelection, default  => sub { {} } );
has catalog_digest => ( is => 'ro', isa => Str,             required => 1 );
has inventory      => ( is => 'ro', isa => Dict [ mutants => Int, digest => Str ], required => 1 );
has unanalyzed     => ( is => 'ro', isa => ArrayRef [ Dict [ path => Str, problem => Str ] ], required => 1 );
has narrowed       => ( is => 'ro', isa => Bool, required => 1 );
has matches        => ( is => 'ro', isa => HashRef [ HashRef [ ArrayRef [Str] ] ], required => 1 );
has digests        => ( is => 'ro', isa => HashRef [Str], required => 1 );
has left_out       => ( is => 'ro', isa => HashRef [Int], required => 1 );
has rejected =>
  ( is => 'ro', isa => ArrayRef [ Dict [ path => Str, mutator => Str, line => Int, rule => Str ] ], required => 1 );

signature_for verify_copy => ( method => InstanceOf [__PACKAGE__], positional => [Str], returns => Undef );

sub verify_copy ( $self, $root ) {
    for my $path ( sort keys $self->digests->%* ) {
        my $file = "$root/$path";
        Test::Mutation::Error::raise( 'source-changed', path => $path )
          if !-f $file
          || Digest::SHA::sha256_hex( Test::Mutation::Source::read_bytes($file) ) ne $self->digests->{$path};
    }
    return;
}

1;

__END__

=head1 NAME

Test::Mutation::Selection - the inputs and mutants of a resolved measurement

=head1 SYNOPSIS

    my $selection = Test::Mutation::Select::resolve( config => $config );
    $selection->verify_copy($copied_root);

=head1 ATTRIBUTES

=head2 project, perl

The absolute project directory and the executable that runs the tests.

=head2 sources, tests, mutators, mutants

The decoded source files, ordered test paths, selected mutators, and mutants assigned to the run.

=head2 selection, catalog_digest

The filters describe the requested subset.
The catalog digest identifies the source and mutator inputs used to refresh a report.

=head2 inventory

The count and digest of every selected mutant before sharding.

=head2 unanalyzed, left_out, rejected

Files with analysis problems, counts of omitted sites, and changes refused by the generator.

=head2 narrowed, matches

Whether the measurement has an explicit selector and the matches for requested patterns and identifiers.

=head2 digests

The SHA-256 digest of the analyzed bytes for each source path.

=head1 METHODS

=head2 verify_copy

Raises an environment error when a copied source is missing or its bytes changed after analysis.

=cut
