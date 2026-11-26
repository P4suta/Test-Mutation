package Test::Mutation::Pool;
use v5.36;
use Digest::SHA            ();
use Fcntl                  ();
use IO::Select             ();
use List::Util             ();
use POSIX                  ();
use Types::Standard        qw(ArrayRef Bool CodeRef Defined Dict HasMethods HashRef Int Maybe Optional Str);
use Types::Common::Numeric qw(PositiveInt PositiveNum);
use Type::Params           qw(signature_for);
use Test::Mutation::Clock;
use Test::Mutation::Error;
use Test::Mutation::Message;
use Test::Mutation::Signals;
use Test::Mutation::Tap;
use Test::Mutation::Try;
use Test::Mutation::Workspace::Processes;
use Test::Mutation::Witness;

our $VERSION = '0.001';

my $KEPT_BYTES    = 262_144;
my $CHUNK_BYTES   = 65_536;
my $DRAIN_SECONDS = 1;
my $GRACE_SECONDS = 0.5;

# Perl runs the handler of a signal after the system call that the signal met.
# A signal between the last look of a turn and its wait therefore waits with it, and this bound ends such a wait.
my $LONGEST_WAIT = 5;

my @STREAMS = qw(output errors);

my $TASK = Dict [
    command         => ArrayRef [Str],
    env             => HashRef [ Maybe [Str] ],
    cwd             => Str,
    lease           => Optional [Str],
    observation     => Optional [ Dict [ directory => Str, descriptor => PositiveInt ] ],
    timeout         => PositiveNum,
    output_limit    => PositiveInt,
    stop_on_failure => Bool,
    payload         => Optional [ HashRef [Defined] ],
];

signature_for run => (
    named => [
        jobs             => PositiveInt,
        next             => CodeRef,
        done             => CodeRef,
        retry_after_done => Bool,
        { default => 0 },
        clock => HasMethods [qw(now wait_for)],
        { default => sub { Test::Mutation::Clock->new } },
        work => HashRef [Int],
        { default => sub { {} } },
    ],
    returns => Int,
);

sub run ($arg) {
    pipe my $wake, my $woken or Test::Mutation::Error::raise( 'pipe-unopenable', reason => "$!" );
    my $pool = {
        clock  => $arg->clock,
        work   => $arg->work,
        wake   => $wake,
        select => IO::Select->new($wake),
        slots  => {},
    };
    my $exhausted = 0;
    my $completed = 0;

    # A signal waits for the top of a turn, where every started test stands in a slot.
    my $turns = sub {
        while (1) {
            Test::Mutation::Signals::check();
            while ( !$exhausted && keys $pool->{slots}->%* < $arg->jobs ) {
                my $task = $arg->next->();
                $exhausted = 1 if !$task;
                _start( $pool, $task ) if $task;
            }
            last if !$pool->{slots}->%*;
            my $now = _turn($pool);
            for my $slot ( grep { _finished( $_, $now ) } values $pool->{slots}->%* ) {
                _close_streams( $pool, $slot );
                delete $pool->{slots}{ $slot->{pid} };
                $completed++;
                $exhausted = 0 if $arg->retry_after_done;
                my $follow_up = $arg->done->( $slot->{task}, _result($slot) );
                _start( $pool, $follow_up ) if $follow_up;
            }
        }
        return $completed;
    };

    # A signal, a callback, or the pool itself may end the turns, and no test may outlive the run.
    my $end = sub { _end_all($pool) if $pool->{slots}->%*; return };

    # The end of a test that holds no pipe of its own reaches the wait through the pipe of the pool alone.
    return Test::Mutation::Signals::watch(
        sub {
            local $SIG{CHLD} = sub { syswrite $woken, q{.}; return };
            return Test::Mutation::Signals::waking( $woken, sub { Test::Mutation::Try::with_cleanup( $turns, $end ) } );
        }
    );
}

sub _start ( $pool, $task ) {
    my $slot = _spawn( $TASK->assert_return($task), $pool->{clock}->now );
    $pool->{work}{spawns}++;
    $pool->{slots}{ $slot->{pid} } = $slot;
    $pool->{select}->add( values $slot->{handles}->%* );
    return;
}

