package Permutl::Tap;
use v5.36;
use Types::Standard qw(Bool Dict Int Maybe Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my $STATE = Dict [ planned => Maybe [Int], seen => Int, failed => Int, bailed => Bool ];

signature_for start => ( positional => [], returns => $STATE );

sub start () {
    return { planned => undef, seen => 0, failed => 0, bailed => 0 };
}

signature_for feed => ( positional => [ $STATE, Str ], returns => $STATE );

sub feed ( $state, $line ) {
    if ( $line =~ /\A1[.][.]([0-9]+)/ ) {
        return { $state->%*, planned => $1 + 0 };
    }
    if ( $line =~ /\A(not )?ok\b(.*)/s ) {
        my ( $not, $rest ) = ( $1, $2 );
        my $failure = $not && $rest !~ /(?<!\\)[#]\s*TODO\b/i ? 1 : 0;
        return { $state->%*, seen => $state->{seen} + 1, failed => $state->{failed} + $failure };
    }
    if ( $line =~ /\ABail out!/ ) {
        return { $state->%*, bailed => 1 };
    }
    return $state;
}

signature_for failed_already => ( positional => [$STATE], returns => Bool );

sub failed_already ($state) {
    return $state->{failed} > 0 || $state->{bailed} ? 1 : 0;
}

signature_for passed => ( positional => [ $STATE, Int ], returns => Bool );

sub passed ( $state, $exit_status ) {
    return 0 if $exit_status != 0 || failed_already($state);
    return 0 if !defined $state->{planned};
    return $state->{seen} == $state->{planned} ? 1 : 0;
}

1;

__END__

=head1 NAME

Permutl::Tap - decide whether a TAP stream passed

=head1 SYNOPSIS

    my $state = Permutl::Tap::start();
    $state = Permutl::Tap::feed( $state, $_ ) for @lines;
    my $stop_now = Permutl::Tap::failed_already($state);
    my $passed   = Permutl::Tap::passed( $state, $exit_status );

=head1 DESCRIPTION

The functions fold the top-level lines of a TAP stream into a small state.
The same state answers the question during the run and after it, so an early stop and the final verdict agree.
Indented lines belong to subtests and change nothing.
A C<not ok> line with a C<TODO> directive counts as a test that ran and did not fail.

=head1 FUNCTIONS

=head2 start

Returns the state before any line.

=head2 feed

Returns the state after one line.

=head2 failed_already

True when a failure or a bail-out makes the final verdict a failure whatever follows.

=head2 passed

True when the exit status is zero, no test failed, and the number of tests equals the plan.

=cut
