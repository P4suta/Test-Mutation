use v5.36;

# The assertion of the library loads this module when it runs, which is too late for a test that started without it.
use Test::Builder ();
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Gate;
use Invariants;
use Samples;
use Space;
use World;
use Test::Mutation::Exit;
use Test::Mutation::Interrupted;
use Test::Mutation::Status;

# S5, the outcomes: every set of statuses, with and without a failing unmodified run, a signal, a part, and a gate.
# No test runs: the run returns a made result, and the three deciders of the command and the library judge it.

my @codes    = map { $_->code } Test::Mutation::Exit::rows()->@*;
my @statuses = map { $_->name } Test::Mutation::Status::rows()->@*;
my @gates    = ( undef, 0, 50, 100 );
my @parts    = ( undef, '1/2' );
my @signals  = ( undef, 'INT' );
my %number   = map { $_ => Test::Mutation::Interrupted->new( signal => $_ )->exit_status } qw(HUP INT TERM);
my $failure  = [ { test => 't/sample.t', output => "not ok 1\n", errors => q{} } ];
my ( %violations, @broken );
my $count = 0;

sub violation ( $gate, $what, $score, $part ) {
    push $violations{$gate}->@*, [ $what, defined $score ? $score : 'none', defined $part ? 'one' : 'whole' ];
    return;
}

# The result that a case hands to the deciders.
sub made ( $statuses, %fact ) {
    my $part = $fact{part};
    return Samples::result(
        statuses    => $fact{baseline_failed} ? [] : $statuses,
        interrupted => $fact{signal},
        shard       => $part,
        ( $fact{baseline_failed} ? ( baseline_failures => $failure )                                             : () ),
        ( defined $part          ? ( inventory         => { mutants => 2 * $statuses->@*, digest => 'a' x 64 } ) : () ),
    );
}

# What each decider says about a whole run under one gate: true for success, and nothing where a decider has no say.
# The assertion of the library always has a gate, and the merge of the two parts is judged without a gate and at one gate.
sub deciders ( $result, $exit, $gate, @line ) {
    my $merges = !defined $gate || $gate == 50;
    return (
        run       => $exit == 0    ? 1                                                          : 0,
        assertion => defined $gate ? Space::asserted( $result, Space::scratch(), min => $gate ) : undef,
        merge     => $merges       ? ( Space::merged( $result, @line ) == 0 ? 1 : 0 )           : undef,
    );
}

# One result under every gate: what the command decides, and what the outcome of the result calls for.
sub judge ( $statuses, %fact ) {
    my ( $part, $signal ) = @fact{qw(part signal)};
    my $result = made( $statuses, %fact );
    my $whole  = !$fact{baseline_failed} && !defined $signal && !defined $part;
    my ( %counts, %exit );
    $counts{$_}++ for $statuses->@*;
    for my $gate (@gates) {
        my @line = ( ( defined $gate ? ( '--min-score', $gate ) : () ), ( defined $part ? ( '--shard', $part ) : () ) );
        my $observation = Space::decided( $result, @line );
        my $exit        = $observation->{exit};
        $count++;
        if ( !defined $exit ) {
            push @broken, "@$statuses @line: $observation->{died}";
            next;
        }
        push @broken, map { "@$statuses @line: $_" } Invariants::exit_domain( $observation, \@codes );
        my ( $outcome, $expected ) =
          Invariants::outcome( \%counts, %fact, gate => $gate, signal => defined $signal ? $number{$signal} : undef );
        violation( 'exit-table', "$outcome: $_", $gate, $part ) for Invariants::exit_table( $observation, $expected );
        violation( 'one-line',   "status $exit: $_", $gate, $part ) for Invariants::one_line($observation);
        $exit{$gate} = $exit if defined $gate;
        violation( 'three-deciders', $_, $gate, $part )
          for $whole ? Invariants::three_deciders( deciders( $result, $exit, $gate, @line ) ) : ();
    }
    return if $fact{baseline_failed} || defined $signal;
    violation( 'gate', $_, 'any', $part ) for Invariants::gate( \%counts, defined $part, \%exit );
    return;
}

my $sets = Space::status_sets();
for my $part (@parts) {
    for my $signal (@signals) {
        judge( $_, part => $part, signal => $signal ) for $sets->@*;
        judge( [], part => $part, signal => $signal, baseline_failed => 1 );
    }
}
judge( [qw(Killed Pending)], signal => $_ ) for qw(HUP TERM);

is \@broken,         [],               'no decision dies, and every exit status stands in the table';
is scalar $sets->@*, 2**@statuses + 2, 'every set of the statuses of the table, and two results with two of one status';
is $count,           @gates * ( @parts * @signals * ( $sets->@* + 1 ) + 2 ), 'the decisions that the tables call for';
Gate::checked( 'decisions', $count, at_least => 4000 );

subtest 'the gate of the configuration file' => sub {
    my $root   = Space::tree( 'mutation.toml' => "[thresholds]\nbreak = 50\n\n[report]\nformats = []\n" );
    my $result = Samples::result( statuses => [qw(Killed Killed Survived)] );
    my $run    = do {
        no warnings 'redefine';
        local *Test::Mutation::Runner::run = sub { return $result };
        World::observe( ['run'], cwd => $root )->{exit};
    };
    my %passes = ( run => $run == 0 ? 1 : 0, assertion => Space::asserted( $result, $root ) );
    violation( 'three-deciders', "the gate of the file: $_", 50, undef ) for Invariants::three_deciders(%passes);
    is $run, 0, 'the run meets the gate of the file';
};

subtest 'an error of the command and an outcome of a run' => sub {
    my $inconclusive = Space::decided( Samples::result( statuses => ['NoVerdict'] ) )->{exit};
    my $error        = do {
        no warnings 'redefine';
        local *Test::Mutation::Runner::run = sub { die "the engine broke\n" };
        World::observe( ['run'], cwd => Space::scratch() );
    };
    is [ $error->@{qw(exit stderr)} ], [ 6, "4 processors online\nmutation: internal error: the engine broke\n" ],
      'an error ends the command with its line, after the first line of the run';
    violation( 'exit-table', "an error of the command: status $error->{exit}, the status of an inconclusive run",
        undef, undef )
      if $error->{exit} == $inconclusive;
};

for my $gate (qw(exit-table one-line gate three-deciders)) {
    Gate::findings( "contract-$gate-outcomes", Space::folded( $violations{$gate} || [], 'gates', 'parts' ) );
}

done_testing;
