use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Cwd            ();
use File::Basename ();
use File::Temp     ();
use Capability;
use Fixture qw(copy_of write_file);
use Samples;
use World;
use Test::Mutation::CLI;
use Test::Mutation::Error;
use Test::Mutation::Interrupted;
use Test::Mutation::Runner;

# The command plans before it acts: the plan reads the arguments, the facts of its world, and the configuration file.
# Carrying the plan out is the one step that changes the directory, starts a test, and prints.

my $root      = copy_of('calc');
my $elsewhere = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );

sub plan_of ( $argv, %fact ) {
    return World::observe( $argv, cwd => $root, %fact, run => 'cheap' )->{plan};
}

sub refusal_of ( $argv, %fact ) {
    my $plan = plan_of( $argv, %fact );
    return $plan->{refused} ? [ $plan->{refused}->@{qw(status text)} ] : 'no refusal';
}

subtest 'the plan changes no directory and no search path' => sub {
    my $here = Cwd::getcwd();
    local @INC = ( 'relative/entry', @INC );
    my @before = @INC;
    my $plan   = Test::Mutation::CLI::plan(
        argv  => [ '--root', $root, 'list' ],
        world => { World::facts(), out => \*STDOUT, err => \*STDERR },
    );
    is $plan->{command}, 'list',   'the plan names the command';
    is Cwd::getcwd(),    $here,    'the directory of the process stays';
    is \@INC,            \@before, 'and so does the search path';
};

subtest 'the plan names the command, the directory, the settings, and the operands' => sub {
    my $plan = plan_of( [ 'show', 'abc', '--jobs', 2, 'def' ] );
    is [ $plan->@{qw(command directory operands)} ], [ 'show', undef, [ 'abc', 'def' ] ], 'a command with operands';
    is [ $plan->{config}->jobs, $plan->{config}->root ], [ 2, $root ], 'the settings, with the directory of the world';

    is [
        map { plan_of($_)->{command} } ['list'],
        [ 'show',  'a' ],
        [ 'exec',  'a', 'b' ],
        [ 'merge', 'a' ],
        ['mutators'], ['run']
      ],
      [qw(list show exec merge mutators run)], 'the first word names the command';
    is plan_of( [ '--jobs', 3 ] ), hash { field command => 'run'; field operands => []; etc },
      'run is the default command';
    is [ plan_of( ['mutators'] )->@{qw(config processors)} ], [ undef, undef ],
      'mutators reads no settings and counts no processor';
    is plan_of( ['list'] )->{processors}, { count => 4, source => 'online' }, 'a plan with settings holds the count';

    is plan_of( [ '--version', 'extra' ] ),
      { command => 'version', directory => undef, config => undef, operands => ['extra'], processors => undef },
      'the version';
    is [ map { plan_of($_)->{command} } ['--help'], ['-h'], [ '--help', '--bogus' ] ], [qw(help help help)], 'the help';
    is plan_of( [ 'list', '--help' ] )->{refused}{status}, 2, 'a later --help is an option of the command';
};

