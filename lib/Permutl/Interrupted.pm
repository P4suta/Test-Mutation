package Permutl::Interrupted;
use v5.36;
use Moo;
use Types::Standard qw(Enum Int);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my %NUMBER = ( HUP => 1, INT => 2, TERM => 15 );

has signal => ( is => 'ro', isa => Enum [ sort keys %NUMBER ], required => 1 );

signature_for exit_status => ( method => 1, positional => [], returns => Int );

sub exit_status ($self) {
    return 128 + $NUMBER{ $self->signal };
}

1;

__END__

=head1 NAME

Permutl::Interrupted - the exception for a run that a signal ended

=head1 SYNOPSIS

    die Permutl::Interrupted->new( signal => 'TERM' );

=head1 ATTRIBUTES

=head2 signal

The name of the signal: C<HUP>, C<INT>, or C<TERM>.

=head1 METHODS

=head2 exit_status

Returns 128 plus the number of the signal, the status a shell reports for it.

=cut
