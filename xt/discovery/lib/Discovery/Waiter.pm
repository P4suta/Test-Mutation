package Discovery::Waiter;
use v5.36;
use File::Temp  ();
use Time::HiRes ();
use Test::Mutation::Pool;

# The pool of the tool with one test process that prints its stream and then waits.
# The pool runs in this process, so the processor time of this process during the wait is the work of the pool alone.
# The time of the whole tool held its start, its analysis, and the load of the machine, and a comparison of two runs varied with them.
# A saboteur is this adapter with a part that uses the processor after the pool.

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

sub _own_cpu () {
    my ( $user, $system ) = times;
    return $user + $system;
}

# The pool with one test that passes, treats its output as named, and waits the given seconds before it ends.
# Returns whether the pool passed the test, and the processor time that this process used meanwhile.
sub _pooled ( $output, $seconds ) {
    my $program = qq[\$| = 1; print "1..1\\nok 1 - waits\\n"; $OUTPUT{$output} select undef, undef, undef, $seconds;];
    my $errors  = File::Temp->new;
    my @tasks   = (
        {
            command         => [ $^X, '-e', $program ],
            env             => {},
            cwd             => q{.},
            timeout         => 60 + $seconds,
            stop_on_failure => 0,
            stderr          => $errors->filename,
        }
    );
    my $used = _own_cpu();
    my $passed;
    Test::Mutation::Pool::run(
        jobs => 1,
        next => sub { return shift @tasks },
        done => sub ( $task, $result ) {
            $passed = $result->{passed};
            return;
        },
    );
    return ( $passed ? 1 : 0, _own_cpu() - $used );
}

# The start and the end of a test cost the pool some processor time whatever the test does.
# The same test without a wait gives that cost, and the result holds what the wait added to it.
sub waited ( $self, $output, $seconds ) {
    die "no treatment of the output is named $output\n" if !exists $OUTPUT{$output};
    my ( undef,   $fixed ) = _pooled( $output, 0 );
    my ( $passed, $used )  = _pooled( $output, $seconds );
    my $before = _own_cpu();
    $self->{burn}->($seconds) if $self->{burn};
    my $added = $used - $fixed + _own_cpu() - $before;
    return { waited => $seconds, passed => $passed, cpu => $added > 0 ? $added : 0 };
}

1;