subtest 'the plan reads the project through the directory that --root names' => sub {
    my ( $name, $parent ) = File::Basename::fileparse($root);
    my $relative = plan_of( [ '--root', $name, 'list' ], cwd => $parent );
    is [ $relative->{directory}, $relative->{config}->root ], [ $name, $root ],
      'a relative directory counts from the world';

    symlink $root, "$elsewhere/link" or die "symlink: $!";
    is plan_of( [ 'list', '-C', "$elsewhere/link" ], cwd => $elsewhere )->{config}->root, $root,
      'the root is the place that a link leads to';

    my $configured = copy_of('calc');
    write_file( "$configured/mutation.toml", "jobs = 7\n" );
    write_file( "$configured/ci.toml",       "jobs = 5\n" );
    write_file( "$elsewhere/mutation.toml",  "jobs = 9\n" );
    is plan_of( ['list'], cwd => $configured )->{config}->jobs, 7, 'mutation.toml of the directory of the world';
    is plan_of( [ 'list', '--root', $configured ], cwd => $elsewhere )->{config}->jobs, 7,
      'mutation.toml of the named directory';
    is plan_of( [ 'list', '--root', $configured, '--config', 'ci.toml' ], cwd => $elsewhere )->{config}->jobs, 5,
      'a named file counts from the named directory';
    is plan_of( [ 'list', '--config', "$configured/ci.toml" ] )->{config}->jobs, 5, 'a named file with its full path';
    is plan_of( ['list'] )->{config}->jobs,                                      3, 'no file leaves the defaults';

    like refusal_of( [ 'list', '--root', $configured, '--config', 'absent.toml' ], cwd => $elsewhere ),
      [ 2, qr/\Amutation: cannot read absent[.]toml: [^\n]+\n\z/ ], 'a missing file has the name the user gave';
    like refusal_of( [ 'list', '--config', q{} ] ), [ 2, qr/\Amutation: cannot read : [^\n]+\n\z/ ],
      'and so has an empty name';
    write_file( "$configured/mutation.toml", "jobs = = 2\n" );
    like refusal_of( [ 'list', '--root', $configured ], cwd => $elsewhere ),
      [ 2, qr/\Amutation: mutation[.]toml: [^\n]+\n\z/ ],
      'a malformed file has its name';
    is plan_of( [ 'mutators', '--root', $configured ], cwd => $elsewhere )->{command}, 'mutators',
      'mutators never reads the file';

    is refusal_of( ['list'], cwd => undef ),
      [ 2, qq{mutation: Undef did not pass type constraint "Str" (in \$_{"root"})\n} ],
      'a process whose directory is gone has no project';
    is [ map { plan_of( $_, cwd => undef )->{command} } ['--version'], ['mutators'], [ '--root', $root, 'list' ] ],
      [qw(version mutators list)], 'and it still answers what needs none';
    is World::observe( [ '--root', $root, 'list', '--shard', '1/19' ], cwd => undef )->{exit}, 0,
      'a named directory with its full path is a project all the same';
};

subtest 'the plan takes the processors and the environment from its world' => sub {
    my $jobs = sub ($count) {
        plan_of( ['list'], processors => sub { { count => $count, source => 'quota' } } )->{config}->jobs;
    };
    is [ map { $jobs->($_) } 1, 2, 4, 8 ], [ 1, 1, 3, 7 ],
      'the jobs are one less than the processors, and at least one';
    my $formats = sub ($env) { plan_of( ['list'], env => $env )->{config}->formats };
    is $formats->( { GITHUB_ACTIONS => 'true' } ), [qw(terminal json html github)], 'GitHub Actions adds its report';
    is [
        map { $formats->($_) } {},
        { GITHUB_ACTIONS => 'false' },
        { GITHUB_ACTIONS => undef },
        { GITHUB_ACTIONS => '1' }
      ],
      [ map { [qw(terminal json html)] } 1 .. 4 ], 'and any other value leaves it out';
    my $called = 0;
    plan_of( [$_], processors => sub { $called++; { count => 4, source => 'online' } } )
      for qw(--version --help mutators);
    is $called, 0, 'a command without settings asks for no processor count';
};

