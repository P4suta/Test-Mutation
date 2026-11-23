package Test::Mutation::Site;
use v5.36;
use Moo;
use Types::Standard qw(Bool Enum HashRef Int Str Tuple);

our $VERSION = '0.001';

has kind => (
    is       => 'ro',
    isa      => Enum [qw(operator word number string regex statement condition sub_body return)],
    required => 1,
);
has text       => ( is => 'ro', isa => Str, required => 1 );
has start      => ( is => 'ro', isa => Int, required => 1 );
has end        => ( is => 'ro', isa => Int, required => 1 );
has role       => ( is => 'ro', isa => Str, default  => q{} );
has scope      => ( is => 'ro', isa => Tuple [ Int, Int ], required => 1 );
has detail     => ( is => 'ro', isa => HashRef, default => sub { {} } );
has comparable => ( is => 'ro', isa => Bool,    default => 1 );

1;

__END__

=head1 NAME

Test::Mutation::Site - a place in a source file that a mutator can change

=head1 DESCRIPTION

A site describes one span of source text without reference to the parser that found it.
Mutators receive sites and return replacement text.

=head1 ATTRIBUTES

=head2 kind

One of C<operator>, C<word>, C<number>, C<string>, C<regex>, C<statement>, C<condition>, C<sub_body>, and C<return>.

=head2 text

The source text of the span.

=head2 start

The character offset of the first character of the span.

=head2 end

The character offset after the last character of the span.

=head2 role

How the text is used.
An operator is C<binary>, C<unary>, or C<update>.
A word is C<compound>, C<modifier>, C<control>, or C<call>.
A part of a pattern is C<anchor>, C<quantifier>, or C<flag>.

=head2 scope

The first and last line of the statement that runs the span.
A test reaches the site when it runs a line in this range.

=head2 detail

Kind-specific facts, such as the operand class after a binding operator.
C<right> holds the number that is the whole right operand of an arithmetic operator.

=head2 comparable

False when L<B::Deparse> leaves the code of the span out, as it does for a field and an C<ADJUST> block.
A change there never shows in the compiled code that the run compares.

=cut
