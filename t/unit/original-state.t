use v5.36;
use Test2::V0;
use File::Temp ();
use Cwd        ();
use lib 't/e2e/lib', 't/lib';
use Fixture qw(write_file);
use Raised;
use Capability;
use POSIX ();
use Test::Mutation::Message;
use Test::Mutation::Runner;
use Test::Mutation::Select;
use Test::Mutation::Settings;
use Test::Mutation::Source;
use Test::Mutation::Tree;
use Test::Mutation::Workspace;

# The runner owns the control states and their effects between test processes.
## no critic (Subroutines::ProtectPrivateSubs Variables::ProtectPrivateVars)
subtest 'a disk-only baseline needs a reproducible difference from the hooked test' => sub {
    my $run     = {};
    my $outcome = {
        map( { $_ => { result => { passed => 0 }, origin => 'initial' } } qw(always disk intermittent) ),
        limit  => { result => { timed_out  => 1 } },
        output => { result => { overflowed => 1 } },
    };
    my @calls;
    my $pass = sub ( $jobs, $tests, $purpose ) {
        my $disk = $run->{try_disk} ? 1 : 0;
        push @calls, [ $disk, $jobs, [@$tests], $purpose ];
        return {
            map {
                $_ => {
                    result => { passed => $_ eq 'intermittent' || $disk && $_ eq 'disk' ? 1 : 0 },
                    origin => 'verified'
                }
            } @$tests
        };
    };
    Test::Mutation::Runner::_disk_baseline( $run, $pass, $outcome, [qw(always intermittent disk limit output)] );
    is \@calls,
      [ [ 1, 1, [qw(always intermittent disk)], 'verifications' ], [ 0, 1, [qw(intermittent disk)], 'verifications' ] ],
      'only completed failures retry on disk and only those passing retry with the hook';
    is $run->{disk_test}, { disk => 1 }, 'only the reproducible difference selects disk observation';
    is [ map { $outcome->{$_}{origin} } qw(always disk intermittent) ], [qw(initial verified initial)],
      'other tests keep the initial observation';
    @calls = ();
    Test::Mutation::Runner::_disk_baseline( $run, $pass, $outcome, [qw(limit output)] );
    is \@calls, [], 'an incomplete test never starts a second baseline';
    Test::Mutation::Runner::_disk_baseline( $run, $pass, $outcome, ['always'] );
    is scalar @calls, 1, 'failing equally on disk needs no third attempt';
};

subtest 'the runner checks the original under the state it will give to the mutant' => sub {
    my @earlier  = qw(a.t b.t);
    my $baseline = { tests => { map { $_ => {} } qw(d.t c.t b.t a.t) } };
    for my $case ( [qw(after after)], [qw(clean clean)], [qw(ordered ordered)], [qw(prerequisite-fails unstable)],
        [qw(test-fails unstable)], [qw(first-test unstable)], )
    {
        my ( $mode, $expected ) = @$case;
        my $work    = File::Temp::tempdir( CLEANUP => 1 );
        my $project = "$work/project";
        my $after   = "$work/after";
        write_file( "$project/state",        'clean' );
        write_file( "$project/.git/HEAD",    'private metadata' );
        write_file( "$project/kept/library", 'dependencies' );
        write_file( "$after/state",          'after' );
        my $config = Test::Mutation::Settings::of_call( { root => $project, link => ['kept'] } );
        my $run    = {
            project => $project,
            root    => $after,
            work    => "$work/jobs",
            config  => $config,
            name    => 'project',
            first   => { previous => 1 }
        };
        my ( @attempts, @paths, @labels );
        no warnings 'redefine';
        local *Test::Mutation::Runner::_unmodified = sub ( $context, $name, $trace, $jobs, $tests, $purpose ) {
            push @labels, $name;
            my $root  = $context->{root};
            my $state = Test::Mutation::Source::read_bytes("$root/state");
            push @attempts, [ $state, [@$tests] ];
            push @paths,    $root;
            is [ $trace, $jobs, $purpose, $context->{first} ], [ 0, 1, 'verifications', {} ],
              'each unmodified control starts without prior launch data';
            my %result;
            for my $test (@$tests) {
                my $preparing = $test ne 'c.t' && $mode ne 'first-test';
                my $passed    = $preparing ? $mode ne 'prerequisite-fails' || $test ne 'b.t' : $mode eq $state;
                $result{$test} = { result => { passed => $passed ? 1 : 0 } };
                write_file( "$root/state", 'ordered' ) if $preparing;
            }
            return \%result;
        };
        my $target    = $mode eq 'first-test' ? 'a.t' : 'c.t';
        my $reference = Test::Mutation::Runner::_verified_reference( $run, $baseline, $target );
        my @wanted    = ( [ 'after', [$target] ] );
        push @wanted, [ 'clean',   [$target] ] if $mode ne 'after';
        push @wanted, [ 'clean',   \@earlier ] if $mode =~ /^(?:ordered|prerequisite-fails|test-fails)$/;
        push @wanted, [ 'ordered', [$target] ] if $mode eq 'ordered' || $mode eq 'test-fails';
        is \@labels, [ map { "control-$_" } 1 .. @wanted ], 'control records use successive execution numbers';
        ok !grep( { !m{/controls/[1-9][0-9]*/project\z} } @paths ), 'every copied reference has a positive slot number';
        is \@attempts, \@wanted, "$mode: controls stop at the first usable state and earlier tests replay in order";
        is [ grep { -d $_ } @paths ], $mode eq 'ordered' ? [ $paths[2] ] : [],
          "$mode: temporary control executions are discarded except an ordered reference";
        is [ $run->{root}, $run->{first} ], [ $after, { previous => 1 } ],
          'control runs leave the measurement roots and launch data intact';

        if ( $expected eq 'after' ) {
            is $reference, { same => 1 }, 'the post-baseline tree is reusable';
        }
        elsif ( $expected eq 'unstable' ) {
            is $reference, { unstable => 1 }, 'the failure also occurs without the mutant';
        }
        else {
            my $ref = $reference->{root};
            is Test::Mutation::Source::read_bytes("$ref/state"), $expected, "the next job starts $expected";
            ok !-e "$ref/.git", 'the clean control omits repository metadata';
            is readlink("$ref/kept"), "$project/kept", 'the control keeps the configured dependency link';
        }
        is Test::Mutation::Source::read_bytes("$project/state"), 'clean', 'the original checkout retains its bytes';
    }
};

