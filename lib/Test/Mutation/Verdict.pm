package Test::Mutation::Verdict;
use v5.36;
use Types::Standard qw(ArrayRef Bool Dict Enum Int Maybe Optional Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Message;
use Test::Mutation::Status;
use Test::Mutation::Types qw(Entry Reason StatusName TestObservation);

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

# The pool ends a test at its time limit and at its output limit, and both say that the test did not end on its own.
# Each limit is a reason of a timeout in the catalog.
my %LIMIT  = ( timeout => 'time-limit', overflow => 'output-limit' );
my $RESULT = Enum [ qw(pass fail), keys %LIMIT ];

my %COMPILE_DETAIL = (
    parse           => 'Perl rejected the generated replacement',
    'compile-phase' => 'the mutant does not compile',
    standalone      => 'the original source fails a syntax check of its own',
);
my %OUTSIDE_TEST =
  map { $_ => 1 } qw(same-code-as-original suppressed slot-not-restored build-copy-not-updated project-changed);

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

signature_for step => ( positional => [ $STATE, TestObservation ], returns => $STATE );

sub step ( $state, $outcome ) {
    return $state if defined $state->{status};
    my $test   = $outcome->{test};
    my %next   = ( $state->%*, tests => $state->{tests} + 1 );
    my $decide = sub ( $status, $reason, $detail ) {
        return { %next, status => $status, reason => $reason, by => $test, detail => $detail, waiting => undef };
    };

    if ( my $anomaly = $outcome->{anomaly} ) {
        return $decide->( 'NoVerdict', $anomaly->@{qw(reason detail)} ) if $anomaly->{reason} ne 'conflicting-test';
        return { %next, waiting => { status => 'NoVerdict', by => $test, $anomaly->%* } };
    }
    return $decide->( 'NoVerdict', 'loaded-around-hook', "$test loaded the target without the hook" )
      if $outcome->{bypassed};
    return $decide->( 'CompileError', 'parse', "the introduced function $outcome->{invalid_call} is undefined" )
      if defined $outcome->{invalid_call};
    if ( defined $outcome->{read_check} ) {
        my $check = $outcome->{read_check};
        return $decide->( 'CompileError', $outcome->{syntax}, $COMPILE_DETAIL{ $outcome->{syntax} } )
          if $check eq 'compile-error';
        return $decide->( 'Killed', undef, "$test failed twice with the changed source" ) if $check eq 'fail';
        return $decide->(
            'NoVerdict', 'unstable-test', "$test failed before loading the module and its repeat ended with $check"
        );
    }
    my $limit = limit( $outcome->{result} );
    return _timed_out( \%next, $test, $outcome->{served}, $limit ) if defined $limit;
    return \%next                                                  if !$outcome->{served};

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
sub _timed_out ( $next, $test, $served, $limit ) {
    my $words = $limit =~ tr/-/ /r;
    my $result =
      $served
      ? { status => 'Timeout', reason => $limit, by => $test, detail => "$test exceeded its $words" }
      : {
        status => 'NoVerdict',
        reason => 'unstable-test',
        by     => $test,
        detail => "$test exceeded its $words before it loaded the mutant"
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

signature_for confirm => ( positional => [ $STATE, $STATE ], returns => $STATE );

sub confirm ( $first, $repeat ) {
    my %result = ( $repeat->%*, tests => $first->{tests} + $repeat->{tests} );
    my ( $first_test, $repeat_test ) = map { defined $_->{by} ? $_->{by} : q{} } $first, $repeat;
    return \%result if $first->{status} eq $repeat->{status} && $first_test eq $repeat_test;
    my ( $before, $after ) = map { _observation($_) } $first, $repeat;
    return {
        %result,
        status => 'NoVerdict',
        reason => $repeat->{status} eq 'NoVerdict' ? $repeat->{reason} : 'unstable-test',
        detail => "$before on the first run, $after on the second run",
        by     => undef,
    };
}

sub _observation ($state) {
    return $state->{detail} if defined $state->{detail};
    return $state->{status} eq 'Survived' ? 'the covering tests passed' : $state->{status};
}

signature_for final => ( positional => [$STATE], returns => StatusName );

sub final ($state) {
    return conclude($state)->{status};
}

signature_for conclude_inventory => ( positional => [ ArrayRef [Entry] ], returns => ArrayRef [Entry] );

sub conclude_inventory ($entries) {
    my ( %first, @result );
    for my $raw (@$entries) {
        my $entry = _observed_verdict($raw);
        my $code  = $entry->{compiled_digest};
        if ( defined $code && Test::Mutation::Status::of( $entry->{status} )->role eq 'undetected' ) {
            my $mutant = $entry->{mutant};
            my $seen   = $first{ $mutant->path } ||= {};
            if ( defined $seen->{$code} ) {
                push @result,
                  {
                    $entry->%*,
                    status => 'Ignored',
                    reason => 'same-code-as-mutant',
                    detail => "compiles to the same code as mutant $seen->{$code}"
                  };
                next;
            }
            $seen->{$code} = $mutant->id;
        }
        push @result, $entry;
    }
    return \@result;
}

sub _observed_verdict ($entry) {
    my $attempts = $entry->{observations};
    return $entry if !$attempts || !$attempts->@* || $entry->{status} eq 'Pending';
    return $entry if defined $entry->{reason} && $OUTSIDE_TEST{ $entry->{reason} };
    my @states;
    for my $attempt (@$attempts) {
        my $state = start();
        $state = step( $state, $_ ) for @$attempt;
        push @states, conclude($state);
    }
    my $result = @states == 2 ? confirm(@states) : $states[0];
    return { $entry->%*, $result->%{qw(status reason detail by)}, tests_run => $result->{tests} };
}

signature_for limit => ( positional => [$RESULT], returns => Maybe [Reason] );

sub limit ($result) {
    return $LIMIT{$result};
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

A passing test that never loaded the mutant gives no evidence of execution.
A failing test can also detect a source change by reading the file as data.
When only the changed file fails a standalone syntax check, its verdict is C<CompileError>.
Otherwise a repeat must fail to establish C<Killed>.
A mutant that no test loaded is C<NoCoverage>, never C<Survived>: C<unreached> without a test, and C<not-loaded> after tests that never loaded it.
A test that loads the target around the hook yields C<NoVerdict> with the reason C<loaded-around-hook>, because the test ran the original code.
A mutant that fails to load is C<CompileError> when its syntax check fails, with the kind that the check found, and otherwise the test result decides.
A test that exceeds its time limit leaves the decision to the next test, and a test that fails still yields C<Killed>.
Without such a test the mutant is C<Timeout>, and the second timeout ends the work on the mutant.
A test that exceeds its time limit before it loads the mutant leaves C<NoVerdict> with the reason C<unstable-test>.
A test that the pool ended at its output limit counts as a timeout, and the reason C<output-limit> names that limit.

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

=head2 confirm

Compares a candidate C<Killed> or C<Survived> with a second concluded state and counts the tests in both attempts.
Conflicting observations give C<NoVerdict> and a detail that names both observations.

=head2 final

Returns the status of the concluded state.

=head2 limit

    my $reason = Test::Mutation::Verdict::limit('overflow');

Returns the reason of the limit that ended a test, C<time-limit> or C<output-limit>, for the result of an outcome.
A test that ended on its own has no such reason.

=head2 conclude_inventory

Returns the verdicts in inventory order.
Completed test attempts determine the verdict with the same rules for an individual run and a merged report.
Among undetected mutants in one source file, the first with each compiled digest keeps its verdict.
Later matches name the first mutant and leave the score.

=cut
