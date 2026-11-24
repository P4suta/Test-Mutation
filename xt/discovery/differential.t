use v5.36;
use Test2::V0;
use lib 't/lib', 'xt/discovery/lib';
use Capability;
use Gate;
use Discovery::Check;
use Discovery::Differential;
use Discovery::Engine;
use Discovery::Known;
use Discovery::Project;
use Discovery::Tier;

# Two ways to run one project stand in a stated relation, and a result outside the relation is a finding.
# The projects are known-answer projects whose tests write nothing, so a difference comes from the varied setting.

Discovery::Tier::announce();
my $seed   = Discovery::Tier::seed();
my $memo   = {};
my $engine = Discovery::Engine->new( memo => $memo );
my $git    = length qx{git --version 2>/dev/null};

sub run_of (%status) {
    return { status => {%status}, by => { map { $_ => 't/a.t' } grep { $status{$_} eq 'Killed' } keys %status } };
}

subtest 'each relation rejects the statuses outside it' => sub {
    my $between = sub ( $name, $first, $other ) {
        return [ Discovery::Check::findings( [$name], run => run_of( $first->%* ), other => run_of( $other->%* ) ) ];
    };
    my %base = ( a => 'Killed', b => 'Survived', c => 'NoCoverage', d => 'Timeout' );

    is $between->( 'jobs', \%base, { a => 'Killed', b => 'NoCoverage', c => 'Survived', d => 'Killed' } ), [],
      'more jobs may move a mutant between the undetected statuses and out of a timeout';
    is $between->( 'jobs', \%base, { %base, a => 'Survived' } ),
      ['the run with more jobs gives Survived where the run with one job gives Killed'], 'and may lose no kill';
    is $between->( 'jobs', \%base, { a => 'Killed', b => 'Survived', c => 'NoCoverage' } ),
      ['the run with more jobs lacks a mutant of the run with one job'], 'nor a mutant';

    is $between->( 'in-place', \%base, { %base, a => 'NoVerdict' } ), [], 'the project itself may give no verdict';
    is $between->( 'in-place', \%base, { %base, b => 'Killed' } ),
      ['the run in the project gives Killed where the run in copies gives Survived'], 'and no other status';

    is $between->( 'coverage', \%base, { %base, c => 'Survived' } ), [],
      'file coverage may turn a mutant without coverage into a survivor';
    is $between->( 'coverage', \%base, { %base, b => 'NoCoverage', c => 'Killed' } ),
      [
        'the run with file coverage gives Killed where the run with line coverage gives NoCoverage',
        'the run with file coverage gives NoCoverage where the run with line coverage gives Survived',
      ],
      'and nothing else';

    is $between->( 'shard', \%base, {%base} ), [], 'the merge of the parts equals the whole run';
    is $between->( 'shard', \%base, { %base, d => 'Killed' } ),
      ['the merge of the parts gives Killed where the whole run gives Timeout'], 'in every status';

    is $between->( 'since', \%base, { a => 'Killed' } ), [], 'the changed lines hold some of the mutants';
    is $between->( 'since', \%base, { a => 'Survived', e => 'Killed' } ),
      [
        'the run on the changed lines gives Survived where the whole run gives Killed',
        'the run on the changed lines holds a mutant that the whole run lacks',
      ],
      'with the statuses of the whole run, and no mutant of their own';

    my $alone = sub (@runs) {
        return [
            Discovery::Check::findings(
                ['single'],
                run    => run_of(%base),
                others => [ map { run_of( $_->%* ) } @runs ]
            )
        ];
    };
    is $alone->( { a => 'Killed' }, { b => 'Survived' }, { d => 'Killed' } ), [],
      'a mutant alone has its status of the whole run, apart from a timeout';
    is $alone->( { a => 'Killed' }, { b => 'Killed' } ),
      ['the run of one mutant gives Killed where the whole run gives Survived'], 'and no other one';

    my $proved = sub ( $status, %under ) {
        return [
            Discovery::Check::findings( ['prove'], run => run_of( a => $status ), verdicts => { a => {%under} } ) ];
    };
    is $proved->( 'Killed', 't/a.t' => 'fail', 't/b.t' => 'pass' ), [],
      'the test that detects a mutant fails under prove';
    is $proved->( 'Survived', 't/a.t' => 'pass' ), [], 'and no test fails on a survivor';
    is $proved->( 'Killed', 't/a.t' => 'pass' ), ['prove passes the test that detects a mutant in the run'],
      'a kill that prove contradicts';
    is $proved->( 'NoCoverage', 't/a.t' => 'fail' ),
      ['prove fails a test on a mutant that the run gives as NoCoverage'],
      'a mutant without coverage that a test detects';
};

# The relations of one project: the fast tier runs them on one seed, and the full tier on more.
sub related ( $known, $each ) {
    my $project = Discovery::Project->new;
    $known->write($project);
    my @found = (
        Discovery::Differential::jobs( $engine, $project ),
        Discovery::Differential::in_place( $engine, $project ),
        Discovery::Differential::coverage( $engine, $project ),
        Discovery::Differential::shard( $engine, $project ),
        Discovery::Differential::single( $engine, $project ),
        Discovery::Differential::prove( $engine, $project, $each ),
    );
    my $whole = $engine->run($project);
    $project->discard;
    return ( scalar keys $whole->{mutants}->%*, @found );
}

# A repository with one changed line: the first cell gets a comment, which moves no mutant.
sub changed_lines ($known) {
    my $project = Discovery::Project->new;
    $known->write($project);
    $project->git( 'init',   '-q' );
    $project->git( 'add',    '.' );
    $project->git( 'commit', '-q', '-m', 'the cells' );
    $project->write( 'lib/Known.pm', $known->module('Known') =~ s/^(sub cell_1 .*)$/$1 # changed/mr );
    my @found    = Discovery::Differential::since( $engine, $project, 'HEAD' );
    my $selected = keys $engine->run( $project, since => 'HEAD' )->{mutants}->%*;
    my $all      = keys $engine->run($project)->{mutants}->%*;
    ok $selected > 0 && $selected < $all, "the changed line selects $selected of $all mutants";
    $project->discard;
    return @found;
}

my %found;
my $mutants = 0;
my @plans   = Discovery::Tier::cases( [ [ $seed, 2 ] ], [ map { [ $seed + $_, undef ] } 1 .. 3 ] );
for my $plan (@plans) {
    my ( $tier, $spec )       = $plan->@*;
    my ( $known_seed, $each ) = $spec->@*;
    my $known = Discovery::Known->new( seed => $known_seed, cells => 6, tests => 2, idle => 1 );
    my ( $count, @found ) = related( $known, $each );
    $mutants += $count;
    push $found{$tier}->@*, @found;
    push $found{$tier}->@*, changed_lines($known)
      if Capability::has( 'git', $git, 'the relation of the changed lines needs the git command' );
}

push $found{fast}->@*,
  Discovery::Differential::cache( $engine, Discovery::Differential::cache_bench(), selections => 1, since => $git );

Discovery::Tier::report( 'differential', \%found );
is [ Discovery::Differential::perturbations() ],
  [qw(data-file environment helper interpreter launch outside-inc shadow source test)],
  'the cache relation perturbs every kind of input';
Gate::checked( 'projects',                 scalar @plans,         at_least => 1 );
Gate::checked( 'mutants in the relations', $mutants,              at_least => 15 );
Gate::checked( 'runs of the tool',         scalar keys $memo->%*, at_least => 25 );

done_testing;
