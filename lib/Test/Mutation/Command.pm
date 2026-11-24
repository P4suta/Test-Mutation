package Test::Mutation::Command;
use v5.36;
use Moo;
use Types::Standard qw(ArrayRef Bool Int Maybe Str);

our $VERSION = '0.001';

has name    => ( is => 'ro', isa => Str, required => 1 );
has words   => ( is => 'ro', isa => ArrayRef [Str], required => 1 );
has default => ( is => 'ro', isa => Bool, default  => 0 );
has usage   => ( is => 'ro', isa => Str,  required => 1 );
has summary => ( is => 'ro', isa => Str,  required => 1 );
has least   => ( is => 'ro', isa => Int,  required => 1 );
has most    => ( is => 'ro', isa => Maybe [Int], required => 1 );

1;

__END__

=head1 NAME

Test::Mutation::Command - one command and the operands it takes

=head1 SYNOPSIS

    my ($show) = grep { $_->name eq 'show' } Test::Mutation::Commands::rows()->@*;
    say $show->usage;

=head1 ATTRIBUTES

=head2 name

The name of the command.

=head2 words

The first arguments that select the command.

=head2 default

True for the command that runs when the first argument names none.

=head2 usage, summary

The usage line of the command and the line that describes it, as the help text prints them.

=head2 least, most

The smallest and the largest number of operands that the usage line declares.
C<most> is undefined for a command that takes any number of operands.

=cut
