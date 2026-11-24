use v5.36;
use Test2::V0;
use File::Temp  ();
use IO::Select  ();
use Time::HiRes ();
use lib 't/lib';
use Gate;
use Test::Mutation::Pool;

# Experiment E12: how often does the loop of the pool turn while no test has anything to say?
# A test that closed its standard output and still runs leaves the pool no handle to wait on.
# A loop that turns without a wait then keeps one processor busy for as long as the test runs.

my $dir = File::Temp::tempdir( CLEANUP => 1 );

# The pool asks IO::Select once in every turn of its loop, so the calls count the turns.
my ( $turns, $without_handle ) = ( 0, 0 );
{
    no warnings 'redefine';
    my $can_read = \&IO::Select::can_read;
    *IO::Select::can_read = sub ( $select, @timeout ) {
        $turns++;
        $without_handle++ if !$select->count;
        return $can_read->( $select, @timeout );
    };
}

# A broken pool may leave a test script behind, so each script ends on its own after a while.
sub script ( $name, $code ) {
    my $path = "$dir/$name";
    open my $handle, '>', $path or die "open $path: $!";
    print {$handle} "alarm 90;\n", $code or die "print $path: $!";
    close $handle or die "close $path: $!";
    return $path;
}

sub measured ($path) {
    ( $turns, $without_handle ) = ( 0, 0 );
    my @queue = (
        {
            command         => [ $^X, $path ],
            env             => {},
            cwd             => $dir,
            timeout         => 20,
            stop_on_failure => 0,
            stderr          => "$path.err"
        }
    );
    my $result;
    my @before  = times;
    my $started = Time::HiRes::time();
    Test::Mutation::Pool::run(
        jobs => 1,
        next => sub { shift @queue },
        done => sub ( $task, $got ) { $result = $got; return },
    );
    my @after = times;
    return {
        passed         => $result->{passed},
        turns          => $turns,
        without_handle => $without_handle,
        seconds        => Time::HiRes::time() - $started,
        processor      => $after[0] + $after[1] - $before[0] - $before[1],
    };
}

# The pool waits a fifth of a second for output, so a test of one second takes about five turns that hold its pipe.
# The limit leaves room for a slow machine and stays far below the count of a loop without a wait.
# After the end of the output the pool may turn without a handle until it reaps the process.
# The load of the machine decides how long that takes, so the count of the control takes the turns that hold the pipe.
my $LIMIT = 100;
my $QUIET = q{$| = 1; print "1..1\nok 1\n"; %s select undef, undef, undef, 1;};

subtest 'the count rejects no loop that waits: a silent test with an open pipe takes a few turns' => sub {
    my $open = measured( script( 'open.t', sprintf $QUIET, q{} ) );
    my $held = $open->{turns} - $open->{without_handle};
    is $open->{passed}, 1, 'the test passes';
    ok $held >= 2 && $held <= $LIMIT, "the loop turns $held times with the pipe in the second of the test";
};

my $closed = measured( script( 'closed.t', sprintf $QUIET, 'close STDOUT;' ) );
is $closed->{passed}, 1, 'a test that closed its standard output and went on passes';
ok $closed->{seconds} >= 1, 'and the pool waits for its end';
note sprintf 'the loop turned %d times without a handle and used %.2f s of processor time in %.2f s',
  @{$closed}{qw(without_handle processor seconds)};

my @found;
push @found, 'the loop of the pool turns without a wait while a running test is silent'
  if $closed->{without_handle} > $LIMIT;
Gate::findings( 'pool', \@found );

done_testing;
