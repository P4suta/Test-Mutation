use v5.36;
use Test2::V0;
use File::Temp  ();
use POSIX       ();
use Time::HiRes ();
use Test::Mutation::Pool;

my $dir = File::Temp::tempdir( CLEANUP => 1 );

# A broken pool may leave a test script behind, so each script ends on its own after a while.
my $OWN_END = "alarm 90;\n";

sub script ( $name, $code ) {
    my $path = "$dir/$name";
    open my $handle, '>', $path or die "open $path: $!";
    print {$handle} ( $name =~ /[.]t\z/ ? $OWN_END : q{} ), $code or die "print $path: $!";
    close $handle or die "close $path: $!";
    return $path;
}

sub task ( $path, %fields ) {
    return {
        command         => [ $^X, $path ],
        env             => {},
        cwd             => $dir,
        timeout         => 20,
        stop_on_failure => 0,
        stderr          => "$path.err",
        %fields,
    };
}

sub run_all ( $jobs, @tasks ) {
    my %result;
    Test::Mutation::Pool::run(
        jobs => $jobs,
        next => sub { shift @tasks },
        done => sub ( $task, $got ) { $result{ $task->{command}[1] } = $got; return },
    );
    return \%result;
}

sub text_of ($path) {
    open my $handle, '<', $path or return;
    local $/ = undef;
    return scalar readline $handle;
}

sub wait_for (@paths) {
    for ( 1 .. 100 ) {
        return 1 if !grep { !-s } @paths;
        Time::HiRes::sleep(0.05);
    }
    return 0;
}

sub gone ($pid) {
    for ( 1 .. 60 ) {
        return 1 if !kill 0, $pid;
        return 1 if qx{ps -o stat= -p $pid 2>/dev/null} =~ /\A\s*Z/;
        Time::HiRes::sleep(0.05);
    }
    return 0;
}

subtest 'the pool asks for a task once more after the last one and then never again' => sub {
    my @queue = map { task( script( "plain-$_.t", qq{print "1..1\\nok 1\\n";\n} ) ) } 1 .. 3;
    push @queue, task( script( 'last.t', qq{sleep 1;\nprint "1..1\\nok 1\\n";\n} ) );
    my $calls = 0;
    Test::Mutation::Pool::run( jobs => 2, next => sub { $calls++; shift @queue }, done => sub { return } );
    is $calls, 5, 'four tasks and the one call that returns nothing, also while a test still runs';
};

subtest 'an error of a callback ends the tests that still run' => sub {
    my $quick   = script( 'quick.t',   qq{print "1..1\\nok 1\\n";\n} );
    my $sleeper = script( 'sleeper.t', q{open my $out, '>', "$0.pid"; print {$out} $$; close $out; sleep 30;} );
    my @queue   = ( task($sleeper), task($quick) );
    like dies {
        Test::Mutation::Pool::run(
            jobs => 2,
            next => sub { shift @queue },
            done => sub ( $task, $result ) { wait_for("$sleeper.pid"); die "the callback broke\n" },
        )
    }, qr/\Athe callback broke\n\z/, 'the error passes through';
    ok gone( text_of("$sleeper.pid") ), 'and no test is left behind';
};

subtest 'a test gets no descriptor beyond the standard three' => sub {
    my $path = script( 'descriptors.t',
        q{use POSIX (); print "1..1\nok 1\n"; print "# open ", join( q{ }, grep { POSIX::fstat($_) } 3 .. 40 ), "\n";}
    );
    my ($alone)  = qx{$^X $path}                              =~ /^# open (.*)$/m;
    my ($pooled) = run_all( 1, task($path) )->{$path}{output} =~ /^# open (.*)$/m;
    is $pooled, $alone, 'the open descriptors match a run from a shell';
};