subtest 'the backup retains symbolic links and omits entries whose original contents cannot be copied' => sub {
    Capability::has( 'unprivileged', $> != 0, 'permission checks need an unprivileged process' ) or return;
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$root/directory/ordinary", 'original' );
    write_file( "$root/private",            'private' );
    chmod 0, "$root/private" or die "chmod: $!";
    mkdir "$root/unsearchable", oct '600' or die "mkdir: $!";
    POSIX::mkfifo( "$root/stream", oct '700' ) or die "mkfifo: $!";
    symlink 'private', "$root/alias" or die "symlink: $!";
    my $workspace = Test::Mutation::Workspace::acquire($root);
    my $config    = Test::Mutation::Settings::of_call( { root => $root, in_place => 1 } );
    my $run       = { config => $config, root => $root, project => $root, workspace => $workspace };
    Test::Mutation::Runner::_prepare_project( $run, Test::Mutation::Select::resolve( config => $config ) );
    my $guard = $run->{guard};
    is [ sort $guard->{opaque}->@* ], [qw(private stream unsearchable)],
      'an unreadable file, a stream, and an unsearchable directory have no backup bytes';
    is readlink("$guard->{backup}/alias"), 'private', 'a link to an unreadable file retains the link itself';
    is Test::Mutation::Source::read_bytes("$guard->{backup}/directory/ordinary"), 'original',
      'a searchable directory and its ordinary contents remain restorable';
    chmod oct '700', "$root/unsearchable" or die "chmod: $!";
    ok $workspace->release(0), 'the unused backup is removed';
};

subtest 'an opaque entry prevents restoration of itself, its children and its parents' => sub {
    my $work  = File::Temp::tempdir( CLEANUP => 1 );
    my $run   = { project => "$work/project" };
    my $guard = { backup  => "$work/backup", opaque => ['dir/locked'] };
    for my $path (qw(dir dir/locked dir/locked/entry)) {
        my $error =
          Raised::error( sub { Test::Mutation::Runner::_restore_changes( $run, $guard, ["removed $path"] ) } );
        is $error->[1], 'file-unreadable', "$path requires unavailable original bytes";
        like $error->[2], qr/\Q$path\E/, 'the error names the affected path';
    }
    write_file( "$work/backup/dir/locked-open",  'original' );
    write_file( "$work/project/dir/locked-open", 'altered' );
    is Test::Mutation::Runner::_restore_changes( $run, $guard, ['changed dir/locked-open'] ), 1,
      'the restoration reports the one changed entry';
    is Test::Mutation::Runner::_restore_changes( $run, $guard, [] ), 0, 'an unchanged original needs no restoration';
    is Test::Mutation::Source::read_bytes("$work/project/dir/locked-open"), 'original',
      'an unrelated sibling sharing a spelling prefix can still be restored';
};