subtest 'the plan refuses with a status and the text for standard error' => sub {
    is refusal_of( [ 'list', '--bogus', '--also-bogus' ] ),
      [ 2, "Unknown option: bogus\nUnknown option: also-bogus\n" ],
      'every complaint of the option parser';
    is refusal_of( [ 'list', '--jobs', 0 ] ), [ 2, qq{mutation: Must be a positive integer (in \$args->{"jobs"})\n} ],
      'a value outside its type';
    is refusal_of( [ 'run', 'surplus' ] ), [ 2, "mutation: unexpected argument surplus\n" ], 'a stray argument of run';
    is refusal_of( ['surplus'] ), [ 2, "mutation: unexpected argument surplus\n" ], 'and of the default command';
    is refusal_of( [ 'mutators', 'surplus', 'more' ] ), [ 2, "mutation: unexpected argument surplus\n" ],
      'and of mutators';
    is refusal_of( ['show'] ), [ 2, "mutation: show needs a mutant identifier\n" ], 'show without an identifier';
    is refusal_of( ['exec'] ), [ 2, "mutation: exec needs a mutant identifier and a command\n" ],
      'exec without anything';
    is refusal_of( [ 'exec', 'abc' ] ), [ 2, "mutation: exec needs a mutant identifier and a command\n" ],
      'exec without a command';
    is refusal_of( ['merge'] ), [ 2, "mutation: merge needs the report of every part\n" ], 'merge without a report';
    is [
        map { ref refusal_of($_) } ['list'],
        [ 'list',  'a', 'b' ],
        [ 'show',  'a', 'b' ],
        [ 'exec',  'a', 'b', 'c' ],
        [ 'merge', 'a', 'b' ]
      ],
      [ q{}, q{}, q{}, q{}, q{} ], 'the operands that the commands accept today';
    is refusal_of( [ 'show', '--jobs', 0 ] ), [ 2, qq{mutation: Must be a positive integer (in \$args->{"jobs"})\n} ],
      'the settings are checked before the operands';
};

subtest 'the plan refuses a directory that the command could not enter' => sub {
    write_file( "$elsewhere/plain", "a file\n" );
    my $reason = sub ($directory) { refusal_of( [ '--root', $directory, '--help' ], cwd => $elsewhere ) };
    is $reason->('none'),  [ 2, "mutation: cannot enter none: No such file or directory\n" ], 'a missing directory';
    is $reason->('plain'), [ 2, "mutation: cannot enter plain: Not a directory\n" ],          'a file';
    is $reason->('plain/below'), [ 2, "mutation: cannot enter plain/below: Not a directory\n" ],
      'a path through a file';
    is $reason->(q{}), [ 2, "mutation: cannot enter : No such file or directory\n" ], 'an empty name';
    is refusal_of( [ '--root', 'none', '--bogus' ], cwd => $elsewhere ),
      [ 2, "mutation: cannot enter none: No such file or directory\n" ], 'the directory comes before the options';
    if ( Capability::has( 'unprivileged', $> != 0, 'the superuser enters every directory' ) ) {
        mkdir "$elsewhere/closed", 0600 or die "mkdir: $!";
        is $reason->('closed'), [ 2, "mutation: cannot enter closed: Permission denied\n" ],
          'a directory without the right';
        chmod 0700, "$elsewhere/closed" or die "chmod: $!";
    }
};

subtest 'carrying out a refusal prints its text and returns its status' => sub {
    my $refused = World::observe( [ 'list', '--bogus' ], cwd => $root );
    is [ $refused->@{qw(exit stdout stderr died)} ], [ 2, q{}, "Unknown option: bogus\n", undef ],
      'the refusal of a plan';
    my $version = World::observe( ['--version'], cwd => $root );
    is [ $version->@{qw(exit stdout stderr)} ], [ 0, "mutation $Test::Mutation::CLI::VERSION\n", q{} ], 'the version';
    my $help = World::observe( [ '--help', 'extra' ], cwd => $root );
    like [ $help->@{qw(exit stdout stderr)} ],
      [ 0, qr/\AUsage: mutation \[run\] \[options\]\n.*--help +Print this text\n\z/s, q{} ],
      'the help';
};

