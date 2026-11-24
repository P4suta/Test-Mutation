package Discovery::Waiter;
use v5.36;
use File::Temp ();
use CountedClock;
use Test::Mutation::Pool;

# The pool of the tool with one test process that prints its stream and then waits.
# The pool waits once in each turn of its loop, so the waits of its clock count its turns.
# A count of turns depends on the events of the test alone, so a busy machine changes nothing.
# The time of the whole tool held its start, its analysis, and the load of the machine, and a comparison of two runs varied with them.
# A saboteur is this adapter with a clock whose wait returns at once, as the wait of a loop without a wait.

# What the test does with its standard output before it waits.
my %OUTPUT = (
    kept       => q{},
    closed     => q[close STDOUT;],
    redirected => q[open STDOUT, '>', '/dev/null';],
);

sub new ( $class, %part ) {
    return bless {%part}, $class;
}

sub with ( $self, %part ) {
    return bless { $self->%*, %part }, ref $self;
}

sub outputs () {
    my @names = sort keys %OUTPUT;
    return @names;
}

# The pool with one test that passes, treats its output as named, and waits the given seconds before it ends.
# Returns whether the pool passed the test, and the turns of the pool meanwhile.
sub _pooled ( $self, $output, $seconds ) {
    my $program = qq[\$| = 1; print "1..1\\nok 1 - waits\\n"; $OUTPUT{$output} select undef, undef, undef, $seconds;];
    my $clock   = CountedClock->new( spins => $self->{spins} );
    my @tasks   = (
        {
            command         => [ $^X, '-e', $program ],
            env             => {},
            cwd             => q{.},
            timeout         => 60 + $seconds,
            output_limit    => 1_000_000,
            stop_on_failure => 0,
        }
    );
    my $passed;
    Test::Mutation::Pool::run(
        jobs  => 1,
        clock => $clock,
        next  => sub { return shift @tasks },
        done  => sub ( $task, $result ) {
            $passed = $result->{passed};
            return;
        },
    );
    return ( $passed ? 1 : 0, $clock->turns );
}

# The start and the end of a test cost the pool some turns whatever the test does.
# The same test without a wait gives that cost, and the result holds the turns that the wait added to it.
sub waited ( $self, $output, $seconds ) {
    die "no treatment of the output is named $output\n" if !exists $OUTPUT{$output};
    my ( undef,   $fixed ) = $self->_pooled( $output, 0 );
    my ( $passed, $turns ) = $self->_pooled( $output, $seconds );
    my $added = $turns - $fixed;
    return { waited => $seconds, passed => $passed, turns => $added > 0 ? $added : 0 };
}

1;