subtest 'in-place controls restore both the project and the effects of the unmodified retest' => sub {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$root/file",           'initial' );
    write_file( "$root/.git/HEAD",      'metadata' );
    write_file( "$root/output/summary", 'prior report' );
    write_file( "$root/cache/results",  'cache' );
    my $config = Test::Mutation::Settings::of_call(
        { root => $root, in_place => 1, cache_dir => 'cache', report_dir => 'output' } );
    my $workspace = Test::Mutation::Workspace::acquire($root);
    my $run       = { config => $config, project => $root, root => $root, workspace => $workspace, jobs => 4 };
    Test::Mutation::Runner::_prepare_project( $run, Test::Mutation::Select::resolve( config => $config ) );
    my $guard = $run->{guard};
    is Test::Mutation::Source::read_bytes("$guard->{backup}/file"), 'initial',
      'the backup precedes every original test';
    ok !grep( { -e "$guard->{backup}/$_" } qw(.git output cache) ), 'the backup excludes VCS, report and cache data';
    is [ sort keys $run->{warnings}->%* ], [ Test::Mutation::Message::warning('in-place-observation') ],
      'the in-place measurement announces its observation limits';
    is $run->{stats}{copies},         1,        'the initial backup counts once';
    is [ keys %{ $guard->{state} } ], ['file'], 'only the protected project state participates';
    my $baseline = { tests => { map { $_ => {} } qw(d.t c.t b.t a.t) } };
    Test::Mutation::Runner::_begin_in_place( $run, $baseline );
    is [ $run->{jobs}, $run->{setup_tests} ], [ 1, undef ], 'the unchanged project can run one job without replay';
    write_file( "$root/preparation", 'baseline side effect' );
    Test::Mutation::Runner::_begin_in_place( $run, $baseline );
    is $run->{setup_tests}, [qw(a.t b.t c.t d.t)], 'a changed baseline records the project-relative order';
    ok !-e "$root/preparation", 'the changed baseline is restored';

    my $pass = 1;
    my @attempts;
    no warnings 'redefine';
    local *Test::Mutation::Runner::_unmodified = sub ( $context, $name, $trace, $jobs, $tests, $purpose ) {
        like $name, qr/\A(?:setup|restored)-[1-9][0-9]*\z/,
          'setup and restoration own distinct positive execution labels';
        push @attempts, [ $trace, $jobs, [@$tests], $purpose, -e "$root/leftover" ? 1 : 0 ];
        write_file( "$root/control", 'a retest can write too' );
        return { map { $_ => { result => { passed => $_ eq 'b.t' ? $pass : 1 } } } @$tests };
    };
    for my $success ( 0, 1 ) {
        $pass = $success;
        write_file( "$root/leftover", 'previous job' );
        my $job     = { used_project => 1 };
        my $failure = Test::Mutation::Runner::_prepare_in_place_test( $run, $job, 'c.t' );
        is pop @attempts, [ 0, 1, [qw(a.t b.t)], 'verifications', 0 ],
          'only earlier tests replay in the restored project';
        is $job->{used_project}, 1, 'the next release must restore any effects of the attempt';
        is $failure, $pass
          ? undef
          : { reason => 'unstable-test', detail => 'b.t failed while preparing the original state for c.t' },
          'a failing prerequisite identifies the test that failed';
        Test::Mutation::Runner::_release( $run, $job );
        ok !-e "$root/control", 'setup changes are removed on job release';
    }
    my $first_job = {};
    is Test::Mutation::Runner::_prepare_in_place_test( $run, $first_job, 'a.t' ), undef,
      'the first test needs no prerequisite';
    is \@attempts, [], 'the earliest test starts directly';
    delete $run->{setup_tests};
    for my $case ( [ 'Killed', 0, 'NoVerdict' ], [ 'Killed', 1, 'Killed' ], [ 'Survived', 0, 'Survived' ] ) {
        my ( $original_status, $pass_control, $wanted ) = @$case;
        $pass = $pass_control;
        write_file( "$root/leftover", 'mutant side effect' );
        my $job = { used_project => 1, verdict => { status => $original_status, by => 'b.t' } };
        Test::Mutation::Runner::_release( $run, $job );
        ok !exists $job->{used_project}, 'the release consumes the ownership of the project once';
        is $job->{verdict}{status}, $wanted, 'a kill needs a passing original after the change';
        is \@attempts, $original_status eq 'Killed' ? [ [ 0, 1, ['b.t'], 'verifications', 0 ] ] : [],
          'only the test responsible for a detection runs on restored bytes';
        is $job->{verdict}{reason}, 'project-changed', 'a failure of restored bytes names the cause'
          if $wanted eq 'NoVerdict';
        ok !-e "$root/leftover" && !-e "$root/control", 'both the mutation and the control leave a restored checkout';
        @attempts = ();
    }
    $run->{warnings} = {};
    my $unchanged = { used_project => 1, verdict => { status => 'Killed', by => 'b.t' } };
    Test::Mutation::Runner::_release( $run, $unchanged );
    is \@attempts, [], 'an unchanged project needs no control test after release';
    is $run->{warnings}, {}, 'an unchanged project produces no change warning';
    write_file( "$root/$_", 'side effect' ) for qw(a b c d e f g);
    Test::Mutation::Runner::_release( $run, { used_project => 1, verdict => { status => 'Survived' } } );
    my $changes = 'created a, created b, created c, created d, created e and 2 more';
    is [ keys $run->{warnings}->%* ], [ Test::Mutation::Message::warning( 'project-changed', changes => $changes ) ],
      'the change warning lists five sorted paths and the number of remaining paths';
    write_file( "$root/file", 'last change' );
    Test::Mutation::Runner::_release_workspace($run);
    is Test::Mutation::Source::read_bytes("$root/file"), 'initial', 'the final release restores the initial bytes';
    ok !-d $workspace->directory, 'the successful release removes its backup directory';
};