subtest 'carrying out a plan enters the directory and prints to the streams of the world' => sub {
    my $listed = World::observe( [ 'list', '--shard', '1/19' ], cwd => $root );
    like [ $listed->@{qw(exit stdout stderr)} ],
      [ 0, qr/\A[0-9a-f]{12}  lib\/Calc[.]pm:5:10  sub-body  [^\n]+\n1 mutant\n\z/, q{} ],
      'list prints to the output of the world';
    my ($id) = $listed->{stdout} =~ /\A([0-9a-f]{12})/;
    like World::observe( [ 'show', $id ], cwd => $root )->{stdout}, qr/\A$id  [^\n]+\n--- lib\/Calc[.]pm\n/, 'show';
    is [ World::observe( [ 'show', 'zzzz' ], cwd => $root )->@{qw(exit stdout stderr)} ],
      [ 2, q{}, "mutation: no mutant has the identifier zzzz\n" ], 'an identifier without a mutant';
    is [ World::observe( [ 'exec', 'zzzz', '--', 'true' ], cwd => $root )->@{qw(exit stdout stderr)} ],
      [ 2, q{}, "mutation: no mutant has the identifier zzzz\n" ], 'and the same for exec';
    like World::observe( ['mutators'], cwd => $root )->{stdout},
      qr/^arithmetic +default +Replaces an arithmetic operator/m,
      'mutators';
    is [ World::observe( [ 'merge', 'none.json' ], cwd => $root )->@{qw(exit stdout)} ], [ 2, q{} ],
      'merge without its file';

    my $here = Cwd::getcwd();
    open my $errors, '>', \my $text or die "open: $!";
    my $world = { World::facts(), out => \*STDOUT, err => $errors };
    my $plan  = Test::Mutation::CLI::plan( argv => [ '--root', $root, 'list' ], world => $world );
    my ( @inc, $entered );
    {
        no warnings 'redefine';
        local *Test::Mutation::Runner::analyze = sub { @inc = @INC; $entered = Cwd::getcwd(); die ['no text'] };
        local @INC                             = ( 'relative/entry', @INC );
        is Test::Mutation::CLI::execute( $plan, $world ), 6, 'an error that is no text ends the command with status 6';
        chdir $here or die "chdir: $!";
    }
    is [ $inc[0], $entered ], [ "$here/relative/entry", $root ],
      'the command enters the directory, and a relative entry of the search path names its place in full';
    is $text, "mutation: internal error: ARRAY\n", 'the error has its line, which names the type of the value';
    $text = q{};
    seek $errors, 0, 0 or die "seek: $!";
    is Test::Mutation::CLI::execute( { $plan->%*, directory => 'gone' }, { $world->%*, err => $errors } ), 2,
      'a directory that vanished after the plan is a usage error';
    is $text,         "mutation: cannot enter gone: No such file or directory\n", 'with its line';
    is Cwd::getcwd(), $here,                                                      'and the command stays where it was';
};

subtest 'the errors of a run end the command with one line and the status of their kind' => sub {
    my $failing = sub ( $failure, @line ) {
        no warnings 'redefine';
        local *Test::Mutation::Runner::analyze = $failure;
        return [ World::observe( @line ? \@line : ['list'], cwd => $root )->@{qw(exit stdout stderr)} ];
    };
    my $usage       = sub { Test::Mutation::Error::raise( 'mutator-unknown', names => 'nonesuch' ) };
    my $environment = sub { Test::Mutation::Error::raise( 'file-unreadable', path  => 'lib/A.pm', reason => 'gone' ) };
    is $failing->($usage),       [ 2, q{}, "mutation: unknown mutator: nonesuch\n" ],  'a usage error';
    is $failing->($environment), [ 5, q{}, "mutation: cannot read lib/A.pm: gone\n" ], 'an error of the environment';
    is $failing->( sub { die 'the analysis broke' } ), [ 6, q{}, "mutation: internal error: the analysis broke\n" ],
      'an error without a type is an internal error, and its line shows no place in the code';
    is $failing->( sub { die "first line\nsecond line\n" } ), [ 6, q{}, "mutation: internal error: first line\n" ],
      'an internal error of several lines keeps the first';
    is $failing->( sub { die "\n" } ), [ 6, q{}, "mutation: internal error: \n" ], 'an error without a text';
    is $failing->( sub { die bless {}, 'Some::Exception' } ), [ 6, q{}, "mutation: internal error: Some::Exception\n" ],
      'an exception object without a text names its class';
    is $failing->( sub { die Test::Mutation::Interrupted->new( signal => 'TERM' ) } ),
      [ 143, q{}, "mutation: interrupted by SIGTERM\n" ], 'an interruption';

    my @exec = ( 'exec', 'zzzz', q{--}, 'true' );
    is $failing->( $usage, @exec ), [ 2, q{}, "mutation: unknown mutator: nonesuch\n" ],
      'a usage error of exec keeps its status, since nothing ran';
    is $failing->( $environment, @exec ), [ 125, q{}, "mutation: cannot read lib/A.pm: gone\n" ],
      'an error of the environment inside exec has the status of exec itself';
    is $failing->( sub { die 'the analysis broke' }, @exec ),
      [ 125, q{}, "mutation: internal error: the analysis broke\n" ], 'and so has an internal error';
    is $failing->( sub { die Test::Mutation::Interrupted->new( signal => 'QUIT' ) }, @exec ),
      [ 131, q{}, "mutation: interrupted by SIGQUIT\n" ], 'an interruption of exec keeps the status of its signal';
};

