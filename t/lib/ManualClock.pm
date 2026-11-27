package ManualClock;
use v5.36;
use Time::HiRes ();

# A clock for the pool that stands still until the test moves it, so each deadline falls where the test puts it.
# Before each wait the clock offers the seconds and the handles of the wait to the next step of the test.
# A step may move the clock or release a test process, and it returns false to wait for a later wait.
# A wait whose seconds the moves used up ends at once with the handles that are ready.
# Any other wait blocks until a handle is ready, as the wait of a pool that only events wake.
# A pool that never ends dies after a number of waits, so a broken loop fails its test instead of hanging it.
# Time stands still between the steps, so a pool acts on every deadline that it reached and never waits for no time.
# A wait for no time is the turn of a loop without a wait, and it dies at once.

my $PATIENCE = 30;

sub new ( $class, %arg ) {
    return bless {
        now   => defined $arg{at} ? $arg{at} : 0,
        steps => [ ( $arg{steps} || [] )->@* ],
        asked => [],
        limit => defined $arg{limit} ? $arg{limit} : 1_000,
      },
      $class;
}

sub now ($self) {
    return $self->{now};
}

sub after_ready ( $path, $step ) {
    return sub (@arguments) {
        Time::HiRes::sleep(0.005) until -s $path;
        return $step->(@arguments);
    };
}

sub move ( $self, $seconds ) {
    $self->{now} += $seconds;
    return 1;
}

# The seconds that the pool asked for in each wait, in their order.
sub asked ($self) {
    return [ $self->{asked}->@* ];
}

# The steps that no wait took.
sub untaken ($self) {
    return scalar $self->{steps}->@*;
}

sub wait_for ( $self, $select, $seconds ) {
    push $self->{asked}->@*, $seconds;
    die "the pool waited more than $self->{limit} times\n" if $self->{asked}->@* > $self->{limit};
    die "the pool waited for no time\n"                    if $seconds <= 0;
    my $from = $self->{now};
    my $step = $self->{steps}[0];
    shift $self->{steps}->@* if $step && $step->( $self, $seconds, $select );
    return [ $select->can_read( $self->{now} - $from >= $seconds ? 0 : $PATIENCE ) ];
}

1;