my $fixture_config = Test::Mutation::Settings::of_call( { root => 't/fixtures/calc' } );
my $fixture_mutant = Test::Mutation::Select::resolve( config => $fixture_config )->mutants->[0];

subtest 'each active job serves its installed source from a separate copy' => sub {
    my $project   = Fixture::copy_of('calc');
    my $config    = Test::Mutation::Settings::of_call( { root => $project } );
    my $selection = Test::Mutation::Select::resolve( config => $config );
    my $mutant    = $selection->mutants->[0];
    my $path      = $mutant->path;
    my $source    = $selection->sources->{$path};
    my $workspace = Test::Mutation::Workspace::acquire($project);
    my $run =
      { config => $config, project => $project, root => $project, workspace => $workspace, listener => sub { return } };
    Test::Mutation::Runner::_prepare_project( $run, $selection );
    Test::Mutation::Runner::_prepare_work($run);
    my ( $one, $two ) = map { Test::Mutation::Runner::_job_root( $run, {} ) } 1 .. 2;
    my ($name) = $project =~ m{/([^/]+)\z};
    is [ $one, $two ], [ map { $workspace->directory . "/slot/$_/$name" } 1 .. 2 ],
      'concurrent copies retain the project name under successive slot numbers';
    my ( $file, $spec ) = Test::Mutation::Runner::_write_mutant( $run, $source, $mutant, $one );
    my $expected = $source->to_bytes( $source->replace_span( $mutant->start, $mutant->end, $mutant->replacement ) );
    is Test::Mutation::Source::read_bytes("$one/$path"), $expected, 'the job reads its installed mutant';
    is Test::Mutation::Source::read_bytes($file),        $expected, 'the standalone compiler reads identical bytes';
    like Test::Mutation::Source::read_bytes($spec),
      qr/^target\t\Q$one\/$path\E\t\Q$one\/$path\E\t\Q$project\/$path\E$/m,
      'the hook serves the path installed in the job and records the original checkout separately';
    is Test::Mutation::Source::read_bytes("$two/$path"), $source->to_bytes( $source->text ),
      'the concurrent job has its own unmodified source';
    ok $workspace->release(0), 'both job directories are released';
};

subtest 'a changed checkout cannot run a selection generated from earlier bytes' => sub {
    my $project   = Fixture::copy_of('calc');
    my $config    = Test::Mutation::Settings::of_call( { root => $project } );
    my $selection = Test::Mutation::Select::resolve( config => $config );
    my $mutant    = $selection->mutants->[0];
    my $source    = $selection->sources->{ $mutant->path };
    my $path      = "$project/" . $mutant->path;
    my $edited    = Test::Mutation::Source::read_bytes($path) . "\n1;\n";
    write_file( $path, $edited );
    my $workspace = Test::Mutation::Workspace::acquire($project);
    my $run =
      { config => $config, root => $project, project => $project, workspace => $workspace, listener => sub { return } };
    my $error = Raised::error( sub { Test::Mutation::Runner::_prepare_project( $run, $selection ) } );
    is $error->[1], 'source-changed', 'the measurement checks the actual copied bytes';
    ok $workspace->release(0), 'a failed selection can release its copy';

    for my $inside ( 0, 1 ) {
        my $settings = Test::Mutation::Settings::of_call( { root => $project, in_place => $inside } );
        my $refused  = Raised::error(
            sub { Test::Mutation::Runner::run_command( $settings, $source, $mutant, [ $^X, '-e', 'exit 0' ] ) } );
        is $refused->[1], 'source-changed', 'exec verifies the source again before running the user command';
        is Test::Mutation::Source::read_bytes($path), $edited, 'the newer checkout bytes survive the refused command';
    }
};

