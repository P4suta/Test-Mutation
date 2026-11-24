package Test::Mutation::Mutant;
use v5.36;
use Moo;
use Types::Standard qw(Bool Int Str StrMatch Tuple);

our $VERSION = '0.001';

with 'Test::Mutation::Value';

has id          => ( is => 'ro', isa => StrMatch [qr/\A[0-9a-f]{12}\z/], required => 1 );
has path        => ( is => 'ro', isa => Str, required => 1 );
has mutator     => ( is => 'ro', isa => Str, required => 1 );
has start       => ( is => 'ro', isa => Int, required => 1 );
has end         => ( is => 'ro', isa => Int, required => 1 );
has original    => ( is => 'ro', isa => Str, required => 1 );
has replacement => ( is => 'ro', isa => Str, required => 1 );
has description => ( is => 'ro', isa => Str, required => 1 );
has from        => ( is => 'ro', isa => Tuple [ Int, Int ], required => 1 );
has to          => ( is => 'ro', isa => Tuple [ Int, Int ], required => 1 );
has scope       => ( is => 'ro', isa => Tuple [ Int, Int ], required => 1 );
has suppressed  => ( is => 'ro', isa => Bool, default => 0 );
has comparable  => ( is => 'ro', isa => Bool, default => 1 );

1;

__END__

=head1 NAME

Test::Mutation::Mutant - one replacement of one span in one file

=head1 ATTRIBUTES

=head2 id

Twelve hexadecimal digits derived from the path, span, mutator, and replacement.

=head2 path

The path of the source file, relative to the project root.

=head2 mutator

The name of the mutator that proposed the replacement.

=head2 start

The character offset of the first replaced character.

=head2 end

The character offset after the last replaced character.

=head2 original

The replaced text.

=head2 replacement

The text that takes its place.

=head2 description

A short phrase that names the change.

=head2 from

The line and column of the first replaced character.

=head2 to

The line and column after the last replaced character.

=head2 scope

The first and last line of the statement that runs the mutated code.

=head2 suppressed

True when a C<## no mutate> comment covers the mutant.

=head2 comparable

False when L<B::Deparse> leaves the replaced code out, so the run compares no compiled code for the mutant.

=cut
