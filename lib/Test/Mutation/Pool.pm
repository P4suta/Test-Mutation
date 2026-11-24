package Test::Mutation::Pool;
use v5.36;
use Digest::SHA            ();
use Fcntl                  ();
use IO::Select             ();
use POSIX                  ();
use Time::HiRes            ();
use Types::Standard        qw(Any ArrayRef Bool CodeRef Dict HashRef Int Maybe Num Optional Str);
use Types::Common::Numeric qw(PositiveInt PositiveNum);
use Type::Params           qw(signature_for);
use Test::Mutation::Interrupted;
use Test::Mutation::Tap;

our $VERSION = '0.001';

my $OUTPUT_LIMIT  = 262_144;
my $POLL_SECONDS  = 0.2;
my $DRAIN_SECONDS = 1;
my $GRACE_SECONDS = 0.5;

my $TASK = Dict [
    command         => ArrayRef [Str],
    env             => HashRef [ Maybe [Str] ],
    cwd             => Str,
    timeout         => PositiveNum,
    stop_on_failure => Bool,
    stderr          => Str,
    payload         => Optional [Any],
];

signature_for run => (
    named   => [ jobs => PositiveInt, next => CodeRef, done => CodeRef ],
    returns => Int,
);

sub run ($arg) {
    my %slots;
    my $select    = IO::Select->new;
    my $exhausted = 0;
    my $completed = 0;
    my $signal;
    local $SIG{HUP}  = sub { $signal = 'HUP' };
    local $SIG{INT}  = sub { $signal = 'INT' };
    local $SIG{TERM} = sub { $signal = 'TERM' };

    my $start = sub ($task) {
        my $slot = _spawn( $TASK->assert_return($task) );
        $slots{ $slot->{pid} } = $slot;
        $select->add( $slot->{handle} );
        return;
    };
    my $ended = eval {
        while (1) {
            die Test::Mutation::Interrupted->new( signal => $signal ) if $signal;    ## no critic (ErrorHandling::RequireCarping)
            while ( !$exhausted && keys %slots < $arg->jobs ) {
                my $task = $arg->next->();
                $exhausted = 1 if !$task;
                $start->($task) if $task;
            }
            last if !%slots;

            _read_ready( $select, \%slots );
            _supervise($_) for values %slots;
            for my $slot ( grep { _finished($_) } values %slots ) {
                $select->remove( $slot->{handle} ) if !$slot->{eof};
                close $slot->{handle} or die "close pipe: $!\n";
                delete $slots{ $slot->{pid} };
                $completed++;
                my $follow_up = $arg->done->( $slot->{task}, _result($slot) );
                $start->($follow_up) if $follow_up;
            }
        }
        1;
    };
    return $completed if $ended;

    # A signal, a callback, or the pool itself failed, and no test may outlive the run.
    my $error = $@;
    _end_all( values %slots );
    die $error;    ## no critic (ErrorHandling::RequireCarping)
}

sub _end_all (@slots) {
    my @escaped = _descendants( map { $_->{pid} } @slots );
    _signal_group( $_, 'TERM' ) for @slots;
    my $deadline = Time::HiRes::time() + $GRACE_SECONDS;
    my @running  = @slots;
    while ( @running && Time::HiRes::time() < $deadline ) {
        @running = grep { waitpid( $_->{pid}, POSIX::WNOHANG ) != $_->{pid} } @running;
        Time::HiRes::sleep(0.02) if @running;
    }
    for my $slot (@running) {
        _signal_group( $slot, 'KILL' );
        waitpid $slot->{pid}, 0;
    }
    _signal_group( $_, 'KILL' ) for @slots;
    _end_escaped(@escaped);
    return;
}

sub _spawn ($task) {
    pipe my $read, my $write or die "pipe: $!\n";
    my $pid = fork;
    die "fork: $!\n" if !defined $pid;
    if ( !$pid ) {
        setpgrp 0, 0;
        _exec_child( $task, $write );
    }
    close $write or die "close pipe: $!\n";
    my $now = Time::HiRes::time();
    return {
        task     => $task,
        pid      => $pid,
        handle   => $read,
        output   => q{},
        digest   => Digest::SHA->new(256),
        tap      => Test::Mutation::Tap::start(),
        started  => $now,
        deadline => $now + $task->{timeout},
    };
}

sub _exec_child ( $task, $write ) {
    my $ok = eval {
        chdir $task->{cwd} or die "chdir $task->{cwd}: $!\n";
        my %environment = ( %ENV, $task->{env}->%* );
        delete @environment{ grep { !defined $environment{$_} } keys %environment };
        local %ENV = %environment;
        ## no critic (InputOutput::RequireBriefOpen)
        open my $input,  '<', '/dev/null'     or die "stdin: $!\n";
        open my $errors, '>', $task->{stderr} or die "stderr: $!\n";
        ## use critic
        _take_standard_descriptors( $input, $write, $errors );
        no warnings 'exec';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        exec { $task->{command}[0] } $task->{command}->@* or die "exec $task->{command}[0]: $!\n";
    };
    my $message = "mutation: $@";
    POSIX::write( 2, $message, length $message ) if !$ok;
    POSIX::_exit(127);
    return;
}

