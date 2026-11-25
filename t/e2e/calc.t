use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Fixture qw(copy_of run_fixture tree_digest statuses);

my $root   = copy_of('calc');
my $before = tree_digest($root);
my ( $result, $events ) = run_fixture($root);

is $result->baseline_failures, [],      'the unmodified run passes';
is $result->problems,          [],      'every source file is analyzed';
is tree_digest($root),         $before, 'the project files are unchanged and the work directory is gone';

is statuses($result),
  {
    'lib/Calc.pm:5 removed the body of add'                  => 'Killed',
    'lib/Calc.pm:7 removed the return value'                 => 'Killed',
    'lib/Calc.pm:7 replaced + with -'                        => 'Killed',
    'lib/Calc.pm:10 removed the body of is_positive'         => 'Killed',
    'lib/Calc.pm:12 removed the return value'                => 'Killed',
    'lib/Calc.pm:12 replaced > with >='                      => 'Survived',
    'lib/Calc.pm:12 replaced > with <='                      => 'Killed',
    'lib/Calc.pm:12 swapped the branches of the conditional' => 'Killed',
    'lib/Calc.pm:15 removed the body of untested'            => 'NoCoverage',
    'lib/Calc.pm:17 removed the return value'                => 'NoCoverage',
    'lib/Calc.pm:17 replaced * with /'                       => 'NoCoverage',
    'lib/Calc.pm:20 removed the body of describe'            => 'Killed',
    'lib/Calc.pm:23 replaced if with unless'                 => 'Killed',
    'lib/Calc.pm:23 replaced < with <='                      => 'Survived',
    'lib/Calc.pm:23 replaced < with >='                      => 'Killed',
    'lib/Calc.pm:24 removed the statement'                   => 'Killed',
    'lib/Calc.pm:26 replaced > with >='                      => 'Survived',
    'lib/Calc.pm:26 replaced > with <='                      => 'Killed',
    'lib/Calc.pm:26 negated the elsif condition'             => 'Killed',
    'lib/Calc.pm:27 removed the statement'                   => 'Killed',
    'lib/Calc.pm:29 removed the return value'                => 'Killed',
  },
  'every mutant has the expected status';

my $tally = $result->tally;
is $tally->{counts}{Killed},     15, 'killed';
is $tally->{counts}{Survived},   3,  'survived';
is $tally->{counts}{NoCoverage}, 3,  'no coverage';
ok $result->conclusive, 'the run is conclusive';
is [ sort { $a cmp $b } map { $_->{name} } $result->tests->@* ], [ 't/add.t', 't/sign.t' ],
  'tests of the unmodified run';
is [ grep { $_ ne 'mutant' && $_ ne 'phase' } $events->@* ], [ 'analyzed', 'baseline' ], 'events before the mutants';

done_testing;
