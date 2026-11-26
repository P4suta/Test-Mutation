use v5.36;
use Test2::V0;
use Test::Mutation::Message;
use Test::Mutation::Runner;
use Test::Mutation::Record;
use Test::Mutation::Select;
use Test::Mutation::Settings;
use Test::Mutation::Workspace;
use lib 't/e2e/lib';
use Fixture qw(copy_of);

sub test_task ( $name, %attributes ) {
    return { payload => { kind => 'test', test => $name, %attributes } };
}

# The schedule maintains the identity of live tasks across pool callbacks.
## no critic (Subroutines::ProtectPrivateSubs Variables::ProtectPrivateVars)
subtest 'a pending retry waits for the prior invocation and gives other work a turn' => sub {
    my ( $initial, $concurrent, $waiting ) = map { test_task('a.t') } 1 .. 3;
    my $other    = test_task('b.t');
    my $compiler = { payload => { kind => 'syntax-original' } };
    my $repeat   = test_task( 'a.t', isolated => 1 );
    my $schedule = { ready => [ $initial, $concurrent ], active => {} };
    for my $task ( $initial, $concurrent ) {
        is Test::Mutation::Runner::_take_ready( $schedule, undef ), $task, 'an unrestricted test takes the next slot';
    }
    is [ map { $_->{payload}{overlapped} } $initial, $concurrent ], [ 1, 1 ],
      'both concurrent observations remember the overlap';
    $schedule->{ready} = [ $waiting, $repeat, $compiler, $other ];
    $schedule->{retrying}{'a.t'} = 1;
    is Test::Mutation::Runner::_take_ready( $schedule, undef ), $compiler, 'compilation can pass a waiting retry';
    is Test::Mutation::Runner::_take_ready( $schedule, undef ), $other,    'an independent test can use the next slot';
    is Test::Mutation::Runner::_take_ready( $schedule, undef ), undef,     'neither waiting invocation may overlap';
    no warnings 'redefine';
    local *Test::Mutation::Runner::_after_task = sub { return 'processed' };
    my $run = { stats => {} };
    Test::Mutation::Runner::_scheduled_result( $run, {}, $schedule, $initial, { passed => 1 } );
    is Test::Mutation::Runner::_take_ready( $schedule, undef ), undef,
      'one of the previous invocations is still active';
    Test::Mutation::Runner::_scheduled_result( $run, {}, $schedule, $concurrent, { passed => 1 } );
    is Test::Mutation::Runner::_take_ready( $schedule, undef ), $repeat, 'the isolated retry takes precedence';
    is Test::Mutation::Runner::_scheduled_result( $run, {}, $schedule, $repeat, { passed => 1 } ), 'processed',
      'a passing isolated observation reaches verdict processing';
    is $repeat->{payload}{conflict}, 1, 'the passing retry remembers its conflict';
    is [ sort keys $run->{warnings}->%* ], [ Test::Mutation::Message::warning( 'conflicting-test', test => 'a.t' ) ],
      'the warning identifies the test that passed alone';
    my $last = test_task('a.t');
    push $schedule->{ready}->@*, $last;
    is Test::Mutation::Runner::_take_ready( $schedule, undef ), $waiting,
      'ordinary measurements resume after the retry';
    is Test::Mutation::Runner::_take_ready( $schedule, undef ), undef, 'later invocations keep the discovered lock';
    Test::Mutation::Runner::_scheduled_result( $run, {}, $schedule, $waiting, { passed => 1 } );
    is Test::Mutation::Runner::_take_ready( $schedule, undef ), $last, 'releasing the lock permits the next invocation';
};

subtest 'a repeated observation preserves the read check and waits for successful restoration' => sub {
    for my $case (
        [ 'failed',         1, 0, 0, 0, 1 ],
        [ 'timed out',      1, 0, 0, 1, 0 ],
        [ 'passed',         1, 1, 0, 0, 0 ],
        [ 'overflowed',     1, 0, 1, 0, 0 ],
        [ 'uncontended',    0, 0, 0, 0, 0 ],
        [ 'restore failed', 1, 0, 0, 0, 1 ],
        [ 'no next task',   1, 0, 0, 0, 1 ],
      )
    {
        my ( $label, $overlapped, $passed, $overflow, $timed_out, $confirm ) = @$case;
        my $run      = { stats => { verifications => 0 } };
        my $job      = { spec  => 'previous.spec', duration => 2 };
        my $task     = test_task( 'a.t', overlapped => $overlapped, confirm_read => $confirm, job => $job );
        my $payload  = $task->{payload};
        my $schedule = { active => { 'a.t' => { $payload => $payload } } };
        my @steps;
        no warnings 'redefine';
        local *Test::Mutation::Runner::_collect = sub { push @steps, 'collect'; return };
        local *Test::Mutation::Runner::_release = sub {
            push @steps, 'restore';
            $job->{restore_error} = 'failed' if $label eq 'restore failed';
            return;
        };
        local *Test::Mutation::Runner::_next_test = sub {
            push @steps, 'schedule';
            return if $label eq 'no next task';
            return test_task('a.t');
        };
        local *Test::Mutation::Runner::_after_task = sub { push @steps, 'verdict'; return 'processed' };
        my $next = Test::Mutation::Runner::_scheduled_result( $run, {}, $schedule, $task,
            { passed => $passed, overflowed => $overflow, timed_out => $timed_out, duration => 3 } );
        my $retry     = $overlapped && !$passed && !$overflow;
        my $scheduled = $label eq 'failed' || $label eq 'timed out';
        is \@steps,
          !$retry ? ['verdict'] : $label eq 'restore failed' ? [qw(collect restore)] : [qw(collect restore schedule)],
          "$label follows the required completion path";
        is $job->{duration}, $retry ? 5     : 2, 'the elapsed time of the discarded observation is counted once';
        is $job->{spec},     $retry ? undef : 'previous.spec',    'a repeat exchanges the original test specification';
        is $run->{stats}{verifications},      $scheduled ? 1 : 0, 'only a scheduled retry counts';
        is $schedule->{retrying}{'a.t'} || 0, $scheduled ? 1 : 0, 'the pending retry owns one reservation';
        is $schedule->{active}, {},           'the completed task has released the last active invocation';
        is $next,
            $scheduled ? test_task( 'a.t', isolated => 1, $confirm ? ( confirm_read => 1 ) : () )
          : $retry     ? undef
          :              'processed', 'a requested direct-read confirmation survives rescheduling';
    }
};

