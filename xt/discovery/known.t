use v5.36;
use Test2::V0;
use lib 't/lib', 'xt/discovery/lib';
use Gate;
use Discovery::Check;
use Discovery::Engine;
use Discovery::Known;
use Discovery::Project;
use Discovery::Tier;

# The statuses of a run equal the truth of the cells, under each coverage mode and each number of jobs.
# The truth comes from a plain interpreter, so a disagreement names a defect of the tool or of the harness.

Discovery::Tier::announce();
my $seed   = Discovery::Tier::seed();
my $engine = Discovery::Engine->new;
my @single = qw(completes I2 I3 I4);

subtest 'a seed gives the same cells on every run' => sub {
    my $known = Discovery::Known->new( seed => 1, cells => 3, tests => 1 );
    is [ split /\n/, $known->module('Known') ],
      [
        'package Known;',
        'use strict;',
        'use warnings;',
        'sub cell_1 { my ( $x, $y ) = @_; return $x + $y }',
        'sub cell_2 { my ( $x, $y ) = @_; return $x - $y }',
        'sub cell_3 { my ( $x, $y ) = @_; return $x - $y }', '1;',
      ],
      'the module of seed 1';
    is $known->rows('t/a.t'),
      [
        [ 'cell_1', [ 2, 2 ], '4' ],
        [ 'cell_1', [ 4, 1 ], '5' ],
        [ 'cell_2', [ 2, 0 ], '2' ],
        [ 'cell_2', [ 3, 3 ], '0' ]
      ],
      'the rows of its test, with the values of the original';
    isnt Discovery::Known->new( seed => 2, cells => 3, tests => 1 )->module('Known'), $known->module('Known'),
      'another seed gives other cells';
};

subtest 'the truth rejects a verdict that the cells contradict' => sub {
    my $known = Discovery::Known->new(
        tests => 1,
        loop  => 1,
        guard => 1,
        cells => [
            { body => 'return $x >= $y ? 1 : 0', rows => [ [ 4, 1 ], [ 0, 2 ] ], test => 't/a.t' },
            { body => 'return $x - $y',          rows => [ [ 3, 1 ] ],           test => undef },
        ],
    );
    my @lines = split /\n/, $known->module('Known');
    is [ @lines[ 3, 4, 5, 6 ] ],
      [
        'BEGIN { die "the guard fails\n" if 2 * 3 != 6 }',
        'sub cell_1 { my ( $x, $y ) = @_; return $x >= $y ? 1 : 0 }',
        'sub cell_2 { my ( $x, $y ) = @_; return $x - $y }',
        'sub cell_loop { my ($x) = @_; my $i = 0; $i += 1 while $i < $x; return $i }',
      ],
      'one cell on each line';
    is $known->rows('t/a.t'), [ [ 'cell_1', [ 4, 1 ], '1' ], [ 'cell_1', [ 0, 2 ], '0' ], [ 'cell_loop', [2], '2' ] ],
      'the rows of the test hold the values of the original';

    my $mutant = sub ( $line, $from, $to ) {
        my $column = 1 + index $lines[ $line - 1 ], $from;
        die "line $line holds no $from\n" if !$column;
        return {
            path        => 'lib/Known.pm',
            line        => $line,
            column      => $column,
            end_line    => $line,
            end_column  => $column + length $from,
            replacement => $to,
        };
    };
    my %mutant = (
        kills   => $mutant->( 5, '>=',     '<' ),
        passes  => $mutant->( 5, '>=',     '>' ),
        idle    => $mutant->( 6, '-',      '+' ),
        loops   => $mutant->( 7, '+=',     '-=' ),
        broken  => $mutant->( 5, 'return', 'return (' ),
        guarded => $mutant->( 4, '!=',     '==' ),
    );
    is {
        map { $_ => $known->truth( $mutant{$_} )->{'t/a.t'} } sort keys %mutant
    },
      {
        kills   => 'kills',
        passes  => 'passes',
        idle    => 'not reached',
        loops   => 'loops',
        broken  => 'does not compile',
        guarded => 'does not compile',
      },
      'what the test does to each mutant';

    my %truth =
      ( kills => 'Killed', passes => 'Survived', idle => 'NoCoverage', loops => 'Timeout', broken => 'CompileError' );
    my $run = sub (%status) {
        return {
            mutants => { map { $_ => $mutant{$_} } keys %status },
            status  => \%status,
            by      => { map { $_ => 't/a.t' } grep { $status{$_} eq 'Killed' } keys %status },
        };
    };
    my $found = sub (%status) {
        return [ Discovery::Check::findings( ['I7'], run => $run->(%status), known => $known, coverage => 'line' ) ];
    };
    is $found->(%truth),                                           [], 'the statuses of the truth pass';
    is $found->( %truth, idle => 'Ignored', passes => 'Ignored' ), [], 'a mutant that no test kills may be ignored';
    is $found->( %truth, kills => 'Ignored' ), ['I7 truth Killed, run Ignored'], 'a mutant that a test kills may not';
    is $found->( kills => 'Survived', passes => 'Killed', idle => 'Survived', loops => 'Killed', broken => 'Killed' ),
      [
        'I7 truth CompileError, run Killed',
        'I7 truth Killed, run Survived',
        'I7 truth NoCoverage, run Survived',
        'I7 truth Survived, run Killed',
        'I7 truth Timeout, run Killed',
      ],
      'every other status is a finding';
    is [ Discovery::Check::findings( ['I7'], run => $run->( idle => 'Survived' ), known => $known, coverage => 'file' )
      ],
      [], 'under file coverage a test that loads the file reaches every cell';
};

