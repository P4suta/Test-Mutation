package CountedClock;
use v5.36;
use Test::Mutation::Clock;

# The clock of the machine with a count of the waits, which are the turns of the loop of a pool.
# A clock that `spins` asks the handles and returns at once, as the wait of a loop that turns without a wait.

sub new ( $class, %arg ) {
    return bless { machine => Test::Mutation::Clock->new, turns => 0, spins => $arg{spins} ? 1 : 0 }, $class;
}

sub now ($self) {
    return $self->{machine}->now;
}

sub turns ($self) {
    return $self->{turns};
}

sub wait_for ( $self, $select, $seconds ) {
    $self->{turns}++;
    return $self->{machine}->wait_for( $select, $self->{spins} ? 0 : $seconds );
}

1;
