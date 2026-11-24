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
# The signals arrive at moments that the files of the run show, since the tool names no phase yet.

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
    is $found->( { exit => 4, stderr => "mutation: cannot copy the project\n" }, fails => 1 ), [],
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

my @signals = Discovery::Tier::cases(
    [ [ 'INT', 'the copy' ], [ 'TERM', 'the unmodified run' ], [ 'HUP', 'the mutants' ] ],
    [
        [ 'TERM', 'the copy' ],
        [ 'HUP',  'the copy' ],
        [ 'INT',  'the unmodified run' ],
        [ 'HUP',  'the unmodified run' ],
        [ 'INT',  'the mutants' ],
        [ 'TERM', 'the mutants' ],
    ],
);
for my $case (@signals) {
    my ( $tier,   $plan )   = $case->@*;
    my ( $signal, $moment ) = $plan->@*;
    met( $tier, "$signal during $moment", Discovery::Faults::signalled( $engine, $bench, $signal, $moment ) );
}
for my $case ( Discovery::Tier::cases( ['TERM'], [ 'INT', 'HUP' ] ) ) {
    my ( $tier, $signal ) = $case->@*;
    met( $tier, "$signal twice", Discovery::Faults::signalled_twice( $engine, $bench, $signal ) );
}
for my $case ( Discovery::Tier::cases( ['mutant'], [ 'analyzed', 'baseline' ] ) ) {
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
is [ Discovery::Faults::moments() ], [ 'the copy', 'the mutants', 'the removal of the copies', 'the unmodified run' ],
  'the moments of a run that a signal can meet';
Gate::checked( 'faults', scalar keys %ran, at_least => $rights ? 10 : 6 );

done_testing;
