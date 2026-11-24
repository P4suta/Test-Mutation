package Test::Mutation::Interrupted;
use v5.36;
use Moo;
use Types::Standard qw(Enum Int Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Exit;
use Test::Mutation::Message;

use overload q{""} => sub ( $self, @ ) { return $self->message . "\n" }, fallback => 1;

our $VERSION = '0.001';

with 'Test::Mutation::Value';

has signal => ( is => 'ro', isa => Enum [ Test::Mutation::Exit::signals()->@* ], required => 1 );

signature_for exit_status => ( method => 1, positional => [], returns => Int );

sub exit_status ($self) {
    return Test::Mutation::Exit::of_signal( $self->signal );
}

signature_for message => ( method => 1, positional => [], returns => Str );

sub message ($self) {
    return Test::Mutation::Message::text_of( 'interrupted', signal => $self->signal );
}

1;

__END__

=head1 NAME

Test::Mutation::Interrupted - the exception for a run that a signal ended

=head1 SYNOPSIS

    my $interruption = Test::Mutation::Interrupted->new( signal => 'TERM' );
    exit $interruption->exit_status;

=head1 DESCRIPTION

L<Test::Mutation::Signals> dies with this value when a signal asks the command to end.
The value passes every place that catches an error, and each of them releases what it holds on the way.
It reads as the line that the command prints for the signal where a text is asked for.

=head1 ATTRIBUTES

=head2 signal

The name of the signal: C<HUP>, C<INT>, C<QUIT>, C<PIPE>, or C<TERM>.

=head1 METHODS

=head2 exit_status

Returns 128 plus the number of the signal, the status a shell reports for it.

=head2 message

Returns the text that the command prints for the signal, without a newline at its end.

=cut