subtest 'a failed in-place baseline cannot switch to a disk-only observation' => sub {
    my $project   = Fixture::copy_of('calc');
    my $workspace = Test::Mutation::Workspace::acquire($project);
    my $config    = Test::Mutation::Settings::of_call( { root => $project, in_place => 1 } );
    my $run       = { config => $config, project => $project, root => $project, jobs => 1, workspace => $workspace };
    my @attempts;
    no warnings 'redefine';
    local *Test::Mutation::Runner::_unmodified = sub {
        my $disk = $run->{try_disk} ? 1 : 0;
        push @attempts, $disk;
        return {
            'a.t' => {
                result =>
                  { passed => $disk, duration => 1, errors => 'failed in the original checkout', output => q{} },
                record => Test::Mutation::Record::parse( ["begin\t1\n"] )
            }
        };
    };
    my $baseline = Test::Mutation::Runner::_baseline( $run, ['a.t'], [] );
    is \@attempts, [0], 'only the configured observation ran in the user checkout';
    is [ map { $_->{test} } $baseline->{failures}->@* ], ['a.t'], 'the failing unmodified test prevents scoring';
    ok $workspace->release(0), 'the failed baseline releases its resources';
};

subtest 'the observed load determines whether compilation or a second reading is needed' => sub {
    for my $case (
        [ 'unobserved pass',   1, 'pass',    0, 0, undef,           undef,             0 ],
        [ 'in-place failure',  0, 'fail',    0, 0, undef,           undef,             0 ],
        [ 'unobserved limit',  1, 'timeout', 0, 0, undef,           undef,             0 ],
        [ 'first read',        1, 'fail',    0, 0, undef,           'syntax-original', 1 ],
        [ 'known syntax',      1, 'fail',    0, 0, 'ok',            'read',            1 ],
        [ 'loaded',            1, 'fail',    1, 0, undef,           undef,             0 ],
        [ 'partly compiled',   1, 'fail',    1, 1, undef,           'syntax-original', 0 ],
        [ 'classified syntax', 1, 'fail',    1, 1, 'compile-phase', undef,             0 ],
        [ 'lost record',       1, 'fail',    0, 0, undef,           undef,             0 ],
      )
    {
        my ( $label, $copy, $ending, $served, $failed, $syntax, $expected, $checking ) = @$case;
        my $run = { root => 'original', copies => $copy ? 'slots' : undef };
        my $job = {
            mutant  => $fixture_mutant,
            file    => 'mutant.pm',
            syntax  => $syntax,
            outcome =>
              { result => $ending, served => $served, load_failed => $failed, anomaly => $label eq 'lost record' }
        };
        no warnings 'redefine';
        local *Test::Mutation::Runner::_verify_read  = sub { return 'read' };
        local *Test::Mutation::Runner::_compile_task = sub ( $context, $current, $kind, $path, $switch ) {
            is [ $path, $switch ], [ 'original/' . $fixture_mutant->path, '-c' ],
              'the first syntax check uses the original source';
            return $kind;
        };
        is Test::Mutation::Runner::_check_load( $run, {}, $job ), $expected, "$label schedules the required check";
        is $job->{check_read} || 0, $checking, "$label records whether the missing load needs confirmation";
    }
};

