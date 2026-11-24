package Test::Mutation::Clock;
use v5.36;
use Moo;
use Time::HiRes            ();
use Types::Standard        qw(ArrayRef FileHandle InstanceOf Num);
use Types::Common::Numeric qw(PositiveOrZeroNum);
use Type::Params           qw(signature_for);

our $VERSION = '0.001';

with 'Test::Mutation::Value';

signature_for now => ( method => 1, positional => [], returns => Num );

# A change of the time of day moves no deadline, so the clock counts from an arbitrary start that only moves forward.
sub now ($self) {
    return Time::HiRes::clock_gettime( Time::HiRes::CLOCK_MONOTONIC() );
}

signature_for wait_for => (
    method     => 1,
    positional => [ InstanceOf ['IO::Select'], PositiveOrZeroNum ],
    returns    => ArrayRef [FileHandle],
);

sub wait_for ( $self, $select, $seconds ) {
    return [ $select->can_read($seconds) ];
}

1;

__END__

=head1 NAME

Test::Mutation::Clock - the time of the machine and a wait for handles

=head1 SYNOPSIS

    my $clock    = Test::Mutation::Clock->new;
    my $deadline = $clock->now + 10;
    my $ready    = $clock->wait_for( IO::Select->new($pipe), $deadline - $clock->now );

=head1 DESCRIPTION

L<Test::Mutation::Pool> reads its time and waits through this object, so a caller may give it another one.
A test gives a clock that moves only when the test moves it, and the deadlines of the pool then fall when the test says so.
Such a clock has the same two methods.

=head1 METHODS

=head2 now

Returns the seconds of a clock that only moves forward.
The start of the count is arbitrary, so a difference of two values alone has a meaning.

=head2 wait_for

    my $ready = $clock->wait_for( $select, $seconds );

Waits until a handle of the L<IO::Select> set can be read or the seconds are over, and returns the readable handles.
A signal that arrives during the wait ends it with no handle.

=cut