subtest 'a test that moved into the process group of the pool is ended at its time limit' => sub {
    my $path = script( 'joined.t', <<'PERL' );
$| = 1;
setpgrp 0, getpgrp getppid;
print "1..1\n";
sleep 30;
PERL
    my $result = do {
        local $SIG{ALRM} = sub { die "the pool did not end the test\n" };
        alarm 15;
        my $got = run_all( 1, task( $path, timeout => 1 ) )->{$path};
        alarm 0;
        $got;
    };
    is [ $result->@{qw(timed_out passed)} ], [ 1, 0 ], 'the signal reaches the process itself';
    ok $result->{duration} < 10, 'without a wait for the end of its sleep';
};

subtest 'a test that leaves a child behind does not hide the output of another test' => sub {
    my $detached = script( 'leaves.t', <<'PERL' );
$| = 1;
if ( !fork ) { setpgrp 0, 0; open my $out, '>', "$0.child"; print {$out} $$; close $out; sleep 8; exit 0 }
sleep 1 while !-s "$0.child";
print "1..1\nok 1\n";
PERL
    my $slow   = script( 'slow.t', q{$| = 1; print "1..2\nok 1\n"; sleep 3; print "ok 2\n";} );
    my $result = run_all( 2, task($detached), task($slow) );
    is $result->{$slow}, hash { field passed => 1; field output => "1..2\nok 1\nok 2\n"; etc },
      'the slower test is read to its end';
    kill 'KILL', text_of("$detached.child");
};

subtest 'standard input of a test is empty' => sub {
    my $input = script( 'input.txt', "a line for the driver\n" );
    my $path  = script( 'reads.t',   q{my $line = <STDIN>; print "1..1\n", defined $line ? 'not ok' : 'ok', " 1\n";} );
    open my $saved, '<&', \*STDIN or die "save: $!";
    open STDIN,     '<',  $input  or die "redirect: $!";
    my $result = run_all( 1, task($path) );
    open STDIN, '<&', $saved or die "restore: $!";
    is $result->{$path}{passed}, 1, 'the test reads the end of the file at once';
};

subtest 'the driver may hold its standard handles in memory' => sub {
    my $path = script( 'memory.t', q{print STDERR "a diagnostic\n"; print "1..1\nok 1\n";} );
    open my $saved_output, '>&', \*STDOUT or die "save: $!";
    open my $saved_errors, '>&', \*STDERR or die "save: $!";
    close STDOUT or die "close: $!";
    close STDERR or die "close: $!";
    open STDOUT, '>', \my $held_output or die "memory: $!";
    open STDERR, '>', \my $held_errors or die "memory: $!";
    my $result = run_all( 1, task($path) );
    close STDOUT or die "close: $!";
    close STDERR or die "close: $!";
    open STDOUT, '>&', $saved_output or die "restore: $!";
    open STDERR, '>&', $saved_errors or die "restore: $!";
    is $result->{$path}, hash { field passed => 1; field output => "1..1\nok 1\n"; etc },
      'the pool reads the output of the test';
    is text_of("$path.err"),           "a diagnostic\n", 'and the standard error of the test goes to its file';
    is [ $held_output, $held_errors ], [ undef, undef ], 'nothing reaches the handles of the driver';
};

subtest 'a command that cannot start leaves its reason in standard error' => sub {
    my $missing = "$dir/no-such-program";
    my $result  = run_all( 1, { task('absent')->%*, command => [$missing], stderr => "$dir/absent.err" } );
    is [ values $result->%* ]->[0]{exit}, 127, 'the exit status of a command that was not found';
    like text_of("$dir/absent.err"), qr/\Amutation: cannot start \Q$missing\E: [^\n]+\n\z/,
      'the message names the command and the reason';
};

subtest 'a line that arrives in two pieces is one line' => sub {
    my $path = script( 'pieces.t',
        q{$| = 1; print "1..2\nok 1 - the first"; select undef, undef, undef, 0.5; print " half\nok 2\n";} );
    is run_all( 1, task($path) )->{$path}, hash { field passed => 1; field early => 0; etc },
      'the two pieces count as one passing line';
    my $failing = script( 'pieces-fail.t',
        q{$| = 1; print "1..1\nnot "; select undef, undef, undef, 0.5; print "ok 1\n"; sleep 5;} );
    my $started = Time::HiRes::time();
    my $stopped = run_all( 1, task( $failing, stop_on_failure => 1 ) )->{$failing};
    is $stopped->{stopped}, 1, 'a failure that arrives in two pieces stops the test';
    ok Time::HiRes::time() - $started < 4, 'at once';
};