# One turn waits once, for a pipe, a signal, or the nearest deadline, and then looks at every test.
sub _turn ($pool) {
    my $clock = $pool->{clock};
    my $ready = $clock->wait_for( $pool->{select}, _patience( $pool, $clock->now ) );
    _take( $pool, $_ ) for $ready->@*;
    my $now = $clock->now;
    _supervise( $pool, $_, $now ) for values $pool->{slots}->%*;
    return $now;
}

sub _patience ( $pool, $now ) {
    my $nearest = List::Util::min( $now + $LONGEST_WAIT, map { _deadline($_) } values $pool->{slots}->%* );
    return List::Util::max( 0, $nearest - $now );
}

# The moment at which the pool acts on a test that sends no news, and a moment passes once.
sub _deadline ($slot) {
    return $slot->{ended} + $DRAIN_SECONDS if defined $slot->{status};
    return                                 if $slot->{killed};
    return $slot->{asked} + $GRACE_SECONDS if defined $slot->{asked};
    return $slot->{deadline};
}

# A read of a pipe that select called readable never blocks, so no signal cuts it short.
# One read of the pipe of the pool takes every byte that the handlers wrote, so that pipe never fills.
sub _take ( $pool, $handle ) {
    my ( $slot, $name ) = _owner( $pool, $handle );
    my $count = sysread( $handle, my $chunk, $CHUNK_BYTES );
    return if !$slot;
    if ($count) {
        _consume( $slot, $name, $chunk );
        return;
    }
    $pool->{select}->remove($handle);
    $slot->{open}--;
    return;
}

sub _owner ( $pool, $handle ) {
    my $number = fileno $handle;
    for my $slot ( values $pool->{slots}->%* ) {
        my ($name) = grep { fileno $slot->{handles}{$_} == $number } @STREAMS;
        return ( $slot, $name ) if defined $name;
    }
    return;
}

sub _consume ( $slot, $name, $chunk ) {
    $slot->{printed} += length $chunk;
    $slot->{$name} = substr $slot->{$name} . $chunk, -$KEPT_BYTES;
    return if $name ne 'output';
    $slot->{digest}->add($chunk);
    $slot->{tap} = Test::Mutation::Tap::feed( $slot->{tap}, $chunk );
    return;
}

# A test that ended keeps its own result, however late the pool looks at it.
# The first cause that ends a test is the one that its result names.
sub _supervise ( $pool, $slot, $now ) {
    return if defined $slot->{status} || _reaped( $slot, $now );
    my $task = $slot->{task};
    my $cause =
        $now >= $slot->{deadline}                                                       ? 'timed_out'
      : $slot->{printed} > $task->{output_limit}                                        ? 'overflowed'
      : $task->{stop_on_failure} && Test::Mutation::Tap::failed_already( $slot->{tap} ) ? 'stopped'
      :                                                                                   undef;
    _ask_to_end( $pool, $slot, $now, $cause ) if defined $cause && !defined $slot->{asked};
    return if !defined $slot->{asked} || $slot->{killed} || $now < $slot->{asked} + $GRACE_SECONDS;
    _signal_group( $slot, 'KILL' );
    $slot->{killed} = 1;
    return;
}

sub _ask_to_end ( $pool, $slot, $now, $cause ) {
    $slot->{$cause}  = 1;
    $slot->{asked}   = $now;
    $slot->{escaped} = [ _descendants( $pool, $slot->{pid} ) ];
    _signal_group( $slot, 'TERM' );
    return;
}

sub _reaped ( $slot, $now ) {
    return 0 if waitpid( $slot->{pid}, POSIX::WNOHANG ) != $slot->{pid};
    $slot->{status} = $?;
    $slot->{ended}  = $now;
    _signal_group( $slot, 'KILL' );
    _end_escaped( $slot->{escaped}->@* ) if $slot->{escaped};
    return 1;
}

# A process that left the group may hold a pipe after the test ended, so the pool reads for a while and then stops.
sub _finished ( $slot, $now ) {
    return 0 if !defined $slot->{status};
    return 1 if !$slot->{open};
    return $now >= $slot->{ended} + $DRAIN_SECONDS ? 1 : 0;
}

sub _close_streams ( $pool, $slot ) {
    for my $handle ( values $slot->{handles}->%* ) {
        $pool->{select}->remove($handle);
        close $handle or Test::Mutation::Error::raise( 'pipe-unclosable', reason => "$!" );
    }
    return;
}

