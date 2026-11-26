use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Fixture qw(copy_of run_fixture tree_digest statuses);

my $root   = copy_of('mechanics');
my $before = tree_digest($root);
my ($result) =
  run_fixture( $root, cache => 0, timeout_floor => 1, timeout_factor => 2, enable => ['comparison-boundary'] );
my $statuses = statuses($result);

sub of ($file) {
    return { map { $_ => $statuses->{$_} } grep { /\A\Q$file\E:/ } keys $statuses->%* };
}

is $result->baseline_failures, [],      'the unmodified run passes';
is tree_digest($root),         $before, 'the project files are unchanged';

subtest 'a mutant that loops forever times out' => sub {
    is of('lib/Loop.pm'),
      {
        'lib/Loop.pm:5 removed the body of countdown' => 'Killed',
        'lib/Loop.pm:8 replaced while with until'     => 'Killed',
        'lib/Loop.pm:8 replaced > with >='            => 'Killed',
        'lib/Loop.pm:8 replaced > with <='            => 'Killed',
        'lib/Loop.pm:9 replaced -- with ++'           => 'Timeout',
        'lib/Loop.pm:9 removed the statement'         => 'Timeout',
        'lib/Loop.pm:10 replaced ++ with --'          => 'Killed',
        'lib/Loop.pm:10 removed the statement'        => 'Killed',
        'lib/Loop.pm:12 removed the return value'     => 'Killed',
      },
      'statuses';
    my ($slow) = grep { $_->{mutant}->path eq 'lib/Loop.pm' && $_->{mutant}->description eq 'replaced > with <=' }
      $result->entries->@*;
    is [ $slow->@{qw(status by)} ], [ 'Killed', 't/loop.t' ],
      'the test stops at its failing assertion before the later endless loop can time out';
};

subtest 'a mutant that fails at compile time is a compile error' => sub {
    is of('lib/Startup.pm'),
      {
        'lib/Startup.pm:6 replaced if with unless'    => 'CompileError',
        'lib/Startup.pm:6 replaced + with -'          => 'CompileError',
        'lib/Startup.pm:6 replaced != with =='        => 'CompileError',
        'lib/Startup.pm:6 removed the statement'      => 'Survived',
        'lib/Startup.pm:10 replaced if with unless'   => 'Killed',
        'lib/Startup.pm:10 replaced < with <='        => 'Survived',
        'lib/Startup.pm:10 replaced < with >='        => 'Killed',
        'lib/Startup.pm:10 removed the statement'     => 'Survived',
        'lib/Startup.pm:12 removed the body of limit' => 'Killed',
        'lib/Startup.pm:12 removed the return value'  => 'Killed',
      },
      'a failure while loading is told apart from a failure to compile';
};

subtest 'a compile error stays a compile error when the test reports the failed load and goes on' => sub {
    is of('lib/Loaded.pm'),
      {
        'lib/Loaded.pm:6 replaced if with unless'   => 'CompileError',
        'lib/Loaded.pm:6 replaced - with +'         => 'CompileError',
        'lib/Loaded.pm:6 replaced != with =='       => 'CompileError',
        'lib/Loaded.pm:6 removed the statement'     => 'Survived',
        'lib/Loaded.pm:9 removed the body of value' => 'Killed',
        'lib/Loaded.pm:9 removed the return value'  => 'Killed',
      },
      'the early stop does not hide the failed compilation';
};

subtest 'tests in taint mode, with use lib, and with a forked child detect mutants' => sub {
    is of('lib/Tainted.pm'),
      {
        'lib/Tainted.pm:5 removed the body of double' => 'Killed',
        'lib/Tainted.pm:7 removed the return value'   => 'Killed',
        'lib/Tainted.pm:7 replaced * with /'          => 'Killed',
      },
      'a test with -T on its first line';
    is of('lib/Shelf.pm'),
      {
        'lib/Shelf.pm:5 removed the body of next_slot' => 'Killed',
        'lib/Shelf.pm:7 removed the return value'      => 'Killed',
        'lib/Shelf.pm:7 replaced + with -'             => 'Killed',
      },
      'a test that calls use lib';
    is of('lib/Forked.pm'),
      {
        'lib/Forked.pm:5 removed the body of triple' => 'Killed',
        'lib/Forked.pm:7 removed the return value'   => 'Killed',
        'lib/Forked.pm:7 replaced * with /'          => 'Killed',
      },
      'a test that loads the module in a forked child';
};

subtest 'an absolute require loads the mutant placed in the job copy' => sub {
    is of('lib/Direct.pm'),
      {
        'lib/Direct.pm:5 removed the body of quadruple' => 'Killed',
        'lib/Direct.pm:7 removed the return value'      => 'Killed',
        'lib/Direct.pm:7 replaced * with /'             => 'Killed',
      },
      'statuses';
    is $result->warnings, [], 'the load was observed in the job copy';
};

ok $result->conclusive, 'the run is conclusive';

done_testing;
