use v5.36;
use Test2::V0;
use Time::HiRes ();
use lib 't/lib';
use Bounded;
use Gate;

# A harness that walks a corpus must end, whatever one input does.
# The bound turns a loop without an end into a result that the harness counts.

my $runs = 0;

sub bounded ( $seconds, $code ) {
    $runs++;
    return [ Bounded::ended( $seconds, $code ) ];
}

subtest 'code that ends gives its values' => sub {
    is bounded( 5, sub { return ( 2, 3 ) } ), [ 1, 2, 3 ], 'the values follow the answer';
    is bounded( 5, sub { return } ),          [1],         'no value is an end all the same';
    is bounded( 5, sub { return 0 } ),        [ 1, 0 ],    'a false value is an end all the same';
};

subtest 'the bound rejects code that never ends' => sub {
    my $started = Time::HiRes::time();
    is bounded( 0.2, sub { 1 while 1 } ), [0], 'the loop is stopped';
    my $spent = Time::HiRes::time() - $started;
    ok $spent >= 0.2 && $spent < 5, 'after the limit, and soon';
    is bounded( 5, sub { return 'next' } ), [ 1, 'next' ], 'the next run starts with a fresh limit';

    my $catches = sub {
        my $done = eval { 1 while 1; 1 };
        die $@ if !$done && Bounded::stopped($@);
        return 'caught';
    };
    is bounded( 0.2, $catches ), [0], 'code that catches its own errors passes the stop on';
    ok !Bounded::stopped("broken input\n"), 'and no other error reads as the stop';
};

subtest 'a death passes through the bound' => sub {
    like dies {
        bounded( 5, sub { die "broken input\n" } )
    }, qr/\Abroken input\n\z/, 'the caller reads the reason';
    my $rang = 0;
    local $SIG{ALRM} = sub { $rang = 1 };
    eval {
        bounded( 0.3, sub { die "early\n" } );
        1;
    } or Time::HiRes::sleep(0.5);
    is $rang, 0, 'and no alarm is left behind';
};

Gate::checked( 'bounded runs', $runs, at_least => 7 );

done_testing;
