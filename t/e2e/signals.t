use v5.36;
use Test2::V0;
use Cwd         ();
use File::Temp  ();
use Time::HiRes ();
use lib 't/e2e/lib';
use Fixture qw(copy_of leftovers ran run_fixture);
use Test::Mutation::Settings;
use Test::Mutation::Runner;
use Test::Mutation::Signals;

# A signal ends the work of a run wherever it meets the run, and the run releases what it holds on the way.
# The cases of interrupt.t send a signal while a test runs, and these cases meet the steps around the tests.

my $library = Cwd::abs_path('lib');
my $command = Cwd::abs_path('bin') . '/mutation';

# What ends a piece of code that a signal waits for: the name of the signal, the text of another error, or nothing.
sub ended_by ( $signal, $code ) {
    my $lived = eval {
        Test::Mutation::Signals::watch( sub { kill $signal, $$; $code->(); return 1 } );
        1;
    };
    return 'nothing' if $lived;
    my $error = $@;
    return ref $error && $error->isa('Test::Mutation::Interrupted') ? $error->signal : "$error";
}

subtest 'a signal ends the analysis between two files' => sub {
    my $root   = copy_of('calc');
    my $config = Test::Mutation::Settings::of_call( { root => $root } );
    is ended_by( 'TERM', sub { Test::Mutation::Runner::analyze($config) } ), 'TERM',
      'the analysis dies with the interruption';
    is scalar Test::Mutation::Runner::analyze($config)->{mutants}->@*, 19,
      'and the same analysis without a signal ends';
};

subtest 'a signal ends the copy of the project, and the run removes what it copied' => sub {
    for my $signal (qw(HUP INT QUIT PIPE TERM)) {
        my $root = copy_of('calc');
        is ended_by( $signal, sub { run_fixture($root) } ), $signal,
          "SIG$signal ends the run as an interruption, and never as a copy that failed";
    }
};

subtest 'a signal ends a run in the project before its first test' => sub {
    my $root = copy_of('calc');
    is ended_by( 'INT', sub { run_fixture( $root, in_place => 1 ) } ), 'INT', 'the run dies with the interruption';
    ok !-e "$root/.mutation", 'and it leaves no work directory';
};

sub wait_for ($condition) {
    for ( 1 .. 100 ) {
        return 1 if $condition->();
        Time::HiRes::sleep(0.05);
    }
    return 0;
}

sub text_of ($path) {
    open my $handle, '<', $path or return q{};
    local $/ = undef;
    my $text = readline $handle;
    return defined $text ? $text : q{};
}

subtest 'a signal for the tool ends exec with its status when the command has ended' => sub {
    my $root = copy_of('calc');
    my ($identifier) = ran( 0, $root, 'list' )->{stdout} =~ /\A([0-9a-f]{12})  /;
    my ( $scratch, $temporary ) = map { Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) ) } 1 .. 2;
    my $script = 'open my $out, q{>}, q{started}; close $out; select undef, undef, undef, 1; exit 7';

    my $pid = fork;
    die "fork: $!" if !defined $pid;
    if ( !$pid ) {
        chdir $root or die "chdir: $!";
        local $ENV{TMPDIR} = $temporary;
        open STDIN,  '<', '/dev/null'           or die "stdin: $!";
        open STDOUT, '>', "$scratch/stdout.txt" or die "stdout: $!";
        open STDERR, '>', "$scratch/stderr.txt" or die "stderr: $!";
        exec {$^X} $^X, "-I$library", $command, 'exec', $identifier, q{--}, $^X, '-e', $script or die "exec: $!";
    }
    ok wait_for( sub { -e "$root/started" } ), 'the command of exec runs';
    kill 'TERM', $pid;
    waitpid $pid, 0;
    is [ $? >> 8, $? & 127 ],          [ 143, 0 ], 'the tool ends with the status of the signal';
    is text_of("$scratch/stderr.txt"), "mutation: interrupted by SIGTERM\n", 'and with its line';
    unlink "$root/started" or die "unlink: $!";
    is leftovers( $temporary, $root ), [], 'and it leaves no work directory';
};

done_testing;
