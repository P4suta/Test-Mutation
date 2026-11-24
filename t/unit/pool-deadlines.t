use v5.36;
use Test2::V0;
use File::Temp  ();
use POSIX       ();
use Time::HiRes ();
use lib 't/lib';
use ManualClock;
use Test::Mutation::Pool;

# The clock of the pool stands still until a step of the test moves it, so every deadline falls at a chosen moment.
# A test process waits at a gate until a step opens it, so the pool meets each deadline while the process is silent.
# Each deadline meets one case a quarter of a second before it and one case exactly at it.

my $dir = File::Temp::tempdir( CLEANUP => 1 );

# A broken pool may leave a test script behind, so each script ends on its own after a while.
sub script ( $name, $code ) {
    my $path = "$dir/$name";
    open my $handle, '>', $path or die "open $path: $!";
    print {$handle} "alarm 60;\n\$| = 1;\n", $code or die "print $path: $!";
    close $handle or die "close $path: $!";
    return $path;
}

my $GATE = qq{select undef, undef, undef, 0.01 until -e "\$0.gate";\n};

sub gated ( $name, $before, $after ) {
    return script( $name, $before . $GATE . $after );
}

sub open_gate ($path) {
    open my $handle, '>', "$path.gate" or die "open $path.gate: $!";
    close $handle or die "close $path.gate: $!";
    return 1;
}

sub number_in ($path) {
    open my $handle, '<', $path or die "open $path: $!";
    my $number = readline $handle;
    return 0 + $number;
}

sub task ( $path, %fields ) {
    return {
        command         => [ $^X, $path ],
        env             => {},
        cwd             => $dir,
        timeout         => 3,
        output_limit    => 1_000_000,
        stop_on_failure => 0,
        %fields,
    };
}

# A pool that never ends would hold the test, and its cleanup would wait on a clock that stands still.
# The alarm therefore ends the whole file at once, which fails it long before a time limit of a mutation run.
# The `after` hook of a payload runs when the pool reports its task.
sub pooled ( $clock, @tasks ) {
    my %result;
    my $jobs = @tasks;
    local $SIG{ALRM} = sub { POSIX::write( 2, "the pool did not end\n", 21 ); POSIX::_exit(1) };
    alarm 5;
    my $ended = eval {
        Test::Mutation::Pool::run(
            jobs  => $jobs,
            clock => $clock,
            next  => sub { shift @tasks },
            done  => sub ( $task, $got ) {
                $result{ $task->{command}[1] } = $got;
                $task->{payload}{after}->() if $task->{payload};
                return;
            },
        );
        1;
    };
    alarm 0;
    die $@ if !$ended;
    return \%result;
}

sub move_by ($seconds) {
    return sub ( $clock, @ ) { return $clock->move($seconds) };
}

# The process of a test is a child of this one, so its end shows as a zombie until the pool reaps it.
# The signal of that end reaches this process while it waits here, outside the wait of the pool.
sub ended ($path) {
    for ( 1 .. 500 ) {
        return 1 if -s "$path.pid" && qx{ps -o stat= -p @{[ number_in("$path.pid") ]} 2>/dev/null} =~ /\A\s*Z/;
        Time::HiRes::sleep(0.01);
    }
    return 0;
}

my $NOTED = qq{open my \$noted, '>', "\$0.pid";\nprint {\$noted} \$\$;\nclose \$noted;\n};

my $PLAN = qq{print "1..1\\n";\n};
my $OK   = qq{print "ok 1\\n";\n};

subtest 'the time limit ends a test at its deadline and no earlier' => sub {
    my $early = gated( 'before-limit.t', $PLAN, $OK );
    my $clock = ManualClock->new( at => 100, steps => [ sub ( $clock, @ ) { $clock->move(2.75); open_gate($early) } ] );
    is pooled( $clock, task($early) )->{$early}, hash { field timed_out => 0; field passed => 1; etc },
      'a quarter of a second before the limit the test runs on';

    my $late = gated( 'at-limit.t', $PLAN, $OK );
    $clock = ManualClock->new( at => 100, steps => [ move_by(3) ] );
    is pooled( $clock, task($late) )->{$late},
      hash { field timed_out => 1; field passed => 0; field signal => 15; etc }, 'at the limit the pool ends it';
    is $clock->asked->[0], 3, 'the first wait lasts until the deadline';
};

