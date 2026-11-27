use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/lib';
use CountedClock;
use Gate;
use Test::Mutation::Pool;

# Experiment E12: how often does the loop of the pool turn while no test has anything to say?
# A test that closed its standard streams and still runs leaves the pool nothing to read until it ends.
# A loop that turns without a wait then keeps one processor busy for as long as the test runs.
# The pool waits through its clock once in every turn, so the waits of a counting clock count the turns.

my $dir = File::Temp::tempdir( CLEANUP => 1 );

# A broken pool may leave a test script behind, so each script ends on its own after a while.
sub script ( $name, $code ) {
    my $path = "$dir/$name";
    open my $handle, '>', $path or die "open $path: $!";
    print {$handle} "alarm 90;\n", $code or die "print $path: $!";
    close $handle or die "close $path: $!";
    return $path;
}

sub measured ( $clock, @paths ) {
    my @queue = map {
        {
            command         => [ $^X, $_ ],
            env             => {},
            cwd             => $dir,
            timeout         => 20,
            output_limit    => 1_000_000,
            stop_on_failure => 0,
        }
    } @paths;
    my @passed;
    Test::Mutation::Pool::run(
        jobs  => scalar @paths,
        clock => $clock,
        next  => sub { shift @queue },
        done  => sub ( $task, $got ) { push @passed, $got->{passed}; return },
    );
    return { passed => ( grep { !$_ } @passed ) ? 0 : 1, turns => $clock->turns };
}

# Each test gives the pool a few events: its output, the ends of its two pipes, its own end, and the end of a drain.
# The end of a process may cost two turns, one for the wait that the signal cut short and one for the byte of its handler.
# Two tests stay below twenty turns, and a loop that turns without a wait turns thousands of times in a second.
my $LIMIT = 20;
my $QUIET = q{$| = 1; print "1..1\nok 1\n"; %s select undef, undef, undef, 1;};

subtest 'the count rejects a loop that turns without a wait' => sub {
    my $spun =
      measured( CountedClock->new( spins => 1 ), script( 'spun.t', sprintf $QUIET, 'close STDOUT; close STDERR;' ) );
    is $spun->{passed}, 1, 'the test passes';
    ok $spun->{turns} > $LIMIT, "a wait that returns at once gives $spun->{turns} turns";
};

# The silent test waits beside a test that ends at once, and beside one whose pipes a process outside its group holds.
# The pool hears of each end and of each pipe that it stops reading once.
my $quick = script( 'quick.t', q{print "1..1\nok 1\n";} );
my $held  = script( 'held.t',  <<'PERL' );
if ( !fork ) { setpgrp 0, 0; select undef, undef, undef, 3; exit 0 }
print "1..1\nok 1\n";
PERL
my $CLOSED = 'close STDOUT; close STDERR;';
my %turns;
for my $case (
    [ 'open',                       q{} ],
    [ 'closed',                     $CLOSED ],
    [ 'closed beside a quick test', $CLOSED,                                  $quick ],
    [ 'closed beside a held pipe',  "$CLOSED select undef, undef, undef, 1;", $held ],
  )
{
    my ( $name, $code, @beside ) = $case->@*;
    my $quiet = measured( CountedClock->new, script( "quiet-$name.t" =~ s/ /-/gr, sprintf $QUIET, $code ), @beside );
    is $quiet->{passed}, 1, "a test with its streams $name passes";
    note "the loop turned $quiet->{turns} times for the test with its streams $name";
    $turns{$name} = $quiet->{turns};
}

my @found;
push @found, 'the loop of the pool turns without a wait while a running test is silent'
  if grep { $_ > $LIMIT } values %turns;
Gate::findings( 'pool', \@found );

done_testing;