subtest 'a grandchild that left the process group is ended at the time limit' => sub {
    my $path = script( 'grand.t', <<'PERL' );
$| = 1;
if ( !fork ) {
    if ( !fork ) { setpgrp 0, 0; open my $out, '>', "$0.grandchild"; print {$out} $$; close $out; sleep 30; exit 0 }
    sleep 30;
    exit 0;
}
sleep 1 while !-s "$0.grandchild";
print "1..1\n";
sleep 30;
PERL
    is run_all( 1, task( $path, timeout => 2 ) )->{$path}{timed_out}, 1, 'the test runs into its time limit';
    ok gone( text_of("$path.grandchild") ), 'the grandchild is ended';
};

sub interrupted (%setup) {
    pipe my $read, my $write or die "pipe: $!";
    my $runner = fork;
    die "fork: $!" if !defined $runner;
    if ( !$runner ) {
        close $read;
        local $ENV{PATH} = $setup{path} if defined $setup{path};
        my @queue = map { task($_) } $setup{tasks}->@*;
        my $ended = eval {
            Test::Mutation::Pool::run( jobs => 4, next => sub { shift @queue }, done => sub { return } );
            1;
        };
        print {$write} $ended ? 'completed' : ref $@ ? $@->signal : "died: $@", "\n";
        close $write;
        POSIX::_exit(0);
    }
    close $write;
    wait_for( $setup{started}->@* ) or die 'the tasks did not start';
    kill $setup{signal} || 'TERM', $runner;
    my $report = readline $read;
    waitpid $runner, 0;
    return $report;
}

subtest 'each signal that asks a program to end stops the pool under its name' => sub {
    for my $signal (qw(HUP INT QUIT PIPE TERM)) {
        my $short = script( "short-$signal.t",
                q{open my $out, '>', "$0.pid"; print {$out} $$; close $out; sleep 3; print "1..1\nok 1\n";}
              . q{open my $done, '>', "$0.done"; close $done;} );
        is interrupted( tasks => [$short], started => ["$short.pid"], signal => $signal ), "$signal\n",
          "SIG$signal ends the run under its name";
        ok !-e "$short.done", 'and before the test ends';
    }
};

subtest 'a signal leaves a test the time to clean up' => sub {
    my $patient = script( 'patient.t', <<'PERL' );
$SIG{TERM} = sub {
    select undef, undef, undef, 0.25;
    open my $out, '>', "$0.cleaned";
    print {$out} 1;
    close $out;
    exit 0;
};
open my $out, '>', "$0.pid";
print {$out} $$;
close $out;
sleep 30;
PERL
    is interrupted( tasks => [$patient], started => ["$patient.pid"] ), "TERM\n", 'the pool raises the signal';
    ok -s "$patient.cleaned", 'a handler that needs a quarter of a second finishes its work';
};

subtest 'a signal ends a child that ignores it, with or without the ps command' => sub {
    my $code = <<'PERL';
if ( !fork ) { $SIG{TERM} = 'IGNORE'; open my $out, '>', "$0.child"; print {$out} $$; close $out; sleep 30; exit 0 }
$SIG{TERM} = sub { exit 0 };
sleep 30;
PERL
    my $with = script( 'deaf-child.t', $code );
    interrupted( tasks => [$with], started => ["$with.child"] );
    ok gone( text_of("$with.child") ), 'the child is ended';

    my $empty = "$dir/empty";
    mkdir $empty or die "mkdir: $!";
    my $without = script( 'deaf-child-no-ps.t', $code );
    interrupted( tasks => [$without], started => ["$without.child"], path => $empty );
    ok gone( text_of("$without.child") ), 'the child in the group of its test is ended without ps too';
};

done_testing;