subtest 'a test that ignores the request to end meets force when its grace ends and no earlier' => sub {
    my $deaf    = qq{\$SIG{TERM} = 'IGNORE';\n$PLAN};
    my $patient = gated( 'within-grace.t', $deaf, $OK );
    my $clock   = ManualClock->new(
        at    => 100,
        steps => [ move_by(3), sub ( $clock, @ ) { $clock->move(0.25); open_gate($patient) } ]
    );
    is pooled( $clock, task($patient) )->{$patient}, hash { field timed_out => 1; field signal => 0; etc },
      'a quarter of a second into the grace the test ends on its own';
    is [ $clock->asked->@[ 0, 1 ] ], [ 3, 0.5 ], 'the wait after the request lasts for the grace';

    my $stubborn = gated( 'after-grace.t', $deaf, $OK );
    $clock = ManualClock->new( at => 100, steps => [ move_by(3), move_by(0.5) ] );
    is pooled( $clock, task($stubborn) )->{$stubborn}, hash { field timed_out => 1; field signal => 9; etc },
      'at the end of the grace the pool kills it';
};

subtest 'the pool reads a pipe that a process outside the group holds for a second after the end of the test' => sub {
    my $code = <<'PERL';
if ( !fork ) {
    alarm 30;
    setpgrp 0, 0;
    open my $out, '>', "$0.child";
    print {$out} $$;
    close $out;
    select undef, undef, undef, 0.01 until -e "$0.gate";
    print "# late\n";
    exit 0;
}
select undef, undef, undef, 0.01 until -s "$0.child";
print "1..1\nok 1\n";
PERL

    # The drain is the one wait of a second, since the time limit leaves the other waits five seconds.
    my $held  = script( 'held.t', $code );
    my $clock = ManualClock->new(
        at    => 100,
        steps => [
            sub ( $clock, $seconds, @ ) {
                return 0 if $seconds != 1;
                $clock->move(0.75);
                return open_gate($held);
            }
        ]
    );
    is pooled( $clock, task( $held, timeout => 20 ) )->{$held}{output}, "1..1\nok 1\n# late\n",
      'three quarters of a second into the drain the late line arrives';

    my $lost = script( 'lost.t', $code );
    $clock =
      ManualClock->new( at => 100, steps => [ sub ( $clock, $seconds, @ ) { $seconds == 1 && $clock->move(1) } ] );
    is pooled( $clock, task( $lost, timeout => 20 ) )->{$lost}{output}, "1..1\nok 1\n",
      'at the end of the drain the pool reads no more';
    is $clock->untaken, 0, 'the end of the test woke the pool before its pipes closed';
    kill 'KILL', number_in("$lost.child");
};

# The test prints nothing, and a process outside its group holds its pipes, so only the signal of its end can wake the pool.
subtest 'the end of a test whose pipes another process holds wakes the pool at once' => sub {
    my $code = <<'PERL';
if ( !fork ) { alarm 30; setpgrp 0, 0; select undef, undef, undef, 0.01 until -e "$0.late"; print "1..1\nok 1\n"; exit 0 }
PERL
    my $path  = gated( 'held-end.t', $code . $NOTED, "exit 0;\n" );
    my $clock = ManualClock->new(
        at    => 100,
        steps => [
            sub (@) { open_gate($path) && ended($path) },
            sub ( $clock, $seconds, @ ) {
                return 0 if $seconds != 1;
                open my $late, '>', "$path.late" or die "open: $!";
                return 1;
            },
        ]
    );
    is pooled( $clock, task( $path, timeout => 20 ) )->{$path},
      hash { field passed => 1; field output => "1..1\nok 1\n"; etc },
      'the pool reaps the test and reads the pipes until the other process ends';
};