subtest 'a failing isolated retry supplies its own observation without locking the test' => sub {
    my $task     = test_task( 'a.t', isolated => 1 );
    my $schedule = { active => {}, retrying => { 'a.t' => 2 } };
    my $run      = {};
    no warnings 'redefine';
    local *Test::Mutation::Runner::_after_task = sub { return 'processed' };
    is Test::Mutation::Runner::_scheduled_result( $run, {}, $schedule, $task, { passed => 0 } ), 'processed',
      'the failing assertion is evaluated by the verdict rules';
    is $schedule->{retrying}{'a.t'}, 1, 'a single completed retry releases only its own reservation';
    ok !$schedule->{locked}{'a.t'} && !$task->{payload}{conflict}, 'a reproducible failure adds no conflict';
    is $run->{warnings}, undef, 'the isolated failure supplies no warning for contention';
};

subtest 'the scheduler remembers both allowed and blocked pairs of test paths' => sub {
    my $rules = { par => [ { seq => [qw(a.t b.t)] }, 'c.t' ] };
    my ( $active, $blocked, $parallel ) = map { test_task($_) } qw(a.t b.t c.t);
    my $schedule = { ready => [$active], active => {} };
    my %calls;
    ok Test::Mutation::Schedule::compatible( $rules, 'c.t', 'a.t' ), 'the harness admits the parallel pair';
    my $compatible = \&Test::Mutation::Schedule::compatible;
    no warnings 'redefine';
    local *Test::Mutation::Schedule::compatible = sub ( $policy, $candidate, $running ) {
        $calls{$candidate}{$running}++;
        return $compatible->( $policy, $candidate, $running );
    };
    is Test::Mutation::Runner::_take_ready( $schedule, $rules ), $active, 'the first job has no peer';
    $schedule->{ready} = [ $blocked, $parallel ];
    is Test::Mutation::Runner::_take_ready( $schedule, $rules ), $parallel, 'a separate parallel branch is ready';
    is $calls{'b.t'}{'a.t'},                                     1,         'the conflicting paths were checked';
    is $calls{'c.t'}{'a.t'},                                     1,         'the parallel paths were checked';
    delete $schedule->{active}{'c.t'};
    my $again = test_task('c.t');
    push $schedule->{ready}->@*, $again;
    is Test::Mutation::Runner::_take_ready( $schedule, $rules ), $again, 'the parallel branch can run again';
    is \%calls, { 'b.t' => { 'a.t' => 1 }, 'c.t' => { 'a.t' => 1 } }, 'the prior answer is reused for either pair';
    delete $schedule->{active}{'a.t'};
    is Test::Mutation::Runner::_take_ready( $schedule, $rules ), $blocked, 'the serial successor can run beside c.t';
    is $calls{'b.t'}{'c.t'},                                     1,        'the new combination has its own decision';
};

