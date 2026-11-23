use v5.36;
use Test2::V0;
use Digest::SHA ();
use File::Temp  ();
use POSIX       ();
use Time::HiRes ();
use Permutl::Pool;

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

sub run_one ( $path, %fields ) {
    my $result;
    Permutl::Pool::run(
        jobs => 1,
        next => do {
            my @queue = ( task( $path, %fields ) );
            sub { shift @queue }
        },
        done => sub ( $task, $got ) { $result = $got; return },
    );
    return $result;
}

subtest 'a passing test' => sub {
    my $result = run_one( script( 'pass.t', qq{print "1..2\\nok 1\\nok 2\\n";\n} ) );
    is $result, hash { field passed => 1; field exit => 0; field timed_out => 0; field stopped => 0; etc }, 'result';
    is $result->{output}, "1..2\nok 1\nok 2\n", 'the output is captured';
};

subtest 'a failing test and a nonzero exit' => sub {
    is run_one( script( 'fail.t', qq{print "1..1\\nnot ok 1\\n";\n} ) ),
      hash { field passed => 0; field early => 1; field exit => 0; etc }, 'a failed assertion';
    is run_one( script( 'exit.t', qq{print "1..1\\nok 1\\n"; exit 3;\n} ) ),
      hash { field passed => 0; field early => 0; field exit => 3; etc }, 'a nonzero exit status';
    is run_one( script( 'partial.t', q{$| = 1; print "1..1\nok 1"; exit 0;} ) ),
      hash { field passed => 1; etc }, 'a last line without a line feed is read';
};

