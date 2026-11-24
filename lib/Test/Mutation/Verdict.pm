package Test::Mutation::Verdict;
use v5.36;
use Types::Standard qw(Bool Dict Enum Int Maybe Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Message;
use Test::Mutation::Status;
use Test::Mutation::Types qw(Reason StatusName);

our $VERSION = '0.001';

my $WAITING = Dict [ status => StatusName, by => Str, reason => Reason, detail => Str ];
my $STATE   = Dict [
    status   => Maybe [StatusName],
    served   => Bool,
    tests    => Int,
    by       => Maybe [Str],
    reason   => Maybe [Reason],
    detail   => Maybe [Str],
    waiting  => Maybe [$WAITING],
    timeouts => Int,
];
my $TIMEOUTS_TRIED = 2;

# A syntax check passes, or it fails with the kind of compile error that it found.
my $OUTCOME = Dict [
    test        => Str,
    result      => Enum [qw(pass fail timeout)],
    served      => Bool,
    load_failed => Bool,
    bypassed    => Bool,
    syntax      => Maybe [ Enum [ 'ok', Test::Mutation::Status::of('CompileError')->reasons->@* ] ],
];
my %COMPILE_DETAIL = (
    'compile-phase' => 'the mutant does not compile',
    standalone      => 'the original source fails a syntax check of its own',
);

signature_for start => ( positional => [], returns => $STATE );

sub start () {
    return {
        status   => undef,
        served   => 0,
        tests    => 0,
        by       => undef,
        reason   => undef,
        detail   => undef,
        waiting  => undef,
        timeouts => 0
    };
}

signature_for step => ( positional => [ $STATE, $OUTCOME ], returns => $STATE );

sub step ( $state, $outcome ) {
    return $state if defined $state->{status};
    my $test   = $outcome->{test};
    my %next   = ( $state->%*, tests => $state->{tests} + 1 );
    my $decide = sub ( $status, $reason, $detail ) {
        return { %next, status => $status, reason => $reason, by => $test, detail => $detail, waiting => undef };
    };

    return $decide->( 'NoVerdict', 'loaded-around-hook', "$test loaded the target without the hook" )
      if $outcome->{bypassed};
    return _timed_out( \%next, $test, $outcome->{served} ) if $outcome->{result} eq 'timeout';
    return \%next                                          if !$outcome->{served};

    $next{served} = 1;
    if ( $outcome->{load_failed} ) {
        my $syntax = $outcome->{syntax};
        die Test::Mutation::Message::text_of('verdict-without-syntax-check') . "\n" if !defined $syntax;
        return $decide->( 'CompileError', $syntax, $COMPILE_DETAIL{$syntax} )       if $syntax ne 'ok';
    }
    return $decide->( 'Killed', undef, "$test failed" ) if $outcome->{result} eq 'fail';
    return \%next;
}

# A timeout says that one test ran out of time, and a later test may still fail within its limit.
# A timeout after the load says more than one before it, and the second timeout ends the work on the mutant.
# A timeout before the load changed the result of a test that never met the mutant, so the test is unstable.
sub _timed_out ( $next, $test, $served ) {
    my $result =
      $served
      ? { status => 'Timeout', reason => 'time-limit', by => $test, detail => "$test exceeded its time limit" }
      : {
        status => 'NoVerdict',
        reason => 'unstable-test',
        by     => $test,
        detail => "$test exceeded its time limit before it loaded the mutant"
      };
    my $waiting = $next->{waiting};
    $waiting = $result if !$waiting || ( $served && $waiting->{status} ne 'Timeout' );
    my %state = ( $next->%*, waiting => $waiting, timeouts => $next->{timeouts} + 1 );
    return $state{timeouts} < $TIMEOUTS_TRIED ? \%state : conclude( \%state );
}

signature_for conclude => ( positional => [$STATE], returns => $STATE );

sub conclude ($state) {
    return $state if defined $state->{status};
    return { $state->%*, $state->{waiting}->%*, waiting => undef } if $state->{waiting};
    return { $state->%*, status => 'Survived' } if $state->{served};
    return { $state->%*, status => 'NoCoverage', reason => $state->{tests} ? 'not-loaded' : 'unreached' };
}

signature_for final => ( positional => [$STATE], returns => StatusName );

sub final ($state) {
    return conclude($state)->{status};
}

1;

__END__

=head1 NAME

Test::Mutation::Verdict - classify a mutant from the outcomes of its tests

=head1 SYNOPSIS

    my $state = Test::Mutation::Verdict::start();
    $state = Test::Mutation::Verdict::step( $state, $outcome );
    my $status = Test::Mutation::Verdict::final($state);

=head1 DESCRIPTION

The functions fold test outcomes into a verdict state.
A decided state ignores later outcomes.

An outcome that never loaded the mutant says nothing about it.
A mutant that no test loaded is C<NoCoverage>, never C<Survived>: C<unreached> without a test, and C<not-loaded> after tests that never loaded it.
A test that loads the target around the hook yields C<NoVerdict> with the reason C<loaded-around-hook>, because the test ran the original code.
A mutant that fails to load is C<CompileError> when its syntax check fails, with the kind that the check found, and otherwise the test result decides.
A test that exceeds its time limit leaves the decision to the next test, and a test that fails still yields C<Killed>.
Without such a test the mutant is C<Timeout>, and the second timeout ends the work on the mutant.
A test that exceeds its time limit before it loads the mutant leaves C<NoVerdict> with the reason C<unstable-test>.

=head1 FUNCTIONS

=head2 start

Returns the state before any outcome.

=head2 step

Returns the state after one outcome.
An outcome with C<load_failed> set needs a defined C<syntax>: C<ok>, or the kind of compile error that the check found.

=head2 conclude

Returns the state as the end of the tests leaves it.
A state without a decision takes the status of its timeout, C<Survived> when a test loaded the mutant, or C<NoCoverage>.
The state holds the status, its reason, the deciding test, and a sentence about the case in C<detail>.

=head2 final

Returns the status of the concluded state.

=cut
