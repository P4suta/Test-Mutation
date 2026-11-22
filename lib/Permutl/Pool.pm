package Permutl::Pool;
use v5.36;
use Digest::SHA            ();
use IO::Select             ();
use POSIX                  ();
use Time::HiRes            ();
use Types::Standard        qw(Any ArrayRef Bool CodeRef Dict HashRef Int Maybe Num Optional Str);
use Types::Common::Numeric qw(PositiveInt PositiveNum);
use Type::Params           qw(signature_for);
use Permutl::Interrupted;
use Permutl::Tap;

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
    my ( %slots, @ready );
    my $select    = IO::Select->new;
    my $exhausted = 0;
    my $completed = 0;
    my $signal;
    local $SIG{HUP}  = sub { $signal = 'HUP' };
    local $SIG{INT}  = sub { $signal = 'INT' };
    local $SIG{TERM} = sub { $signal = 'TERM' };

    while (1) {
        if ($signal) {
            _end_all( values %slots );
            die Permutl::Interrupted->new( signal => $signal );    ## no critic (ErrorHandling::RequireCarping)
        }
        while ( keys %slots < $arg->jobs ) {
            my $task = shift @ready;
            if ( !$task && !$exhausted ) {
                $task      = $arg->next->();
                $exhausted = 1 if !$task;
            }
            last if !$task;
            my $slot = _spawn( $TASK->assert_return($task) );
            $slots{ $slot->{pid} } = $slot;
            $select->add( $slot->{handle} );
        }
        last if !%slots;

        _read_ready( $select, \%slots );
        for my $slot ( values %slots ) {
            _supervise($slot);
            next                               if !_finished($slot);
            $select->remove( $slot->{handle} ) if !$slot->{eof};
            close $slot->{handle} or die "close pipe: $!\n";
            delete $slots{ $slot->{pid} };
            $completed++;
            my $follow_up = $arg->done->( $slot->{task}, _result($slot) );
            push @ready, $follow_up if $follow_up;
        }
    }
    return $completed;
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
        close $read;
        setpgrp 0, 0;
        _exec_child( $task, $write );
    }
    close $write or die "close pipe: $!\n";
    my $now = Time::HiRes::time();
    return {
        task     => $task,
        pid      => $pid,
        handle   => $read,
        buffer   => q{},
        output   => q{},
        digest   => Digest::SHA->new(256),
        tap      => Permutl::Tap::start(),
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
        open STDIN,  '<',  '/dev/null'     or die "stdin: $!\n";
        open STDOUT, '>&', $write          or die "stdout: $!\n";
        open STDERR, '>',  $task->{stderr} or die "stderr: $!\n";
        exec { $task->{command}[0] } $task->{command}->@* or die "exec $task->{command}[0]: $!\n";
    };
    print {*STDERR} "permutl: $@" if !$ok;
    POSIX::_exit(127);
    return;
}

sub _read_ready ( $select, $slots ) {
    my %by_fileno = map { fileno( $_->{handle} ) => $_ } grep { !$_->{eof} } values $slots->%*;
    for my $handle ( $select->can_read($POLL_SECONDS) ) {
        my $slot = $by_fileno{ fileno $handle };
        my $read = sysread $handle, my $chunk, 65_536;
        if ($read) {
            _consume( $slot, $chunk );
            next;
        }
        $slot->{eof} = 1;
        $select->remove($handle);
    }
    return;
}

sub _consume ( $slot, $chunk ) {
    $slot->{digest}->add($chunk);
    $slot->{output} .= $chunk;
    $slot->{output} = substr $slot->{output}, -$OUTPUT_LIMIT if length $slot->{output} > $OUTPUT_LIMIT;
    $slot->{buffer} .= $chunk;
    while ( $slot->{buffer} =~ s/\A([^\n]*)\n// ) {
        $slot->{tap} = Permutl::Tap::feed( $slot->{tap}, $1 );
    }
    return;
}

sub _signal_group ( $slot, $signal ) {
    kill $signal, -$slot->{pid};
    kill $signal, $slot->{pid};
    return;
}

sub _descendants (@roots) {
    open my $listing, q{-|}, 'ps', '-A', '-o', 'pid=,ppid=' or return;
    my %children;
    while ( my $line = readline $listing ) {
        my ( $pid, $parent ) = $line =~ /(\d+)\s+(\d+)/ or next;
        push $children{$parent}->@*, $pid;
    }
    close $listing or return;
    my @found;
    my @queue = @roots;
    while (@queue) {
        my @next = ( $children{ shift @queue } || [] )->@*;
        push @found, @next;
        push @queue, @next;
    }
    return @found;
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
    if ( $now > $slot->{deadline} && !$slot->{stopped} ) {
        $slot->{timed_out} = 1;
        _ask_to_end($slot);
    }
    elsif ( $slot->{task}{stop_on_failure} && !$slot->{stopped} && Permutl::Tap::failed_already( $slot->{tap} ) ) {
        $slot->{stopped} = 1;
        _ask_to_end($slot);
    }
    _signal_group( $slot, 'KILL' ) if defined $slot->{asked} && $now - $slot->{asked} > $GRACE_SECONDS;
    if ( waitpid( $slot->{pid}, POSIX::WNOHANG ) == $slot->{pid} ) {
        $slot->{status} = $?;
        $slot->{ended}  = Time::HiRes::time();
        _signal_group( $slot, 'KILL' );
        _end_escaped( $slot->{escaped}->@* ) if $slot->{escaped};
    }
    return;
}

sub _finished ($slot) {
    return 0 if !defined $slot->{status};
    return 1 if $slot->{eof};
    return Time::HiRes::time() - $slot->{ended} > $DRAIN_SECONDS;
}

sub _result ($slot) {
    $slot->{tap} = Permutl::Tap::feed( $slot->{tap}, $slot->{buffer} ) if length $slot->{buffer};
    my $exit        = $slot->{status} >> 8;
    my $signal      = $slot->{status} & 127;
    my $interrupted = $slot->{timed_out} || $slot->{stopped} || $signal;
    return {
        exit      => $exit,
        signal    => $signal,
        timed_out => $slot->{timed_out}                                           ? 1 : 0,
        stopped   => $slot->{stopped}                                             ? 1 : 0,
        passed    => !$interrupted && Permutl::Tap::passed( $slot->{tap}, $exit ) ? 1 : 0,
        early     => Permutl::Tap::failed_already( $slot->{tap} ),
        duration  => $slot->{ended} - $slot->{started},
        output    => $slot->{output},
        digest    => $slot->{digest}->hexdigest,
    };
}

1;

__END__

=head1 NAME

Permutl::Pool - run test processes in parallel with time limits

=head1 SYNOPSIS

    Permutl::Pool::run(
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
C<passed> is true when the process ran to its end and its TAP stream passed.
C<early> is true when the stream had failed before the process ended.
C<output> holds the end of the standard output, and C<digest> is the SHA-256 digest of all of it.

=cut