subtest 'the environment and the working directory reach the test' => sub {
    local $ENV{PERMUTL_POOL_REMOVED} = 'present';
    my $path = script( 'env.t',
        q{use Cwd; print "$ENV{PERMUTL_POOL_ADDED}|", ( $ENV{PERMUTL_POOL_REMOVED} // 'gone' ), '|', getcwd(), "\n";} );
    my $result = run_one( $path, env => { PERMUTL_POOL_ADDED => 'added', PERMUTL_POOL_REMOVED => undef } );
    like $result->{output}, qr{\Aadded[|]gone[|].*\Q$dir\E\n\z},
      'variables are set and removed, and the directory is changed';
};

subtest 'standard error goes to the named file' => sub {
    my $path = script( 'stderr.t', qq{print STDERR "diagnostic\\n"; print "1..1\\nok 1\\n";\n} );
    run_one($path);
    open my $handle, '<', "$path.err" or die "open: $!";
    is scalar( readline $handle ), "diagnostic\n", 'standard error is kept apart from the TAP stream';
};

subtest 'a time limit ends the test and its children' => sub {
    my $marker = "$dir/child-alive";
    my $path   = script( 'hang.t', <<"PERL" );
\$| = 1;
print "1..1\\n";
if ( !fork ) { sleep 2; open my \$out, '>', '$marker'; exit 0 }
sleep 30;
PERL
    my $started = Time::HiRes::time();
    my $result  = run_one( $path, timeout => 0.5 );
    my $elapsed = Time::HiRes::time() - $started;
    is $result, hash { field timed_out => 1; field passed => 0; etc }, 'the result reports the time limit';
    ok $elapsed < 5, 'the pool does not wait for the hanging test';
    sleep 3;
    ok !-e $marker, 'the child of the test was ended with it';
};

subtest 'a test gets a chance to clean up before it is ended' => sub {
    my $marker = "$dir/term-received";
    my $path   = script( 'graceful.t', <<"PERL" );
\$| = 1;
\$SIG{TERM} = sub { open my \$out, '>', '$marker'; close \$out; exit 0 };
print "1..1\\n";
sleep 30;
PERL
    my $result = run_one( $path, timeout => 0.5 );
    ok -e $marker, 'the test received TERM';
    is $result->{timed_out}, 1, 'the result reports the time limit';

    my $stubborn = script( 'stubborn.t', q{$| = 1; $SIG{TERM} = 'IGNORE'; print "1..1\n"; sleep 30;} );
    my $started  = Time::HiRes::time();
    is run_one( $stubborn, timeout => 0.5 )->{timed_out}, 1, 'a test that ignores TERM is ended';
    ok Time::HiRes::time() - $started < 5, 'without waiting for it';
};

subtest 'stop_on_failure ends the test at the first failure' => sub {
    my $path    = script( 'slow-fail.t', qq{\$| = 1; print "1..2\\nnot ok 1\\n"; sleep 30; print "ok 2\\n";\n} );
    my $started = Time::HiRes::time();
    my $result  = run_one( $path, stop_on_failure => 1 );
    ok Time::HiRes::time() - $started < 5, 'the pool does not wait for the rest of the test';
    is $result, hash { field stopped => 1; field passed => 0; field timed_out => 0; etc },
      'the result reports the early stop';

    my $todo = script( 'todo.t', qq{\$| = 1; print "1..2\\nnot ok 1 # TODO later\\nok 2\\n";\n} );
    is run_one( $todo, stop_on_failure => 1 ), hash { field stopped => 0; field passed => 1; etc },
      'a TODO failure does not stop the test';
};

subtest 'a command that cannot start fails' => sub {
    my $result;
    Permutl::Pool::run(
        jobs => 1,
        next => do {
            my @queue = ( { task('x')->%*, command => ["$dir/no-such-program"] } );
            sub { shift @queue }
        },
        done => sub ( $task, $got ) { $result = $got; return },
    );
    is $result, hash { field passed => 0; field exit => 127; etc }, 'exit status 127';
};

subtest 'tasks run in parallel and follow-up tasks run first' => sub {
    my $sleeper = script( 'sleep.t', qq{sleep 1; print "1..1\\nok 1\\n";\n} );
    my @queue   = map { task( $sleeper, payload => "first-$_" ) } 1 .. 4;
    my @order;
    my $started = Time::HiRes::time();
    my $count   = Permutl::Pool::run(
        jobs => 4,
        next => sub { shift @queue },
        done => sub ( $task, $result ) {
            push @order, $task->{payload};
            return task( script( 'quick.t', qq{print "1..1\\nok 1\\n";\n} ), payload => 'follow-up' )
              if $task->{payload} eq 'first-1';
            return;
        },
    );
    my $elapsed = Time::HiRes::time() - $started;
    is $count, 5, 'every task ran';
    ok $elapsed < 3, "four one-second tasks ran side by side ($elapsed s)";
    is scalar( grep { $_ eq 'follow-up' } @order ), 1, 'the follow-up task ran';
};

subtest 'no more tasks run side by side than the jobs allow' => sub {
    my $running = "$dir/running";
    mkdir $running or die "mkdir: $!";
    my $path = script( 'crowd.t', <<"PERL" );
\$| = 1;
open my \$mark, '>', "$running/\$\$" or die "mark: \$!";
close \$mark;
select undef, undef, undef, 0.3;
my \@present = glob "$running/*";
print "1..1\\n", ( \@present <= 2 ? 'ok' : 'not ok' ), " 1 - \@{[ scalar \@present ]} running\\n";
unlink "$running/\$\$";
PERL
    my @queue  = map { task($path) } 1 .. 6;
    my @passed = ();
    Permutl::Pool::run(
        jobs => 2,
        next => sub { shift @queue },
        done => sub ( $task, $result ) { push @passed, $result->{passed}; return },
    );
    is \@passed, [ (1) x 6 ], 'every task saw at most two tasks running';
};

subtest 'the captured output keeps its end when a test prints a lot' => sub {
    my $path =
      script( 'chatty.t', q{print "# filler line number $_\n" for 1 .. 20_000; print "1..1\nok 1 - last line\n";} );
    my $result = run_one($path);
    is $result->{passed},           1,       'the test stream is read in full';
    is length( $result->{output} ), 262_144, 'the captured output stops at its limit';
    like $result->{output}, qr/ok 1 - last line\n\z/, 'and keeps the end of the stream';

    my $short = run_one( script( 'short.t', qq{print "1..1\\n"; print "ok 1\\n";\n} ) );
    is $short->{output}, "1..1\nok 1\n", 'a short stream is captured whole';
};

subtest 'the result carries a digest of the whole output' => sub {
    my $text = join q{}, ( map { "# filler line number $_\n" } 1 .. 20_000 ), "1..1\nok 1 - last line\n";
    my $path =
      script( 'loud.t', q{print "# filler line number $_\n" for 1 .. 20_000; print "1..1\nok 1 - last line\n";} );
    is run_one($path)->{digest}, Digest::SHA::sha256_hex($text),
      'the digest covers the output beyond the capture limit';
    isnt run_one( script( 'quiet.t', qq{print "1..1\\nok 1\\n";\n} ) )->{digest}, Digest::SHA::sha256_hex($text),
      'a different output has a different digest';
};

sub wait_for (@paths) {
    for ( 1 .. 100 ) {
        return 1 if !grep { !-s } @paths;
        Time::HiRes::sleep(0.05);
    }
    return 0;
}

sub number_in ($path) {
    open my $handle, '<', $path or die "open $path: $!";
    my $number = readline $handle;
    chomp $number;
    return $number;
}

# A container without an init process never reaps an orphan, so a process that ended can stay in the table.
sub gone ($pid) {
    for ( 1 .. 60 ) {
        return 1 if !kill 0, $pid;
        return 1 if qx{ps -o stat= -p $pid 2>/dev/null} =~ /\A\s*Z/;
        Time::HiRes::sleep(0.05);
    }
    return 0;
}

subtest 'a signal ends the polite tasks, the stubborn tasks, and their children' => sub {
    my $note   = q{open my $out, '>', "$0.pid"; print {$out} $$; close $out;};
    my $polite = script( 'polite.t',
        qq{\$SIG{TERM} = sub { open my \$out, '>', "\$0.cleaned"; print {\$out} 1; close \$out; exit 0 };\n$note sleep 30;}
    );
    my $stubborn = script( 'deaf.t', qq{\$SIG{TERM} = 'IGNORE';\n$note sleep 30;} );
    my $family   = script( 'family.t',
        qq{if ( !fork ) { open my \$out, '>', "\$0.child"; print {\$out} \$\$; close \$out; sleep 30; exit 0 }\n$note sleep 30;}
    );
    my $loose = script( 'loose.t',
        qq{if ( !fork ) { setpgrp 0, 0; open my \$out, '>', "\$0.child"; print {\$out} \$\$; close \$out; sleep 30; exit 0 }\n$note sleep 30;}
    );

    pipe my $read, my $write or die "pipe: $!";
    my $runner = fork;
    die "fork: $!" if !defined $runner;
    if ( !$runner ) {
        close $read;
        my @queue = map { task($_) } $polite, $stubborn, $family, $loose;
        my $ended = eval {
            Permutl::Pool::run( jobs => 4, next => sub { shift @queue }, done => sub { return } );
            1;
        };
        my $error = $@;
        my $left  = kill 0, number_in("$stubborn.pid");
        print {$write} $ended ? 'completed' : ref $error ? $error->signal : "died: $error", " $left\n";
        close $write;
        POSIX::_exit(0);
    }
    close $write;
    ok wait_for( "$polite.pid", "$stubborn.pid", "$family.pid", "$family.child", "$loose.pid", "$loose.child" ),
      'the tasks started';
    my $started = Time::HiRes::time();
    kill 'TERM', $runner;
    my $report  = readline $read;
    my $elapsed = Time::HiRes::time() - $started;
    waitpid $runner, 0;

    is $report, "TERM 0\n", 'the pool raises the signal after every task is reaped';
    ok -s "$polite.cleaned",               'a task that handles the signal cleans up';
    ok $elapsed < 10,                      'the pool does not wait for the tasks to finish on their own';
    ok gone( number_in("$family.child") ), 'the child of a task is ended';
    ok gone( number_in("$loose.child") ),  'and so is a child that left the process group';
};

subtest 'a forced end works and stays quiet without the ps command' => sub {
    my $empty = "$dir/empty";
    mkdir $empty or die "mkdir: $!";
    my $path = script( 'no-ps.t', q{$| = 1; print "1..1\n"; sleep 30;} );
    open my $saved, '>&', \*STDERR          or die "save: $!";
    open STDERR,    '>',  "$dir/driver.err" or die "redirect: $!";
    my $result = do {
        local $ENV{PATH} = $empty;
        run_one( $path, timeout => 0.5 );
    };
    open STDERR, '>&', $saved or die "restore: $!";
    is $result->{timed_out}, 1, 'the time limit ends the test';
    is -s "$dir/driver.err", 0, 'the driver prints no warning';
};

subtest 'a forced end reaches a child that left the process group' => sub {
    my $code = <<'PERL';
$| = 1;
if ( !fork ) { setpgrp 0, 0; open my $out, '>', "$0.child"; print {$out} $$; close $out; sleep 30; exit 0 }
print "1..2\nnot ok 1\n";
sleep 30;
PERL
    my $late = script( 'escape-late.t', $code );
    is run_one( $late, timeout => 1 )->{timed_out}, 1, 'the test runs into its time limit';
    ok wait_for("$late.child"),          'its child started';
    ok gone( number_in("$late.child") ), 'the time limit ends the child';

    my $failed = script( 'escape-failed.t', $code );
    is run_one( $failed, stop_on_failure => 1 )->{stopped}, 1, 'the test stops at its first failure';
    ok wait_for("$failed.child"),          'its child started';
    ok gone( number_in("$failed.child") ), 'the early stop ends the child';
};

subtest 'a finished test leaves no child behind and holds no output open' => sub {
    my $path = script( 'litter.t', <<'PERL' );
$| = 1;
if ( !fork ) { open my $out, '>', "$0.child"; print {$out} $$; close $out; sleep 30; exit 0 }
sleep 1 while !-s "$0.child";
print "1..1\nok 1\n";
PERL
    my $result = run_one($path);
    is $result->{passed}, 1, 'the test passes';
    ok gone( number_in("$path.child") ), 'its child is ended';

    my $detached = script( 'detached.t', <<'PERL' );
$| = 1;
if ( !fork ) { setpgrp 0, 0; open my $out, '>', "$0.child"; print {$out} $$; close $out; sleep 5; exit 0 }
sleep 1 while !-s "$0.child";
print "1..1\nok 1\n";
PERL
    my $started = Time::HiRes::time();
    my $escaped = run_one($detached);
    my $elapsed = Time::HiRes::time() - $started;
    is $escaped->{passed}, 1, 'a test with a detached child passes';
    ok $elapsed < 4, "the pool stops reading after the test ends ($elapsed s)";
    kill 'KILL', number_in("$detached.child");
};

subtest 'a test that exits cleanly after its time limit does not pass' => sub {
    my $path   = script( 'late.t', q{$| = 1; $SIG{TERM} = sub { exit 0 }; print "1..1\nok 1\n"; sleep 30;} );
    my $result = run_one( $path, timeout => 0.5 );
    is $result, hash { field timed_out => 1; field exit => 0; field signal => 0; field passed => 0; etc },
      'the time limit decides';
};

subtest 'a malformed task is refused' => sub {
    like dies {
        Permutl::Pool::run(
            jobs => 1,
            next => do {
                my @queue = ( { command => 'perl' } );
                sub { shift @queue }
            },
            done => sub { return }
        )
    }, qr/did not pass type constraint/, 'refused';
};

done_testing;
