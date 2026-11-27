use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(copy_of);
use Test::Mutation::Runner;
use Test::Mutation::Select;
use Test::Mutation::Settings;
use Test::Mutation::Source;
use Test::Mutation::Workspace;

my $root      = copy_of('calc');
my $config    = Test::Mutation::Settings::of_call( { root => $root, baseline_timeout => 37 } );
my $selection = Test::Mutation::Select::resolve( config => $config );
my @mutants   = $selection->mutants->@*;

# A compiler task exposes the exact command and working directory passed to the pool.
## no critic (Subroutines::ProtectPrivateSubs)
subtest 'compilation retains the selected interpreter, file and working tree' => sub {
    my $workspace = Test::Mutation::Workspace::acquire($root);
    my $run       = { root => $root, project => $root, config => $config, workspace => $workspace, perl => $^X };
    Test::Mutation::Runner::_prepare_work($run);
    my $private = copy_of('calc');
    my $job     = { mutant => $mutants[0], copy => { root => $private }, tests => ['t/add.t'] };
    my $path    = $mutants[0]->path;
    for my $case (
        [ 'syntax-original', '-c',          1, q{use charnames ':full';},              1 ],
        [ 'code-original',   '-MO=Deparse', 1, q{use strict;},                         0 ],
        [ 'code-mutant',     '-MO=Deparse', 1, q{use charnames ':full';},              1 ],
        [ 'code-mutant',     '-MO=Deparse', 1, q{use charnames ':full'; my $h = $^H;}, 0 ],
        [ 'code-mutant',     '-MO=Deparse', 1, q{use charnames ':full'; my %h = %^H;}, 0 ],
        [ 'syntax-mutant',   '-c',          1, q{use charnames ':full';},              0 ],
        [ 'code-mutant',     '-MO=Deparse', 0, q{use charnames ':full';},              1 ],
      )
    {
        my ( $kind, $request, $covered, $source, $normalize ) = @$case;
        my $original = $kind =~ /-original\z/;
        my $file     = ( $original ? $root : $private ) . "/$path";
        $job->{tests} = $covered ? ['t/add.t'] : [];
        $run->{sources}{$path} = Test::Mutation::Source->from_bytes( path => $path, bytes => $source );
        my $task   = Test::Mutation::Runner::_compile_task( $run, $job, $kind, $file, $request );
        my $option = $original ? '-MO=Deparse' : $request;
        is [ grep { $_ eq '-MO=Deparse' || $_ eq '-c' } $task->{command}->@* ], [$option],
          'the original is deparsed once for both syntax and equivalence';
        is $task->{command}[-1], $file, 'the compiler reads the intended source';
        is $task->{cwd}, !$covered ? $task->{payload}{tmp} : $original ? $root : $private,
          'an uncovered source runs alone and a covered source runs in its own project state';
        is ref( $task->{digest_line} ), $normalize ? 'CODE' : q{}, 'only standard character name hints are normalized';
        is $task->{payload}{original},  $original  ? $path  : undef, 'only the original can supply shared work';
        is $task->{timeout},            37, 'the first compile uses the configured baseline deadline';
    }
    $run->{targets} = [$path];
    my $schedule_test = sub {
        return Test::Mutation::Runner::_test_task(
            $run,
            root            => $root,
            test            => 't/add.t',
            spec            => "$run->{work}/observed.spec",
            timeout         => 2,
            stop_on_failure => 1,
            payload         => {}
        );
    };
    my $file        = "$private/$path";
    my $first_test  = $schedule_test->();
    my $compile     = Test::Mutation::Runner::_compile_task( $run, $job, 'code-mutant', $file, '-MO=Deparse' );
    my $second_test = $schedule_test->();
    my %directories = map { $_->{payload}{tmp} => 1 } $first_test, $compile, $second_test;
    is scalar keys %directories, 3, 'interleaved live compilers and tests cannot share a temporary directory';
    for my $key (qw(charnames charnames_inverse_ords charnames_name_aliases charnames_ord_aliases)) {
        my $type = $key eq 'charnames' ? 'CODE' : 'HASH';
        my $line = "  \$^H{'$key'} = '$type(0xDeF0)';\n";
        is $compile->{digest_line}->($line), $line =~ s/0xDeF0/*/r,
          'standard character name addresses compare equally across Perl processes';
    }
    my $other_hint = q{$^H{'another_plugin'} = 'CODE(0x2a)';};
    is $compile->{digest_line}->($other_hint), $other_hint, 'custom hints retain the full deparsed line';
    for my $duration ( 0.2, 2.5 ) {
        $run->{original_compile}{$path} = { duration => $duration };
        my $task = Test::Mutation::Runner::_compile_task( $run, $job, 'syntax-mutant', $file, '-c' );
        is $task->{timeout}, $duration < 1 ? 10 : 25, 'a measured compile supplies a deadline with a floor';
    }
    ok $workspace->release(0), 'the compiler leaves its workspace releasable';
};

subtest 'every original compiler observation records the result before the job continues' => sub {
    my $path = $mutants[0]->path;
    for my $case ( [ 0, 'code', 'hash' ], [ 0, q{}, q{} ], [ 0, '0', 'hash' ], [ 2, 'compiler output', q{} ], ) {
        my ( $exit, $output, $digest ) = @$case;
        my $run    = {};
        my $result = {
            exit       => $exit,
            signal     => 0,
            timed_out  => 0,
            overflowed => 0,
            duration   => 2.5,
            output     => $output,
            digest     => 'hash'
        };
        my $task = {
            payload => {
                job      => {},
                kind     => 'code-original',
                original => $path,
                tmp      => "$root/unused-compiler-directory"
            }
        };
        no warnings 'redefine';
        local *Test::Mutation::Runner::_after_code = sub { return 'handled' };    ## no critic (Variables::ProtectPrivateVars)
        is Test::Mutation::Runner::_after_task( $run, {}, $task, $result ), 'handled', 'the job can resume';
        is $run->{original_compile}{$path}, { passed => $exit ? 0 : 1, duration => 2.5, code => $digest },
          'syntax and equivalence share the same completed original compiler observation';
        my $shared = $run->{original_compile}{$path};
        delete $task->{payload}{original};
        $task->{payload}{kind} = 'code-mutant';
        Test::Mutation::Runner::_after_task( $run, {}, $task, { %$result, duration => 9 } );
        is $run->{original_compile}, { $path => $shared }, 'a subsequent mutant never alters the original result';
    }
};

subtest 'only a completed nonempty mutant deparse provides a digest for comparison' => sub {
    for my $case (
        [ {}, 1 ],
        [ { exit       => 1 },   0 ],
        [ { signal     => 9 },   0 ],
        [ { timed_out  => 1 },   0 ],
        [ { overflowed => 1 },   0 ],
        [ { output     => q{} }, 0 ],
        [ { output     => '0' }, 1 ],
      )
    {
        my ( $changes, $usable ) = @$case;
        my $result = {
            exit       => 0,
            signal     => 0,
            timed_out  => 0,
            overflowed => 0,
            digest     => 'fingerprint',
            output     => 'sub answer { 42 }',
            %$changes
        };
        my $job  = {};
        my $task = { payload => { job => $job, original => $mutants[0]->path } };
        Test::Mutation::Runner::_after_code( {}, $task, $result );
        ok !exists $job->{code}, 'the original result stays out of the mutant fingerprint';
        delete $task->{payload}{original};
        Test::Mutation::Runner::_after_code( {}, $task, $result );
        is $job->{code}, $usable ? 'fingerprint' : q{}, 'a failed or empty deparse cannot establish equivalence';
    }
};

subtest 'interruptions retain completed verdicts and account for every attempted test' => sub {
    my ( $finished, $started, $repeated ) = @mutants;
    my $done    = { status        => 'Killed', by => 't/known.t' };
    my $entries = { $finished->id => $done };
    my @unfinished = (
        { mutant => $finished },
        {
            mutant   => $repeated,
            verdict  => { tests => 1 },
            first    => { tests => 4 },
            tests    => [qw(t/add.t t/compare.t)],
            duration => 3
        },
    );
    my @waiting = ( { mutant => $started, verdict => { tests => 0 }, tests => [], duration => 0 } );
    Test::Mutation::Runner::_pending_jobs( sub { return shift @waiting }, $entries, @unfinished );
    is $entries->{ $finished->id }, $done, 'a completed detection retains its test';
    for my $pair ( [ $started, [], 0, 0 ], [ $repeated, [qw(t/add.t t/compare.t)], 5, 3 ] ) {
        my ( $mutant, $tests, $count, $duration ) = @$pair;
        my $entry = $entries->{ $mutant->id };
        is [ $entry->@{qw(mutant status reason by covered_by tests_run duration)} ],
          [ $mutant, 'Pending', 'interrupted', undef, $tests, $count, $duration ],
          'an interrupted attempt retains its coverage, test count and elapsed time';
    }
};

## use critic

# The observers supply controlled test results while the runner manages the temporary project directory.
## no critic (Variables::ProtectPrivateVars Subroutines::ProtectPrivateSubs)
subtest 'original test writes invalidate saved observations in the applicable execution modes' => sub {
    for my $case (
        [ 'a private copy',           1, 0, 1 ],
        [ 'an in-place cache',        0, 1, 1 ],
        [ 'an uncached in-place run', 0, 0, 0 ],
      )
    {
        my ( $label, $copied, $cached, $observes ) = @$case;
        my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
        my $settings =
          Test::Mutation::Settings::of_call( { root => $project, cache => $cached, in_place => !$copied } );
        my $run = { root => $project, project => $project, config => $settings, stats => {}, targets => [] };
        if   ($copied) { $run->{copies} = "$project/slots" }
        else           { $run->{guard}  = { state => Test::Mutation::Runner::_tree($run) } }
        no warnings 'redefine';
        local *Test::Mutation::Runner::_baseline = sub {
            Fixture::write_file( "$project/observation.txt", "new contents\n" );
            return { tests => {} };
        };
        is Test::Mutation::Runner::_observed_baseline( $run, [] ), { tests => {} }, "$label returns the test facts";
        is $run->{baseline_changed}, $observes ? 1   : undef, "$label records the project change when it affects reuse";
        is exists $run->{tree},      $cached   ? T() : F(), "$label retains the updated state only for a guarded cache";
    }
};

subtest 'a complete or fully reused baseline needs no partial-input comparison' => sub {
    my ( $cached, $changed ) = qw(t/cached.t t/changed.t);
    my @all  = ( $cached, $changed );
    my $fact = { breakable => {} };
    for my $case (
        [ 'an in-place update', 1, { $cached => $fact },         [$changed], 1 ],
        [ 'a cold measurement', 1, {},                           [@all],     1 ],
        [ 'a disabled cache',   0, {},                           [@all],     0 ],
        [ 'a complete cache',   1, { map { $_ => $fact } @all }, [],         0 ],
      )
    {
        my ( $label, $enabled, $hits, $missing, $save ) = @$case;
        my $settings = Test::Mutation::Settings::of_call( { root => $root, cache => $enabled } );
        my $run      = { root => $root, config => $settings, test_paths => \@all };
        my ( @runs, @writes, $compared );
        no warnings 'redefine';
        local *Test::Mutation::Runner::_observed_baseline = sub ( $context, $tests ) {
            push @runs, [@$tests];
            return { tests => { map { $_ => $fact } @$tests }, failures => [], parallel_safe => 1 };
        };
        local *Test::Mutation::Runner::_run_inputs = sub { ++$compared; return 'observed' };
        local *Test::Mutation::Runner::_save_originals =
          sub ( $context, $baseline ) { push @writes, $baseline; return };
        my $result = Test::Mutation::Runner::_complete_baseline( $run, { tests => $hits, missing => $missing } );
        is \@runs,                   @$missing ? [ \@all ] : [], "$label controls whether the complete suite must run";
        is $run->{reused_originals}, @$missing ? {} : $hits, "$label only reuses facts from accepted original tests";
        is [ sort keys $result->{tests}->%* ], [ sort @all ], "$label reports every test";
        ok !$compared, "$label needs no second fingerprint for a mixture of old and new test facts";
        is \@writes, $save ? [$result] : [], "$label writes only newly measured facts when caching is enabled";
    }
};
subtest 'partial original results are reused only when the two observations agree' => sub {
    my ( $cached_test, $changed_test ) = qw(t/first.t t/second.t);
    my $record = sub ($line) { return { duration => $line, breakable => { 'lib/Calc.pm' => { $line => 1 } } } };
    for my $case (
        [ 'matching inputs',    0, 1, 0, 'same',      1 ],
        [ 'a changed project',  1, 1, 0, 'same',      0 ],
        [ 'a test conflict',    0, 0, 0, 'same',      0 ],
        [ 'a failed original',  0, 1, 1, 'same',      0 ],
        [ 'unavailable inputs', 0, 1, 0, undef,       0 ],
        [ 'different inputs',   0, 1, 0, 'different', 0 ]
      )
    {
        my ( $label, $changed, $safe, $failed, $shared, $reuse ) = @$case;
        my $run =
          { root => $root, copies => 'available', config => $config, test_paths => [ $cached_test, $changed_test ] };
        my $plan = { tests => { $cached_test => $record->(1) }, missing => [$changed_test], shared => 'same' };
        my ( $trial, @reads, @saved );
        no warnings 'redefine';
        local *Test::Mutation::Runner::_control_copy      = sub { return $trial = File::Temp::tempdir( CLEANUP => 1 ) };
        local *Test::Mutation::Runner::_observed_baseline = sub ( $context, $names ) {
            push @reads, [ $context->{root}, [@$names] ];
            if ( @$names == 1 ) {
                $context->{baseline_changed} = $changed;
                return {
                    tests         => { $changed_test => $record->(2) },
                    parallel_safe => $safe,
                    failures      => $failed ? [ { test => $changed_test } ] : []
                };
            }
            return {
                tests         => { $cached_test => $record->(3), $changed_test => $record->(4) },
                parallel_safe => 1,
                failures      => []
            };
        };
        local *Test::Mutation::Runner::_run_inputs     = sub { return $shared };
        local *Test::Mutation::Runner::_save_originals = sub ( $context, $baseline ) {
            push @saved, $baseline;
            return;
        };
        my $result = Test::Mutation::Runner::_complete_baseline( $run, $plan );
        is \@reads, [ [ $trial, [$changed_test] ], $reuse ? () : [ $root, [ $cached_test, $changed_test ] ] ],
          "$label determines which original tests must be measured";
        ok !-e $trial, "$label releases the temporary copy before returning";
        is [ sort keys $run->{reused_originals}->%* ], $reuse ? [$cached_test] : [],
          "$label retains the verified tests";
        is [ sort keys $result->{breakable}{'lib/Calc.pm'}->%* ], $reuse ? [ 1, 2 ] : [ 3, 4 ],
          "$label publishes the executable lines from the accepted observations";
        is \@saved, [$result], "$label saves the completed baseline once";
    }
};
## use critic

subtest 'a fresh baseline after a cache mismatch supplies every original test fact' => sub {
    my $old     = { tests => { 't/cached.t' => { duration => 1 } }, parallel_safe => 1, failures => [] };
    my $failure = { test  => 't/current.t', output => "1..1\nnot ok 1\n", errors => "changed input\n" };
    my $fresh   = { tests => { 't/current.t' => { duration => 4.5 } }, parallel_safe => 0, failures => [$failure] };
    no warnings 'redefine';
    local *Test::Mutation::Runner::_complete_baseline = sub { return $old };                                         ## no critic (Variables::ProtectPrivateVars)
    local *Test::Mutation::Runner::_mutants = sub ( $run, @ ) { $run->{rechecked_baseline} = $fresh; return [] };    ## no critic (Variables::ProtectPrivateVars)
    my $result = Test::Mutation::Runner::run( $config, sub { return }, { selection => $selection } );
    is $result->tests, [ { name => 't/current.t', duration => 4.5 } ],
      'the report uses the newly measured test and duration';
    is $result->parallel_safe,     0,          'the new observation determines whether tests can run concurrently';
    is $result->baseline_failures, [$failure], 'the failure from the new original run reaches the result';
};

done_testing;