# The full tier measures larger projects of other seeds under every product of coverage and jobs.
sub wider ($seed) {
    return (
        {
            known => { seed => $seed, cells => 8, tests => 3, idle => 2 },
            runs  => [ [ 'line', 1 ], [ 'line', 3 ], [ 'file', 1 ], [ 'file', 3 ] ]
        },
        { known => { seed => $seed, cells => 3, loop => 1, guard => 1 }, runs => [ [ 'line', 1 ], [ 'file', 2 ] ] },
    );
}

my @cases = Discovery::Tier::cases(
    [
        { known => { seed => $seed, cells => 4, loop => 1, guard => 1 }, runs => [ [ 'line', 2 ] ] },
        {
            known => { seed => $seed + 1, cells => 5 },
            runs  => [ [ 'line', 1 ], [ 'line', 2 ], [ 'file', 1 ], [ 'file', 2 ] ]
        },
    ],
    [ map { wider( $seed + $_ ) } 2 .. 9 ],
);

my ( %found, %class, %ran );
my ( $runs, $mutants ) = ( 0, 0 );
for my $case (@cases) {
    my ( $tier, $plan ) = $case->@*;
    my $known   = Discovery::Known->new( $plan->{known}->%* );
    my $project = Discovery::Project->new;
    $known->write($project);
    for my $settings ( $plan->{runs}->@* ) {
        my ( $coverage, $jobs ) = $settings->@*;
        my $label = "coverage=$coverage jobs=$jobs";
        my $run   = $engine->run( $project, coverage => $coverage, jobs => $jobs, timeout_floor => 2 );
        push $found{$tier}->@*, Discovery::Check::findings( ['I5'], run => $run ),
          map { "$label: $_" }
          Discovery::Check::findings( [ @single, 'I7' ], run => $run, known => $known, coverage => $coverage );
        $class{$_}++ for map { values $known->truth( $run->{mutants}{$_} )->%* } keys $run->{mutants}->%*;
        $ran{"coverage=$coverage"}++;
        $ran{"jobs=$jobs"}++;
        $runs++;
        $mutants += keys $run->{mutants}->%*;
    }
    $project->discard;
}

Discovery::Tier::report( 'known', \%found );
is [ sort keys %class ], [ 'does not compile', 'kills', 'loops', 'not reached', 'passes' ],
  'the truth holds every class of outcome';
ok !( grep { !$ran{$_} } qw(coverage=file coverage=line jobs=1 jobs=2) ),
  'every coverage mode and both kinds of jobs ran';
Gate::checked( 'runs',                        $runs,    at_least => 5 );
Gate::checked( 'mutants compared with truth', $mutants, at_least => 60 );

done_testing;
