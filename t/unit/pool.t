use v5.36;
use Test2::V0;
use File::Temp  ();
use Time::HiRes ();
use Permutl::Pool;

my $dir = File::Temp::tempdir( CLEANUP => 1 );

sub script ( $name, $code ) {
    my $path = "$dir/$name";
    open my $handle, '>', $path or die "open $path: $!";
    print {$handle} $code or die "print $path: $!";
    close $handle         or die "close $path: $!";
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
