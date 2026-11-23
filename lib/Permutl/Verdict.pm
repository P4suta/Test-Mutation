package Permutl::Verdict;
use v5.36;
use Types::Standard qw(Bool Dict Enum Int Maybe Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my $STATUS  = Enum [qw(Killed Survived NoCoverage Timeout CompileError RuntimeError Ignored Pending)];
my $WAITING = Dict [ status => $STATUS, by => Str, reason => Str ];
my $STATE   = Dict [
    status   => Maybe [$STATUS],
    served   => Bool,
    tests    => Int,
    by       => Maybe [Str],
    reason   => Maybe [Str],
    waiting  => Maybe [$WAITING],
    timeouts => Int,
];
my $TIMEOUTS_TRIED = 2;
my $OUTCOME        = Dict [
    test        => Str,
    result      => Enum [qw(pass fail timeout)],
    served      => Bool,
    load_failed => Bool,
    bypassed    => Bool,
    syntax_ok   => Maybe [Bool],
];

signature_for start => ( positional => [], returns => $STATE );

sub start () {
    return { status => undef, served => 0, tests => 0, by => undef, reason => undef, waiting => undef, timeouts => 0 };
}

signature_for step => ( positional => [ $STATE, $OUTCOME ], returns => $STATE );

sub step ( $state, $outcome ) {
    return $state if defined $state->{status};
    my $test   = $outcome->{test};
    my %next   = ( $state->%*, tests => $state->{tests} + 1 );
    my $decide = sub ( $status, $reason ) {
        return { %next, status => $status, by => $test, reason => $reason, waiting => undef };
    };

    return $decide->( 'RuntimeError', "$test loaded the target without the hook" ) if $outcome->{bypassed};
    return _timed_out( \%next, $test, $outcome->{served} )                         if $outcome->{result} eq 'timeout';
    return \%next                                                                  if !$outcome->{served};

    $next{served} = 1;
    if ( $outcome->{load_failed} ) {
        die "a load failure needs a syntax check\n"                       if !defined $outcome->{syntax_ok};
        return $decide->( 'CompileError', 'the mutant does not compile' ) if !$outcome->{syntax_ok};
    }
    return $decide->( 'Killed', "$test failed" ) if $outcome->{result} eq 'fail';
    return \%next;
}

# A timeout says that one test ran out of time, and a later test may still fail within its limit.
# A timeout after the load says more than one before it, and the second timeout ends the work on the mutant.
sub _timed_out ( $next, $test, $served ) {
    my $result =
      $served
      ? { status => 'Timeout', by => $test, reason => "$test exceeded its time limit" }
      : {
        status => 'RuntimeError',
        by     => $test,
        reason => "$test exceeded its time limit before it loaded the mutant"
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
    return { $state->%*, status => $state->{served} ? 'Survived' : 'NoCoverage' };
}

signature_for final => ( positional => [$STATE], returns => $STATUS );

sub final ($state) {
    return conclude($state)->{status};
}

1;

__END__

=head1 NAME

Permutl::Verdict - classify a mutant from the outcomes of its tests

=head1 SYNOPSIS

    my $state = Permutl::Verdict::start();
    $state = Permutl::Verdict::step( $state, $outcome );
    my $status = Permutl::Verdict::final($state);

=head1 DESCRIPTION

The functions fold test outcomes into a verdict state.
A decided state ignores later outcomes.

An outcome that never loaded the mutant says nothing about it.
A mutant that no test loaded is C<NoCoverage>, never C<Survived>.
A test that loads the target around the hook yields C<RuntimeError>, because the test ran the original code.
A mutant that fails to load is C<CompileError> when its syntax check fails, and otherwise the test result decides.
A test that exceeds its time limit leaves the decision to the next test, and a test that fails still yields C<Killed>.
Without such a test the mutant is C<Timeout>, and the second timeout ends the work on the mutant.

=head1 FUNCTIONS

=head2 start

Returns the state before any outcome.

=head2 step

Returns the state after one outcome.
An outcome with C<load_failed> set needs a defined C<syntax_ok>.

=head2 conclude

Returns the state as the end of the tests leaves it.
A state without a decision takes the status of its timeout, C<Survived> when a test loaded the mutant, or C<NoCoverage>.

=head2 final

Returns the status of the concluded state.

=cut
