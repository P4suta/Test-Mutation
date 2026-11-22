package Permutl::Verdict;
use v5.36;
use Types::Standard qw(Bool Dict Enum Int Maybe Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my $STATUS = Enum [qw(Killed Survived NoCoverage Timeout CompileError RuntimeError Ignored Pending)];
my $STATE  = Dict [ status => Maybe [$STATUS], served => Bool, tests => Int, by => Maybe [Str], reason => Maybe [Str] ];
my $OUTCOME = Dict [
    test        => Str,
    result      => Enum [qw(pass fail timeout)],
    served      => Bool,
    load_failed => Bool,
    bypassed    => Bool,
    syntax_ok   => Maybe [Bool],
];

signature_for start => ( positional => [], returns => $STATE );

sub start () {
    return { status => undef, served => 0, tests => 0, by => undef, reason => undef };
}

signature_for step => ( positional => [ $STATE, $OUTCOME ], returns => $STATE );

sub step ( $state, $outcome ) {
    return $state if defined $state->{status};
    my $test   = $outcome->{test};
    my %next   = ( $state->%*, tests => $state->{tests} + 1 );
    my $decide = sub ( $status, $reason ) {
        return { %next, status => $status, by => $test, reason => $reason };
    };

    return $decide->( 'RuntimeError', "$test loaded the target without the hook" ) if $outcome->{bypassed};
    if ( $outcome->{result} eq 'timeout' ) {
        return $decide->( 'Timeout',      "$test exceeded its time limit" ) if $outcome->{served};
        return $decide->( 'RuntimeError', "$test exceeded its time limit before it loaded the mutant" );
    }
    return \%next if !$outcome->{served};

    $next{served} = 1;
    if ( $outcome->{load_failed} ) {
        die "a load failure needs a syntax check\n"                       if !defined $outcome->{syntax_ok};
        return $decide->( 'CompileError', 'the mutant does not compile' ) if !$outcome->{syntax_ok};
    }
    return $decide->( 'Killed', "$test failed" ) if $outcome->{result} eq 'fail';
    return \%next;
}

signature_for final => ( positional => [$STATE], returns => $STATUS );

sub final ($state) {
    return $state->{status} if defined $state->{status};
    return $state->{served} ? 'Survived' : 'NoCoverage';
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
A time limit exceeded after the mutant loaded yields C<Timeout>.

=head1 FUNCTIONS

=head2 start

Returns the state before any outcome.

=head2 step

Returns the state after one outcome.
An outcome with C<load_failed> set needs a defined C<syntax_ok>.

=head2 final

Returns the status of a state: the decided status, C<Survived> when a test loaded the mutant, or C<NoCoverage>.

=cut