subtest 'a known original compilation determines the next check and the reported syntax' => sub {
    my $path   = $fixture_mutant->path;
    my $parent = File::Temp::tempdir( CLEANUP => 1 );
    for my $passed ( 0, 1 ) {
        my $run      = { config => $fixture_config, copies     => 'slots', root => 'original',  stats   => {} };
        my $original = { mutant => $fixture_mutant, check_read => 1,       file => 'mutant.pm', outcome => {} };
        my $result   = {
            exit       => $passed ? 0 : 1,
            duration   => 0.1,
            errors     => "BEGIN failed--compilation aborted at mutant.pm line 1.\n",
            output     => q{},
            signal     => 0,
            overflowed => 0,
            timed_out  => 0
        };
        my $temporary = File::Temp::tempdir( DIR => $parent );
        my $task = { payload => { kind => 'syntax-original', original => $path, job => $original, tmp => $temporary } };
        no warnings 'redefine';
        local *Test::Mutation::Runner::_compile_task = sub ( $context, $job, $kind, $file, $switch ) {
            return [ $kind, $file, $switch ];
        };
        local *Test::Mutation::Runner::_verify_read = sub { return 'confirm' };
        my $compile = [ 'syntax-mutant', 'mutant.pm', '-c' ];
        is Test::Mutation::Runner::_after_task( $run, {}, $task, $result ), $compile,
          'checking a direct read requires compiling the mutant after either original result';
        for my $served ( 0, 1 ) {
            my $job = {
                mutant  => $fixture_mutant,
                file    => 'mutant.pm',
                outcome => { result => 'fail', served => $served, load_failed => 1 }
            };
            my $next = Test::Mutation::Runner::_check_load( $run, {}, $job );
            is $next, $passed || !$served ? $compile : undef,
              'a served target uses the known original result and an unobserved direct read still needs checking';
            is $job->{syntax}, !$passed && $served ? 'standalone' : undef,
              'only a served target with an unsuccessful original check is immediately classified';
        }
        my $served = { mutant => $fixture_mutant, file => 'mutant.pm', outcome => {} };
        is Test::Mutation::Runner::_after_syntax( $run, {},
            { payload => { job => $served, kind => 'syntax-original' } }, $result ),
          $passed ? $compile : undef, 'a served target proceeds to the mutant only after a successful original check';
        for my $succeeded ( 0, 1 ) {
            my $job  = { mutant => $fixture_mutant, file => 'mutant.pm', check_read => 1, outcome => {} };
            my $next = Test::Mutation::Runner::_after_syntax(
                $run, {},
                { payload        => { job => $job, kind => 'syntax-mutant' } },
                { %$result, exit => $succeeded ? 0 : 1 }
            );
            my $syntax = !$passed ? 'standalone' : $succeeded ? 'ok' : 'compile-phase';
            is [ $next, $job->{syntax}, $job->{outcome}{syntax} ], [ 'confirm', $syntax, $syntax ],
              'the read and its verdict retain the classification from both compilation results';
        }
    }
};

subtest 'confirming a direct source read uses a restored copy and records the second observation' => sub {
    for my $case (
        [ 'compile-phase', 0, 'compile-error' ],
        [ 'ok',            0, 'repeat' ],
        [ 'standalone',    0, 'repeat' ],
        [ 'ok',            1, 'stop' ]
      )
    {
        my ( $syntax, $broken, $decision ) = @$case;
        my $run = { stats      => { verifications => 0 } };
        my $job = { check_read => 1, syntax => $syntax, spec => 'first.spec', outcome => {} };
        my @actions;
        no warnings 'redefine';
        local *Test::Mutation::Runner::_release = sub {
            push @actions, 'release';
            $job->{restore_error} = 'failed to restore the source' if $broken;
            return;
        };
        local *Test::Mutation::Runner::_next_test = sub {
            push @actions, 'schedule';
            return { payload => { previous_spec => exists $job->{spec} ? 1 : 0 } };
        };
        my $repeat = Test::Mutation::Runner::_verify_read( $run, {}, $job );
        ok !exists $job->{check_read}, 'the pending source-read check is consumed';
        is \@actions, $decision eq 'repeat' ? [qw(release schedule)] : $broken ? ['release'] : [],
          'a failed restore or compilation cannot start a second test';
        is $repeat, $decision eq 'repeat' ? { payload => { confirm_read => 1, previous_spec => 0 } } : undef,
          'the repeated task uses a fresh specification and requests the confirming observation';
        is $run->{stats}{verifications}, $decision eq 'repeat' ? 1 : 0, 'only a scheduled observation counts';
        is $job->{outcome}{read_check}, $decision eq 'compile-error' ? 'compile-error' : undef,
          'a known compile failure provides the terminal result';
    }
};