# The driver may hold STDOUT or STDERR in memory or closed, so the child sets descriptors 0 to 2 and no Perl handle.
# Each source moves above the three first, because a source that sits on one of them would be replaced too early.
sub _take_standard_descriptors (@handles) {
    my @copies = map { fcntl $_, Fcntl::F_DUPFD(), 3 } @handles;
    die "dup: $!\n" if grep { !defined } @copies;
    for my $target ( 0 .. 2 ) {
        defined POSIX::dup2( $copies[$target], $target ) or die "dup2: $!\n";
    }
    POSIX::close($_) for @copies;
    return;
}

sub _read_ready ( $select, $slots ) {
    my %by_fileno = map { fileno( $_->{handle} ) => $_ } grep { !$_->{eof} } values $slots->%*;
    for my $handle ( $select->can_read($POLL_SECONDS) ) {
        my $slot = $by_fileno{ fileno $handle };
        if ( sysread $handle, my $chunk, 65_536 ) {
            _consume( $slot, $chunk );
        }
        else {
            $slot->{eof} = 1;
            $select->remove($handle);
        }
    }
    return;
}

sub _consume ( $slot, $chunk ) {
    $slot->{digest}->add($chunk);
    $slot->{output} = substr $slot->{output} . $chunk, -$OUTPUT_LIMIT;
    $slot->{tap}    = Test::Mutation::Tap::feed( $slot->{tap}, $chunk );
    return;
}

sub _signal_group ( $slot, $signal ) {
    kill $signal, -$slot->{pid};
    kill $signal, $slot->{pid};
    return;
}

sub _descendants (@roots) {
    no warnings 'exec';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    open my $listing, q{-|}, 'ps', '-A', '-o', 'pid=,ppid=' or return;
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

sub _ask_to_end ($slot) {
    return if defined $slot->{asked};
    $slot->{asked}   = Time::HiRes::time();
    $slot->{escaped} = [ _descendants( $slot->{pid} ) ];
    _signal_group( $slot, 'TERM' );
    return;
}

sub _supervise ($slot) {
    my $now = Time::HiRes::time();
    return if defined $slot->{status};

    # A test that ended keeps its own result, however late the pool looks at it.
    return if _reaped($slot);
    if ( $now > $slot->{deadline} && !$slot->{stopped} ) {
        $slot->{timed_out} = 1;
        _ask_to_end($slot);
    }
    elsif ( $slot->{task}{stop_on_failure} && !$slot->{stopped} && Test::Mutation::Tap::failed_already( $slot->{tap} ) )
    {
        $slot->{stopped} = 1;
        _ask_to_end($slot);
    }
    _signal_group( $slot, 'KILL' ) if defined $slot->{asked} && $now - $slot->{asked} > $GRACE_SECONDS;
    return;
}

sub _reaped ($slot) {
    return 0 if waitpid( $slot->{pid}, POSIX::WNOHANG ) != $slot->{pid};
    $slot->{status} = $?;
    $slot->{ended}  = Time::HiRes::time();
    _signal_group( $slot, 'KILL' );
    _end_escaped( $slot->{escaped}->@* ) if $slot->{escaped};
    return 1;
}

sub _finished ($slot) {
    return 0 if !defined $slot->{status};
    return 1 if $slot->{eof};
    return Time::HiRes::time() - $slot->{ended} > $DRAIN_SECONDS;
}

sub _result ($slot) {
    my $tap = Test::Mutation::Tap::finish( $slot->{tap} );
    return {
        exit      => $slot->{status} >> 8,
        signal    => $slot->{status} & 127,
        timed_out => $slot->{timed_out}                                                          ? 1 : 0,
        stopped   => $slot->{stopped}                                                            ? 1 : 0,
        passed    => !$slot->{timed_out} && Test::Mutation::Tap::passed( $tap, $slot->{status} ) ? 1 : 0,
        early     => Test::Mutation::Tap::failed_already($tap),
        duration  => $slot->{ended} - $slot->{started},
        output    => $slot->{output},
        digest    => $slot->{digest}->hexdigest,
    };
}

1;

__END__

=head1 NAME

Test::Mutation::Pool - run test processes in parallel with time limits

=head1 SYNOPSIS

    Test::Mutation::Pool::run(
        jobs => 4,
        next => sub { return shift @tasks },
        done => sub ( $task, $result ) { return },
    );

=head1 DESCRIPTION

The pool starts every task in its own process group and reads its standard output as TAP.
It ends a task that exceeds its time limit, and a task that asked to stop at the first failure, by signalling the whole group.
Before a forced end the pool lists the descendants of the task with C<ps>, and it ends those that left the group too.

=head1 FUNCTIONS

=head2 run

Runs tasks until C<next> returns nothing and every started task has finished, and returns the number of tasks.
C<done> receives each task with its result, and a task it returns runs before any task from C<next>.

A task has the keys C<command>, C<env>, C<cwd>, C<timeout>, C<stop_on_failure>, C<stderr>, and an optional C<payload>.
An undefined value in C<env> removes the variable.

A result has the keys C<exit>, C<signal>, C<timed_out>, C<stopped>, C<passed>, C<early>, C<duration>, C<output>, and C<digest>.
C<passed> is true when the process ended within its time limit and L<Test::Mutation::Tap> passes its stream and its wait status.
C<early> is true when the stream had failed before the process ended.
C<output> holds the end of the standard output, and C<digest> is the SHA-256 digest of all of it.

=cut