# The callback of the quick test holds the pool until the watched test ended, and the clock then passes its deadline.
subtest 'a test that ended within its time limit keeps its result when the pool looks after the limit' => sub {
    my $quick   = script( 'quick.t', $PLAN . $OK );
    my $watched = gated( 'watched.t', $NOTED . $PLAN, $OK );
    my $clock   = ManualClock->new(
        at    => 100,
        steps => [ sub ( $clock, @ ) { -e "$watched.gate" && $clock->move(2) } ]
    );
    my $results = pooled(
        $clock,
        task( $quick,   payload => { after => sub { open_gate($watched) && ended($watched) } } ),
        task( $watched, timeout => 1.5 )
    );
    is $results->{$watched}, hash { field timed_out => 0; field passed => 1; field duration => 2; etc },
      'the test that ended on its own has its own result';
};

subtest 'the duration of a test is the time of the clock from its start to its end' => sub {
    my $path  = gated( 'timed.t', $PLAN, $OK );
    my $clock = ManualClock->new( at => 100, steps => [ sub ( $clock, @ ) { $clock->move(1.25); open_gate($path) } ] );
    is pooled( $clock, task($path) )->{$path}{duration}, 1.25, 'one and a quarter seconds';
};

subtest 'each wait lasts until the nearest deadline, and five seconds at most' => sub {
    my ( $near, $far ) = map { gated( "$_.t", $PLAN, $OK ) } qw(near far);
    my $clock = ManualClock->new( at => 100, steps => [ sub (@) { open_gate($near) && open_gate($far) } ] );
    pooled( $clock, task( $far, timeout => 4 ), task( $near, timeout => 2 ) );
    is $clock->asked->[0], 2, 'the nearer of two deadlines';

    my $distant = gated( 'distant.t', $PLAN, $OK );
    $clock = ManualClock->new( at => 100, steps => [ sub (@) { open_gate($distant) } ] );
    pooled( $clock, task( $distant, timeout => 600 ) );
    is $clock->asked->[0], 5, 'a far deadline leaves a wait of five seconds';
};

subtest 'a signal ends the wait at once and leaves the tests their grace, then force' => sub {
    my $code   = qq{\$SIG{TERM} = 'IGNORE';\nopen my \$pid, '>', "\$0.pid";\nprint {\$pid} \$\$;\nclose \$pid;\n};
    my $after  = qq{open my \$out, '>', "\$0.passed";\nclose \$out;\n};
    my $signal = sub (@) { kill 'TERM', $$; return 1 };

    # The process of a test is a child of this one, so a process that the pool left unreaped is still there to reap.
    my $reaped = sub ($path) { return waitpid( number_in("$path.pid"), POSIX::WNOHANG() ) == -1 ? 1 : 0 };

    my $patient = gated( 'interrupted-patient.t', $code, $after );
    my $clock   = ManualClock->new(
        at    => 100,
        steps => [ $signal, sub ( $clock, @ ) { $clock->move(0.25); open_gate($patient) } ]
    );
    my $error = dies { pooled( $clock, task( $patient, timeout => 20 ) ) };
    is $error && $error->can('signal') ? $error->signal : $error, 'TERM', 'the pool ends with the signal';
    ok -e "$patient.passed", 'a test that ends a quarter of a second into the grace ends on its own';
    is [ $clock->asked->@[ 0, 1 ] ], [ 5, 0.5 ], 'the end of the pool waits for the grace';
    is $reaped->($patient),          1,          'and the pool reaps it';

    my $stubborn = gated( 'interrupted-stubborn.t', $code, $after );
    $clock = ManualClock->new( at => 100, steps => [ $signal, move_by(0.5) ] );
    $error = dies { pooled( $clock, task( $stubborn, timeout => 20 ) ) };
    is $error && $error->can('signal') ? $error->signal : $error, 'TERM', 'the pool ends with the signal';
    ok !-e "$stubborn.passed", 'a test that is still running when the grace ends is killed';
    is $reaped->($stubborn), 1, 'and reaped';
};

done_testing;
