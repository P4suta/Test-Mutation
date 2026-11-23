use v5.36;
use Test2::V0;
use File::Temp  ();
use Time::HiRes ();

# A process that cannot start and a handle that cannot close are rare, so two overrides provoke them.
# The close override closes the handle and then reports a failure to the subroutine that the pattern names.
our ( $fork_fails, $close_fails_in );

BEGIN {
    no warnings 'once';
    *CORE::GLOBAL::fork = sub {
        return CORE::fork() if !$fork_fails;
        $! = 35;    ## no critic (Variables::RequireLocalizedPunctuationVars)
        return;
    };
    *CORE::GLOBAL::close = sub : prototype(;*) (@handle) {
        my $closed = @handle ? CORE::close( $handle[0] ) : CORE::close();
        my $level  = 1;
        $level++ while ( ( caller $level )[3] || q{} ) eq '(eval)';
        my $caller = ( caller $level )[3]          || 'main';
        return $closed if !defined $close_fails_in || $caller !~ $close_fails_in;
        $! = 5;     ## no critic (Variables::RequireLocalizedPunctuationVars)
        return !1;
    };
}

use Permutl::Pool;

my $dir = File::Temp::tempdir( CLEANUP => 1 );

sub script ( $name, $code ) {
    my $path = "$dir/$name";
    open my $handle, '>', $path or die "open $path: $!";
    print {$handle} $code or die "print $path: $!";
    close $handle         or die "close $path: $!";
    return $path;
}

sub pool_error (%task) {
    my @queue = ( { env => {}, cwd => $dir, timeout => 20, stop_on_failure => 0, %task } );
    return dies {
        Permutl::Pool::run( jobs => 1, next => sub { shift @queue }, done => sub { return } )
    };
}

sub text_of ($path) {
    open my $handle, '<', $path or return;
    local $/ = undef;
    return scalar readline $handle;
}

subtest 'a process that cannot start stops the pool' => sub {
    my $path  = script( 'unreached.t', 'exit 3;' );
    my $error = do {
        local $fork_fails = 1;
        pool_error( command => [ $^X, $path ], stderr => "$path.err" );
    };
    like $error, qr/\Afork: \S/, 'the error names the reason';
};

subtest 'a pipe that does not close stops the pool' => sub {
    for my $place (qw(run _spawn)) {
        my $path  = script( "$place.t", qq{print "1..1\\nok 1\\n";\n} );
        my $error = do {
            local $close_fails_in = qr/::Pool::\Q$place\E\z/;
            pool_error( command => [ $^X, $path ], stderr => "$path.err" );
        };
        like $error, qr/\Aclose pipe: \S/, "a failure in $place";
    }
};

subtest 'a process listing that does not close names no process to end' => sub {
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
    my $error = do {
        local $close_fails_in = qr/::Pool::_descendants\z/;
        pool_error( command => [ $^X, $path ], stderr => "$path.err", timeout => 2 );
    };
    is $error, undef, 'the pool ends the test at its time limit';
    my $grandchild = text_of("$path.grandchild");
    ok kill( 0, $grandchild ), 'a process outside the group stays, because the listing is not trusted';
    kill 'KILL', $grandchild;
};

done_testing;