subtest 'a run that ends without success says why in one line' => sub {
    my $failure = [ { test => 't/a.t', output => "not ok 1\n", errors => q{} } ];
    my $ended   = sub ( $result, @line ) {
        no warnings 'redefine';
        local *Test::Mutation::Runner::run = sub { return $result };
        my $observation =
          World::observe( [ 'run', '--format', 'json', '--report-dir', "$elsewhere/out", @line ], cwd => $root );

        # The first line of a run names its processors, and the outcome follows it.
        my ( $first, $rest ) = split /\n/, $observation->{stderr}, 2;
        is $first, '4 processors online', 'the first line of the run';
        return [ $observation->{exit}, $rest ];
    };
    is $ended->( Samples::result( statuses => [qw(Killed Killed Survived)] ), '--min-score', 67 ),
      [ 1, "mutation: the score 66.7% is below the gate of 67%\n" ], 'a score below the gate';
    is $ended->( Samples::result( statuses => [qw(Killed Killed Survived)] ), '--min-score', 66.5 ),
      [ 0, q{} ], 'a score above the gate says nothing';
    is $ended->( Samples::result( statuses => [], baseline_failures => [ $failure->@*, $failure->@* ] ) ),
      [ 3, "mutation: tests that fail without a mutant: 2\n" ], 'a failing unmodified run';
    is $ended->( Samples::result( statuses => ['NoVerdict'] ) ), [ 4, "mutation: the run states no score\n" ],
      'a run without a score';
    is $ended->( Samples::result( statuses => [qw(Killed Pending)], interrupted => 'PIPE' ) ),
      [ 141, "mutation: interrupted by SIGPIPE\n" ], 'an interrupted run';
    is $ended->( Samples::result( statuses => ['Killed'], interrupted => 'HUP', baseline_failures => $failure ) ),
      [ 129, "mutation: interrupted by SIGHUP\n" ], 'the signal comes before every other outcome';
};