subtest 'a passing isolated baseline supplies its own file and line evidence' => sub {
    my $root  = copy_of('calc');
    my $path  = 'lib/Calc.pm';
    my @tests = qw(a.t b.t);
    for my $coverage (qw(file line)) {
        for my $passes ( 0, 1 ) {
            my $config = Test::Mutation::Settings::of_call( { root => $root, coverage => $coverage } );
            my $run    = { root => $root, project => $root, config => $config, jobs => 2, copies => [] };
            my @calls;
            no warnings 'redefine';
            local *Test::Mutation::Runner::_unmodified =
              sub ( $context, $name, $trace, $jobs, $tests, $purpose, $isolated = 0 ) {
                push @calls, [ $name, $trace ? 1 : 0, $jobs, [@$tests], $purpose, $isolated ];
                my %outcomes;
                for my $test (@$tests) {
                    my $tree = $isolated ? "$root/$test" : $root;
                    my $line = scalar @calls;
                    my $pass = $test eq 'a.t' ? ( $name eq 'separate' ? $passes : $jobs == 1 ) : 1;
                    $outcomes{$test} = {
                        root   => $tree,
                        result => { passed => $pass, duration => $line, early => 0 },
                        record => Test::Mutation::Record::parse(
                            ["begin\t1\nseen\t$tree/$path\nhit\t$tree/$path\t$line\nlines\t$tree/$path\t$line\n"]
                        )
                    };
                }
                return \%outcomes;
              };
            my $baseline = Test::Mutation::Runner::_baseline( $run, \@tests, [$path] );
            my $trace    = $coverage eq 'line' ? 1 : 0;
            is \@calls,
              [
                [ 'baseline', $trace, 2, \@tests, 'baseline_tests', 0 ],
                [ 'baseline', $trace, 1, ['a.t'], 'verifications',  0 ],
                [ 'separate', $trace, 2, \@tests, 'verifications',  1 ],
              ],
              'only the initial failures repeat before the complete suite runs in private copies';
            is $baseline->{failures}, [], 'both tests passed on an accepted unmodified state';
            is [ $baseline->{parallel_safe}, $run->{jobs} ], $passes ? [ 1, 2 ] : [ 0, 1 ],
              'a shared external conflict forces serial measurement';
            for my $test (@tests) {
                my $line = $passes ? 3 : $test eq 'a.t' ? 2 : 1;
                is $baseline->{tests}{$test}{duration}, $line, 'the deadline uses the accepted run';
                is $baseline->{tests}{$test}{files}{$path}{hits}, { $line => 1 },
                  'coverage is read from the tree that produced the accepted result';
            }
            is $baseline->{breakable}{$path}, $passes ? { 3 => 1 } : { 1 => 1, 2 => 1 },
              'breakable lines come from all accepted baselines';
        }
    }
};

subtest 'a completed baseline discards each private test tree after collecting its record' => sub {
    my $project   = copy_of('calc');
    my $config    = Test::Mutation::Settings::of_call( { root => $project } );
    my $workspace = Test::Mutation::Workspace::acquire($project);
    my $run       = {
        root      => $project,
        project   => $project,
        config    => $config,
        workspace => $workspace,
        perl      => $^X,
        targets   => ['lib/Calc.pm'],
        stats     => {},
        listener  => sub { return }
    };
    Test::Mutation::Runner::_prepare_work($run);
    Test::Mutation::Runner::_prepare_project( $run, Test::Mutation::Select::resolve( config => $config ) );
    my @tests   = qw(t/add.t t/sign.t);
    my $results = Test::Mutation::Runner::_unmodified( $run, 'separate', 0, 2, \@tests, 'verifications', 1 );
    my %roots;

    for my $test (@tests) {
        my $outcome = $results->{$test};
        ok $outcome->{result}{passed}, 'the isolated unmodified test finished normally';
        my $tree = $outcome->{root};
        $roots{$tree}++;
        ok $outcome->{record}{served}{"$tree/lib/Calc.pm"}, 'the target was observed inside the private test tree';
        ok !-e $tree, 'the completed test has released its own copy before the next phase';
    }
    is scalar keys %roots,           2, 'each unmodified test had its own project copy';
    is $run->{stats}{verifications}, 2, 'each test counted as an independent verification';
    ok -d $run->{root},        'the baseline still owns its shared project tree';
    ok $workspace->release(0), 'the remaining workspace is released';
};

subtest 'an isolated pass needs a confirmed target load before resolving an overlapping failure' => sub {
    my $root     = copy_of('calc');
    my $config   = Test::Mutation::Settings::of_call( { root => $root } );
    my $mutant   = Test::Mutation::Select::resolve( config => $config )->mutants->[0];
    my $absolute = "$root/" . $mutant->path;
    for my $case (
        [ q{},                                        1 ],
        [ "seen\t$absolute\topened",                  1 ],
        [ "seen\t$absolute\tfailed",                  1 ],
        [ "seen\t$absolute\nseen\t$absolute\tfailed", 1 ],
        [ "seen\t$absolute",                          0 ],
      )
    {
        my ( $observation, $uncertain ) = @$case;
        my $job  = { mutant  => $mutant, duration => 0, syntax => 'ok' };
        my $task = { payload => { job => $job, test => 'a.t', conflict => 1 } };
        no warnings 'redefine';
        local *Test::Mutation::Runner::_collect =
          sub { return Test::Mutation::Record::parse( ["begin\t1\n$observation"] ) };
        Test::Mutation::Runner::_after_test( { root => $root }, {}, $task, { passed => 1, duration => 1 } );
        my $outcome = $job->{outcome};
        is $outcome->{anomaly},
          $uncertain
          ? {
            reason => 'conflicting-test',
            detail => 'a.t passed alone without a confirmed target load after an overlapping failure'
          }
          : undef,
          'the retry preserves uncertainty when the target did not finish loading';
    }
};

## use critic

done_testing;
