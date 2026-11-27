use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(run_fixture write_file);
use Test::Mutation::Launch;

my $project = File::Temp::tempdir( CLEANUP => 1 );
my $shim    = { generation => 2, directory => "$project/shim", record => "$project/records", spec => "$project/spec" };
my $command = Test::Mutation::Launch::test_command(
    perl    => $^X,
    root    => $project,
    program => 't/test.t',
    tmp     => "$project/tmp",
    lib     => [],
    switch  => [],
    shim    => $shim,
    env     => {},
);
is $command->{env}{TEST_MUTATION_ROOT}, $project,              'every instrumented child can identify its project';
is $command->{env}{HARNESS_VERSION},    TAP::Harness->VERSION, 'tests see the version of the active harness';
is $command->{command},                 [ $^X, 't/test.t' ],   'a command needs no configured switches';

subtest 'the pool routes each completed child to the matching result handler' => sub {
    my @calls;
    my $parent = File::Temp::tempdir( CLEANUP => 1 );
    no warnings 'redefine';

    # The three continuations make the next scheduled task observable before a compiler can run again.
    ## no critic (Variables::ProtectPrivateVars Subroutines::ProtectPrivateSubs)
    local *Test::Mutation::Runner::_after_test   = sub { push @calls, 'test';   return 'continue test' };
    local *Test::Mutation::Runner::_after_syntax = sub { push @calls, 'syntax'; return 'continue syntax' };
    local *Test::Mutation::Runner::_after_code   = sub { push @calls, 'code';   return 'continue code' };
    for my $case (
        [ 'test',            'test' ],
        [ 'syntax-original', 'syntax' ],
        [ 'syntax-mutant',   'syntax' ],
        [ 'code-original',   'code' ],
        [ 'code-mutant',     'code' ],
      )
    {
        my ( $kind, $handler ) = @$case;
        my $tmp  = File::Temp::tempdir( DIR => $parent );
        my $task = { payload => { kind => $kind, tmp => $tmp, job => {} } };
        is Test::Mutation::Runner::_after_task( {}, {}, $task, {} ), "continue $handler",
          "$kind returns the continuation of its own result handler";
        is pop(@calls), $handler, "$kind consumed exactly its own observation";
        is( -d $tmp ? 1 : 0, $kind eq 'test' ? 1 : 0, 'compiler scratch is released on completion' );
    }
    ## use critic
};

my $compile  = File::Temp::tempdir( CLEANUP => 1 );
my $observer = "package Observer;\n" . <<'OBSERVER';
if ($^C) {
    open my $out, '>>', $ENV{TEST_COMPILE_OBSERVATIONS} or die $!;
    print {$out} -d $ENV{TMPDIR} ? "ready\n" : "missing\n";
    close $out or die $!;
}
1;
OBSERVER
write_file( "$project/support/Observer.pm", $observer );
write_file( "$project/lib/Clockwork.pm", "package Clockwork;\nuse Observer;\nsub total { return \$_[0] + 1 }\n1;\n" );
local $ENV{TEST_COMPILE_OBSERVATIONS} = "$compile/compiled";
write_file( "$project/t/idle.t", "use Test::More tests => 1;\npass 'the distribution loads';\n" );
my $compile_task = Test::Mutation::Runner->can('_compile_task');
my %scheduled;
my $measured;
{
    no warnings 'redefine';

    local *Test::Mutation::Runner::_compile_task = sub ( $run, $job, $kind, $file, $switch ) {    ## no critic (Variables::ProtectPrivateVars)
        die "the runner scheduled $kind twice for $file\n" if $scheduled{$kind}{$file}++;
        return $compile_task->( $run, $job, $kind, $file, $switch );
    };
    ($measured) = run_fixture( $project, jobs => 1, lib => [qw(lib support)] );
}
ok $measured->stats->{compiles}, 'the comparison invoked the compiler';
open my $observations, '<', "$compile/compiled" or die $!;
my @recorded = <$observations>;
close $observations or die $!;
is [ grep { $_ ne "ready\n" } @recorded ], [], 'every compiler receives an existing private temporary directory';
ok @recorded, 'the compiler checked its directory while running';

done_testing;