# The tests that still run when the turns end get the grace to end on their own, and then force.
sub _end_all ($pool) {
    my @slots   = values $pool->{slots}->%*;
    my @escaped = _descendants( $pool, map { $_->{pid} } @slots );
    _signal_group( $_, 'TERM' ) for @slots;
    my $clock   = $pool->{clock};
    my $until   = $clock->now + $GRACE_SECONDS;
    my $signals = IO::Select->new( $pool->{wake} );
    my @running = grep { !defined $_->{status} } @slots;
    while ( @running = grep { waitpid( $_->{pid}, POSIX::WNOHANG ) != $_->{pid} } @running ) {
        my $now = $clock->now;
        last if $now >= $until;
        _take( $pool, $_ ) for $clock->wait_for( $signals, $until - $now )->@*;
    }
    for my $slot (@running) {
        _signal_group( $slot, 'KILL' );
        waitpid $slot->{pid}, 0;
    }
    _signal_group( $_, 'KILL' ) for @slots;
    _end_escaped(@escaped);
    return;
}

sub _spawn ( $task, $now ) {
    my %pipe;
    for my $name (@STREAMS) {
        pipe my $read, my $write or Test::Mutation::Error::raise( 'pipe-unopenable', reason => "$!" );
        $pipe{$name} = [ $read, $write ];
    }
    my $pid = fork;
    Test::Mutation::Error::raise( 'process-unstartable', reason => "$!" ) if !defined $pid;
    return _started( $task, $pid, $now, \%pipe )                          if $pid;

    # The child ends here, since code after this point would run the rest of the driver a second time.
    setpgrp 0, 0;
    _exec_child( $task, map { $pipe{$_}[1] } @STREAMS );
    POSIX::_exit(127);
    return;
}

sub _started ( $task, $pid, $now, $pipe ) {
    for my $name (@STREAMS) {
        close $pipe->{$name}[1] or Test::Mutation::Error::raise( 'pipe-unclosable', reason => "$!" );
    }
    return {
        task     => $task,
        pid      => $pid,
        handles  => { map { $_ => $pipe->{$_}[0] } @STREAMS },
        open     => scalar @STREAMS,
        output   => q{},
        errors   => q{},
        printed  => 0,
        digest   => Digest::SHA->new(256),
        tap      => Test::Mutation::Tap::start(),
        started  => $now,
        deadline => $now + $task->{timeout},
    };
}