subtest 'a job exchanges its copy when the next test needs a different verified reference' => sub {
    for my $case (
        [ undef,     undef,               'working', 0 ],
        [ 'working', { same => 1 },       'working', 0 ],
        [ 'working', { root => 'clean' }, 'clean',   1 ],
        [ 'clean',   { root => 'clean' }, 'clean',   0 ],
        [ 'clean',   undef,               'working', 1 ],
        [ 'broken',  { root => 'clean' }, 'clean',   1 ]
      )
    {
        my ( $previous, $proof, $expected, $exchange ) = @$case;
        my $run = { config => $fixture_config, root => 'working', controls => { 'test.t' => $proof } };
        my $job = { mutant => $fixture_mutant, tests => ['test.t'], index => 0, raw => 0 };
        if ( defined $previous ) {
            $job->{copy} = { root => 'slot', reference => $previous };
            $job->{spec} = 'previous.spec';
        }
        my $baseline = { tests => { 'test.t' => { duration => 1, anomalies => {} } } };
        my @actions;
        no warnings 'redefine';
        local *Test::Mutation::Runner::_release = sub {
            push @actions, 'release';
            delete $job->{copy};
            $job->{restore_error} = 'restoration failed' if $previous eq 'broken';
            return;
        };
        local *Test::Mutation::Runner::_write_mutant = sub {
            push @actions, 'place';
            return ( 'mutant.pm', 'fresh.spec' );
        };
        local *Test::Mutation::Runner::_test_task = sub ( $context, %args ) {
            push @actions, 'schedule';
            return { spec => $args{spec} };
        };
        my $next   = Test::Mutation::Runner::_next_test( $run, $job, $baseline );
        my $broken = defined $previous && $previous eq 'broken';
        my @expected;
        push @expected, 'release' if $exchange;
        push @expected, 'place'   if !$broken && ( $exchange || !defined $previous );
        push @expected, 'schedule' unless $broken;
        is \@actions, \@expected, 'the prior copy is released before placement on a different reference';
        is $job->{starting_tree}, $broken ? undef : $expected, 'the job records its selected reference';
        is $next, $broken ? undef : { spec => $exchange || !defined $previous ? 'fresh.spec' : 'previous.spec' },
          'only a compatible placement can supply the next specification';
    }
};

subtest 'the next test reports a failed setup before an anomaly found in its baseline' => sub {
    my $prior  = { reason => 'loaded-around-hook' };
    my $failed = { reason => 'unstable-test' };
    for my $case ( [ 0, $prior, $prior ], [ 1, $prior, $failed ], [ 1, undef, $failed ], [ 0, undef, undef ] ) {
        my ( $guarded, $anomaly, $expected ) = @$case;
        my $run = { config => $fixture_config, root => 'working', guard => $guarded };
        my $job = { mutant => $fixture_mutant, spec => 'current.spec', tests => ['test.t'], index => 0, raw => 0 };
        my $baseline =
          { tests => { 'test.t' => { duration => 1, anomalies => { $fixture_mutant->path => $anomaly } } } };
        my @prepared;
        no warnings 'redefine';
        local *Test::Mutation::Runner::_prepare_in_place_test = sub { push @prepared, 1; return $failed };
        local *Test::Mutation::Runner::_test_task             = sub ( $context, %args ) { return $args{payload} };
        my $task = Test::Mutation::Runner::_next_test( $run, $job, $baseline );
        is $task->{baseline_anomaly}, $expected, 'the scheduled test retains the most immediate cause';
        is scalar @prepared,          $guarded,  'an in-place test prepares the checkout once';
    }
};

subtest 'reusing and finishing a specification removes its disk observation and preserves other jobs' => sub {
    my $work = File::Temp::tempdir( CLEANUP => 1 );
    my $run =
      { config => $fixture_config, work => $work, root => 'working', project => 'working', listener => sub { } };
    write_file( "$work/other.spec.disk", 'another job' );
    my $file = "$work/changed.pm";
    for my $kind (qw(regular dangling)) {
        my $disk = "$work/job.spec.disk";
        if ( $kind eq 'regular' ) { write_file( $disk, 'a stale observation' ) }
        else                      { symlink 'missing-spec', $disk or die "symlink: $!" }
        my $spec = Test::Mutation::Runner::_spec( $run, 'working', 'job', 0, [] );
        ok !-e $disk && !-l $disk, 'a regenerated specification discards its earlier observation';
        write_file( $file, 'changed' );
        if ( $kind eq 'regular' ) { write_file( $disk, 'an observation of the current mutant' ) }
        else {
            unlink $disk if -l $disk;
            symlink 'missing-spec', $disk or die "symlink: $!";
        }
        my $job = {
            file     => $file,
            spec     => $spec,
            mutant   => $fixture_mutant,
            tests    => [],
            duration => 0,
            verdict  => Test::Mutation::Verdict::start()
        };
        Test::Mutation::Runner::_finish( $run, $job );
        is [ grep { -e $_ || -l $_ } $file, $spec, $disk ], [], 'all entries belonging to the finished job are removed';
    }
    mkdir "$work/conflict.spec.disk" or die "mkdir: $!";
    my $error = Raised::error( sub { Test::Mutation::Runner::_spec( $run, 'working', 'conflict', 0, [] ) } );
    is $error->[1], 'file-unremovable', 'a directory at the observation path cannot be replaced as a file';
    ok -d "$work/conflict.spec.disk", 'unrelated directory contents are preserved';
    is Test::Mutation::Source::read_bytes("$work/other.spec.disk"), 'another job',
      'a neighboring job retains its observation';
};

