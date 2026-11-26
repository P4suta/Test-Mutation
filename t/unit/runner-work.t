use v5.36;
use Test2::V0;
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
    my @jobs    = (
        { mutant => $finished },
        { mutant => $started, verdict => { tests => 0 }, tests => [], duration => 0 },
        {
            mutant   => $repeated,
            verdict  => { tests => 1 },
            first    => { tests => 4 },
            tests    => [qw(t/add.t t/compare.t)],
            duration => 3
        },
    );
    Test::Mutation::Runner::_pending_jobs( \@jobs, $entries );
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

done_testing;
