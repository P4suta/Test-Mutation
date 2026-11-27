use v5.36;
use Test2::V0;
use lib 't/lib', 'xt/discovery/lib';
use Capability;
use Gate;
use Discovery::Check;
use Discovery::Engine;
use Discovery::Faults;
use Discovery::Tier;

# A fault ends a run in a stated way: an exit status of the contract, one line of the tool, and nothing left behind.
# The phase listener and the files of the run identify when each signal arrives.

Discovery::Tier::announce();
my $engine = Discovery::Engine->new;
my $bench  = Discovery::Faults::bench();
my $small  = Discovery::Faults::bench(20);
my $rights = Capability::has( 'unprivileged', $> != 0, 'a fault of rights needs a user without every right' );

subtest 'the check of a fault rejects each way to end badly' => sub {
    my $found = sub ( $run, @fault ) {
        return [ Discovery::Check::findings( ['fault'], run => { hung => 0, signal => 0, $run->%* }, @fault ) ];
    };
    my $line = "3 mutants in 1 file, 2 tests\nmutation: interrupted by SIGTERM\n";
    is $found->( { exit => 143, stderr => $line }, signal => 'TERM' ), [], 'the status and the line of a signal';
    is $found->( { exit => 4, stderr => "mutation: the run states no score\n" }, fails => 1 ), [],
      'the status and the line of a failure';
    is $found->( { exit => 0, signal => 15, stderr => q{} }, signal => 'TERM' ), ['the run ends by signal 15'],
      'a death by the signal';
    is $found->( { exit => 130, stderr => $line }, signal => 'TERM' ),
      ['the run exits with status 130 after the signal'],
      'the status of another signal';
    is $found->( { exit => 77, stderr => "mutation: no\n" } ),
      ['the run exits with status 77, which the contract leaves out'], 'a status outside the contract';
    is $found->( { exit => 3, stderr => "3 mutants in 1 file, 2 tests\n" } ),
      ['standard error ends without one line of the tool'], 'a failure without a line of the tool';
    is $found->( { exit => 4, stderr => "mutation: one\nmutation: two\n" } ),
      ['standard error ends without one line of the tool'], 'two lines of the tool';
    is $found->( { exit => 4, stderr => "mutation: no file at lib/A.pm line 7.\n" } ),
      ['standard error names a place in the code'], 'a place in the code';
    is $found->( { exit => 0, stderr => q{} }, fails => 1 ), ['the run exits with status 0 after the fault'],
      'a success where nothing can be measured';
    is $found->( { exit => 5, stderr => "mutation: cannot copy the project\n" }, fails => 1 ), [],
      'the status and the line of an error of the environment';
    is $found->( { exit => 6, stderr => "mutation: internal error: no\n" }, fails => 1 ),
      ['the run exits with status 6, an internal error'], 'a defect of the tool';
    is $found->( { exit => 6, stderr => "mutation: internal error: no\n" }, fails => 1, internal => 1 ), [],
      'the status and the line of a fault that is a defect';
    is $found->( { exit => 4, stderr => "mutation: no\n" }, fails => 1, internal => 1 ),
      ['the run exits with status 4, where the fault is an internal error'], 'a defect under another status';
    is $found->( { exit => 131, stderr => "mutation: interrupted by SIGQUIT\n" }, signal => 'QUIT' ), [],
      'the status and the line of the signal QUIT';
    is $found->( { exit => 141, stderr => "mutation: interrupted by SIGPIPE\n" }, signal => 'PIPE' ), [],
      'the status and the line of the signal PIPE';
};

my ( %found, %ran );

# A signal that never met its moment observed nothing, which is a failure of the harness and no finding.
sub met ( $tier, $name, @result ) {
    my $reached = pop @result;
    ok $reached, "$name met its moment" or diag @result;
    push $found{$tier}->@*, @result if $reached;
    $ran{$name}++;
    return;
}

# A moment that the plain project passes too fast has a project of its own, which keeps the tool there for longer.
# A run that misses the analysis would measure thousands of mutants, so that run compares no compiled code.
my %stage = (
    'the analysis'     => [ Discovery::Faults::analysis_bench(), equivalence => 0, deadline => 60 ],
    'the cache digest' => [ Discovery::Faults::digest_bench(),   cache => 1 ],
);
my @signals = Discovery::Tier::cases(
    [
        [ 'INT',  'the copy' ],
        [ 'TERM', 'the analysis' ],
        [ 'TERM', 'the unmodified run' ],
        [ 'INT',  'the cache digest' ],
        [ 'HUP',  'the mutants' ],
        [ 'QUIT', 'the copy' ],
        [ 'PIPE', 'the mutants' ],
    ],
    [
        [ 'TERM', 'the copy' ],
        [ 'HUP',  'the copy' ],
        [ 'PIPE', 'the copy' ],
        [ 'INT',  'the analysis' ],
        [ 'HUP',  'the analysis' ],
        [ 'INT',  'the unmodified run' ],
        [ 'HUP',  'the unmodified run' ],
        [ 'QUIT', 'the unmodified run' ],
        [ 'PIPE', 'the unmodified run' ],
        [ 'TERM', 'the cache digest' ],
        [ 'HUP',  'the cache digest' ],
        [ 'INT',  'the mutants' ],
        [ 'TERM', 'the mutants' ],
        [ 'QUIT', 'the mutants' ],
    ],
);
for my $case (@signals) {
    my ( $tier,    $plan )     = $case->@*;
    my ( $signal,  $moment )   = $plan->@*;
    my ( $project, @settings ) = @{ $stage{$moment} || [$bench] };
    met(
        $tier,
        "$signal during $moment",
        Discovery::Faults::signalled( $engine, $project, $signal, $moment, @settings )
    );
}
for my $case ( Discovery::Tier::cases( [ 'TERM', 'QUIT' ], [ 'INT', 'HUP', 'PIPE' ] ) ) {
    my ( $tier, $signal ) = $case->@*;
    met( $tier, "$signal twice", Discovery::Faults::signalled_twice( $engine, $bench, $signal ) );
}
for my $case ( Discovery::Tier::cases( [ 'mutant', 'phase:release' ], [ 'analyzed', 'baseline' ] ) ) {
    my ( $tier, $event ) = $case->@*;
    push $found{$tier}->@*, Discovery::Faults::dying_listener( $engine, $small, $event );
    $ran{"a listener at $event"}++;
}

push $found{fast}->@*, Discovery::Faults::missing_interpreter( $engine, $small );
$ran{'an interpreter'}++;
if ($rights) {
    push $found{fast}->@*, map { $_->( $engine, $small ) } \&Discovery::Faults::read_only_temporary,
      \&Discovery::Faults::unreadable_file, \&Discovery::Faults::unwritable_cache,
      \&Discovery::Faults::read_only_project;
    $ran{$_}++ for 'a temporary directory', 'a file', 'a cache directory', 'a project';
}

Discovery::Tier::report( 'faults', \%found );
is [ Discovery::Faults::moments() ],
  [ 'the analysis', 'the cache digest', 'the copy', 'the mutants', 'the removal of the copies', 'the unmodified run' ],
  'the moments of a run that a signal can meet';
Gate::checked( 'faults', scalar keys %ran, at_least => $rights ? 15 : 11 );

done_testing;