subtest 'a command sees the mutant in its requested mode and restores the calling process' => sub {
    my $root    = Fixture::copy_of('calc');
    my $outside = File::Temp::tempdir( CLEANUP => 1 );
    my $caller  = Cwd::getcwd();
    my $program = "$outside/inspect.pl";
    write_file( $program, <<'PERL' );
use Cwd ();
use Calc;
open my $out, '>', $ARGV[0] or die "open: $!";
print {$out} join "\n", Cwd::getcwd(), Calc::add(6, 4), $ENV{HARNESS_ACTIVE} // 'absent',
  $ENV{HARNESS_VERSION} // 'absent', $ENV{TEST_MUTATION_GENERATION} // 0;
close $out or die "close: $!";
exit 17;
PERL
    my $original = Test::Mutation::Source::read_bytes("$root/lib/Calc.pm");
    local $ENV{HARNESS_ACTIVE}  = undef;
    local $ENV{HARNESS_VERSION} = undef;
    delete @ENV{qw(HARNESS_ACTIVE HARNESS_VERSION)};
    my $generation = $ENV{TEST_MUTATION_GENERATION} || 0;

    for my $inside ( 0, 1 ) {
        my $config   = Test::Mutation::Settings::of_call( { root => $root, in_place => $inside } );
        my $selected = Test::Mutation::Select::resolve( config => $config );
        my ($mutant) = grep { $_->description eq 'replaced + with -' } $selected->mutants->@*;
        my $source   = $selected->sources->{ $mutant->path };
        my $output   = "$outside/out-$inside";
        my $status =
          Test::Mutation::Runner::run_command( $config, $source, $mutant, [ $^X, '-Ilib', $program, $output ] );
        is Cwd::getcwd(), $caller, 'the library returns in the calling directory';
        is $status,       17,      'the exit status of the user command is preserved';
        my ( $directory, @values ) = split /\n/, Test::Mutation::Source::read_bytes($output);
        is \@values, [ 2, 'absent', 'absent', $generation + $inside ],
          'the command inherits the caller environment and loads the requested mutant';
        is $directory eq $root ? 1 : 0, $inside, 'the working directory matches the selected execution mode';
        is Test::Mutation::Source::read_bytes("$root/lib/Calc.pm"), $original,
          'the checkout preserves the unmodified source';
    }
};

subtest 'mutation exec distinguishes a missing command from a command without execute permission' => sub {
    my $project   = Fixture::copy_of('calc');
    my $outside   = File::Temp::tempdir( CLEANUP => 1 );
    my $config    = Test::Mutation::Settings::of_call( { root => $project } );
    my $selection = Test::Mutation::Select::resolve( config => $config );
    my $mutant    = $selection->mutants->[0];
    my $source    = $selection->sources->{ $mutant->path };
    my $caller    = Cwd::getcwd();
    write_file( "$outside/denied", "#!$^X\nexit 0;\n" );
    chmod oct '600', "$outside/denied" or die "chmod: $!";

    for my $case ( [qw(missing command-not-found)], [qw(denied command-not-runnable)] ) {
        my ( $name, $id ) = @$case;
        my $program = "$outside/$name";
        my $error =
          Raised::error( sub { Test::Mutation::Runner::run_command( $config, $source, $mutant, [$program] ) } );
        is $error->[1], $id, 'a failed launch reports the reason provided by the operating system';
        like $error->[2], qr/\Q$program\E/, 'the diagnostic identifies the user command';
        is Cwd::getcwd(), $caller, 'a failed launch restores the calling directory';
    }
};

subtest 'an incomplete cleanup keeps the backup available for recovery' => sub {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$root/file", 'initial' );
    my $workspace = Test::Mutation::Workspace::acquire($root);
    my $config    = Test::Mutation::Settings::of_call( { root => $root, in_place => 1 } );
    my $run       = { root => $root, project => $root, config => $config, workspace => $workspace };
    Test::Mutation::Runner::_prepare_project( $run, Test::Mutation::Select::resolve( config => $config ) );
    my $backup = $run->{guard}{backup};
    {
        no warnings 'redefine';
        my @finishes = ( 0, 1 );
        local *Test::Mutation::Workspace::Processes::finish = sub { return shift @finishes };
        my $error = Raised::error( sub { Test::Mutation::Runner::_release_workspace($run) } );
        is $error->[1], 'directory-unopenable', 'a live test process prevents final restoration';
        like $error->[2], qr/\Q$backup\E.*still hold/, 'the error identifies the backup and the live processes';
    }
    ok -f $workspace->directory . '/kept', 'a releasable backup survives the following measurement';
    is Test::Mutation::Source::read_bytes("$backup/file"), 'initial',
      'the original bytes survive an unsuccessful release';
    Test::Mutation::Tree::remove( $workspace->directory );
};

## use critic

done_testing;