# Replaces the child with the command of the test, and returns when the command fails to start.
sub _exec_child ( $task, $output, $errors ) {
    my $attempt = Test::Mutation::Try::attempt(
        sub {
            chdir $task->{cwd}
              or Test::Mutation::Error::raise( 'test-directory-closed', directory => $task->{cwd}, reason => "$!" );
            my %environment = ( %ENV, $task->{env}->%* );
            delete @environment{ grep { !defined $environment{$_} } keys %environment };
            local %ENV = %environment;
            ## no critic (InputOutput::RequireBriefOpen)
            open my $input, '<', '/dev/null' or Test::Mutation::Error::raise( 'test-streams-unset', reason => "$!" );
            ## use critic
            _take_standard_descriptors( $input, $output, $errors );
            my $lease =
              defined $task->{lease} ? Test::Mutation::Workspace::Processes::inherit( $task->{lease} ) : undef;
            Test::Mutation::Witness::inherit( $task->{observation}->@{qw(directory descriptor)} )
              if $task->{observation};
            no warnings 'exec';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
            exec { $task->{command}[0] } $task->{command}->@*
              or Test::Mutation::Error::raise( 'command-unstartable', command => $task->{command}[0], reason => "$!" );
        }
    );

    # The error reads as its message, and the line reaches the standard error of the test when the streams are set.
    my $line = Test::Mutation::Message::line( $attempt->{error} =~ s/\n\z//r );
    POSIX::write( 2, $line, length $line );
    return;
}

# The driver may hold STDOUT or STDERR in memory or closed, so the child sets descriptors 0 to 2 and no Perl handle.
# Each source moves above the three first, because a source that sits on one of them would be replaced too early.
sub _take_standard_descriptors (@handles) {
    my @copies = map { fcntl $_, Fcntl::F_DUPFD(), 3 } @handles;
    Test::Mutation::Error::raise( 'test-streams-unset', reason => "$!" ) if grep { !defined } @copies;
    for my $target ( 0 .. 2 ) {
        defined POSIX::dup2( $copies[$target], $target )
          or Test::Mutation::Error::raise( 'test-streams-unset', reason => "$!" );
    }
    POSIX::close($_) for @copies;
    return;
}

sub _signal_group ( $slot, $signal ) {
    kill $signal, -$slot->{pid};
    kill $signal, $slot->{pid};
    return;
}

sub _descendants ( $pool, @roots ) {
    no warnings 'exec';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    open my $listing, q{-|}, 'ps', '-A', '-o', 'pid=,ppid=' or return;
    $pool->{work}{listings}++;
    my %children;
    while ( my $line = readline $listing ) {
        my ( $pid, $parent ) = $line =~ /(\d+)\s+(\d+)/ or next;
        $children{$parent}{$pid} = 1;
    }
    close $listing or return;
    return _below( \%children, @roots );
}

sub _below ( $children, @parents ) {
    return map { ( $_, _below( $children, $_ ) ) } map { keys( ( $children->{$_} || {} )->%* ) } @parents;
}

sub _end_escaped (@pids) {
    kill 'KILL', map { ( -$_, $_ ) } @pids;
    return;
}

sub _result ($slot) {
    my $tap     = Test::Mutation::Tap::finish( $slot->{tap} );
    my $limited = $slot->{timed_out} || $slot->{overflowed};
    return {
        exit       => $slot->{status} >> 8,
        signal     => $slot->{status} & 127,
        timed_out  => $slot->{timed_out}                                                ? 1 : 0,
        overflowed => $slot->{overflowed}                                               ? 1 : 0,
        stopped    => $slot->{stopped}                                                  ? 1 : 0,
        passed     => !$limited && Test::Mutation::Tap::passed( $tap, $slot->{status} ) ? 1 : 0,
        early      => Test::Mutation::Tap::failed_already($tap),
        duration   => $slot->{ended} - $slot->{started},
        output     => $slot->{output},
        errors     => $slot->{errors},
        digest     => $slot->{digest}->hexdigest,
    };
}

1;

__END__

=head1 NAME

Test::Mutation::Pool - run test processes in parallel with limits of time and output

=head1 SYNOPSIS

    my %work;
    Test::Mutation::Pool::run(
        jobs => 4,
        next => sub { return shift @tasks },
        done => sub ( $task, $result ) { return },
        work => \%work,
    );

=head1 DESCRIPTION

The pool starts every task in its own process group and reads its standard output as TAP and its standard error apart.
It waits in one C<select> on the pipes of its tasks and on a pipe of its own, which the handlers of C<CHLD> and of the signals of L<Test::Mutation::Signals> write.
The wait ends at the nearest deadline, so the pool never turns without a wait.

The pool ends a task that exceeds its time limit, that prints more than its output limit, or that asked to stop at its first failure.
It signals the whole group, and it kills the group when the task outlives a grace of half a second.
Before a forced end the pool lists the descendants of the task with C<ps>, and it ends those that left the group too.

=head1 FUNCTIONS

=head2 run

Runs tasks until C<next> returns nothing and every started task has finished, and returns the number of tasks.
With C<retry_after_done>, a completion may release a scheduling constraint and the pool asks C<next> for work again.
C<done> receives each task with its result, and a task it returns runs before any task from C<next>.
C<clock> gives the time and the wait, and L<Test::Mutation::Clock> is its default.
C<work> is a hash where the pool adds the processes that it started under C<spawns> and the process listings that it read under C<listings>.

A task has the keys C<command>, C<env>, C<cwd>, C<timeout>, C<output_limit>, C<stop_on_failure>, and an optional C<payload> hash.
An undefined value in C<env> removes the variable.
C<output_limit> is the number of bytes that the task may print on its two streams together.

A result has the keys C<exit>, C<signal>, C<timed_out>, C<overflowed>, C<stopped>, C<passed>, C<early>, C<duration>, C<output>, C<errors>, and C<digest>.
C<passed> is true when the process ended within its limits and L<Test::Mutation::Tap> passes its stream and its wait status.
C<early> is true when the stream had failed before the process ended.
C<output> and C<errors> hold the ends of the two streams, and C<digest> is the SHA-256 digest of all of the standard output.

=cut