subtest 'a run reports its progress to the errors of the world and its result to the output' => sub {
    my $result = Samples::result( statuses => [qw(Killed Survived Killed)] );
    my $run    = sub ( $argv, %fact ) {
        no warnings 'redefine';
        local *Test::Mutation::Runner::run = sub ( $config, $listener ) {
            $listener->( 'analyzed', { mutants => 3, files => 1, tests => 1 } );
            $listener->( 'baseline', { tests   => 1, jobs  => 2 } );
            $listener->( 'mutant',   { status  => $_->{status} } ) for $result->entries->@*;
            return $result;
        };
        return World::observe( $argv, cwd => $root, %fact );
    };
    my $log = $run->( [ '--format', 'terminal' ] );
    is $log->{stderr},
      "4 processors online\n3 mutants in 1 file, 1 test\nThe unmodified run passed: 1 test, 2 jobs\n"
      . "[1/3] 1 killed\n[2/3] 1 killed, 1 survived\n[3/3] 2 killed, 1 survived\n", 'a log gets one line for each step';
    like $log->{stdout}, qr/\A3 mutants: 2 killed, 1 survived\nScore: 66[.]7% \(2 of 3 valid mutants\)\n/, 'the report';
    is $log->{exit}, 0, 'and the run succeeds';
    is $run->( [ '--format', 'terminal' ], err_tty => 1 )->{stderr},
      "4 processors online\n3 mutants in 1 file, 1 test\nThe unmodified run passed: 1 test, 2 jobs\n"
      . "\r[1/3] 1 killed\r[2/3] 1 killed, 1 survived\r[3/3] 2 killed, 1 survived\n",
      'a terminal gets one line that changes';
    my $calls = 0;
    my $limited =
      $run->( [ '--format', 'terminal' ], processors => sub { $calls++; { count => 2, source => 'quota' } } );
    like $limited->{stderr}, qr/\A2 processors in the quota of the control group\n3 mutants in 1 file/,
      'the first line names the count of processors and its source';
    is $calls, 1, 'and the run asks its world for the count once';
    is [ map { $run->( [ '--format', 'terminal', '--min-score', $_ ] )->{exit} } 66, 67 ], [ 0, 1 ], 'the gate decides';

    my $summary = "$elsewhere/summary.md";
    my $github  = $run->( [ '--format', 'github' ], env => { GITHUB_STEP_SUMMARY => $summary } );
    like $github->{stdout}, qr/\A::warning file=lib\/Sample[.]pm,line=2,/, 'the annotations go to the output';
    ok -s $summary, 'and the summary goes to the file that the environment of the world names';
    my $unnamed = $run->( [ '--format', 'github' ], env => { GITHUB_STEP_SUMMARY => q{} } );
    is $unnamed->{exit}, 0, 'an empty name writes no summary';

    my $reports = $run->( [ '--format', 'json', '--report-dir', "$elsewhere/out" ] );
    is $reports->{stdout}, "Reports: $elsewhere/out/mutation.json\n", 'the paths of the report files';
    my $interrupted = Samples::result( statuses => [qw(Killed Pending)], interrupted => 'INT' );
    $result = $interrupted;
    my $stopped = $run->( [ '--format', 'terminal' ] );
    is [ $stopped->{exit}, ( split /\n/, $stopped->{stderr} )[-1] ], [ 130, 'mutation: interrupted by SIGINT' ],
      'an interrupted run ends with the status and the line of its signal';
};

subtest 'main plans and acts in the world of the process' => sub {
    my $here = Cwd::getcwd();
    my ( $output, $errors ) = ( q{}, q{} );
    chdir $root or die "chdir: $!";
    my @status = do {
        local *STDOUT;    ## no critic (Variables::RequireInitializationForLocalVars)
        local *STDERR;    ## no critic (Variables::RequireInitializationForLocalVars)
        open STDOUT, '>', \$output or die "stdout: $!";
        open STDERR, '>', \$errors or die "stderr: $!";
        local $ENV{GITHUB_ACTIONS} = 'false';
        map { Test::Mutation::CLI::main( $_->@* ) } ['--version'], [ 'list', '--shard', '1/19' ], [ 'list', '--bogus' ];
    };
    chdir $here or die "chdir: $!";
    is \@status, [ 0, 0, 2 ], 'the status of each command';
    like $output, qr/\Amutation [0-9.]+\n[0-9a-f]{12}  lib\/Calc[.]pm:5:10  [^\n]+\n1 mutant\n\z/,
      'the output of the process, and the project in its directory';
    is $errors, "Unknown option: bogus\n", 'the errors of the process';

    my @warnings;
    my @without = do {
        local $SIG{__WARN__} = sub ($text) { push @warnings, $text };
        local *STDOUT;    ## no critic (Variables::RequireInitializationForLocalVars)
        local *STDERR;    ## no critic (Variables::RequireInitializationForLocalVars)
        map { Test::Mutation::CLI::main( $_->@* ) } ['--version'], [ 'list', '--bogus' ];
    };
    is \@without, [ 0, 2 ], 'a process without its standard streams still gets the status of each command';
    like \@warnings, [ qr/\Asay[(][)] on unopened filehandle STDOUT/, qr/\Aprint[(][)] on unopened filehandle STDERR/ ],
      'and Perl warns about the two lines that found no stream, and about nothing else';
};

done_testing;
