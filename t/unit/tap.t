use v5.36;
use Test2::V0;
use Test::Mutation::Tap;

sub fold (@lines) {
    my $state = Test::Mutation::Tap::start();
    $state = Test::Mutation::Tap::feed( $state, $_ ) for @lines;
    return $state;
}

my @cases = (
    [ 'all tests pass',                  [ '1..2', 'ok 1', 'ok 2 - named' ],                                 0, 1, 0 ],
    [ 'plan at the end',                 [ 'ok 1', 'ok 2', '1..2' ],                                         0, 1, 0 ],
    [ 'a failure',                       [ '1..2', 'ok 1', 'not ok 2 - broken' ],                            1, 0, 1 ],
    [ 'a TODO failure does not fail',    [ '1..1', 'not ok 1 - later # TODO unfinished' ],                   0, 1, 0 ],
    [ 'a lowercase todo directive',      [ '1..1', 'not ok 1 # todo unfinished' ],                           0, 1, 0 ],
    [ 'an escaped hash is not a TODO',   [ '1..1', 'not ok 1 - name \\# TODO' ],                             1, 0, 1 ],
    [ 'a skipped test passes',           [ '1..1', 'ok 1 # SKIP no network' ],                               0, 1, 0 ],
    [ 'a skipped file passes',           ['1..0 # SKIP not supported'],                                      0, 1, 0 ],
    [ 'a bail-out',                      [ '1..3', 'ok 1', 'Bail out! disk full' ],                          0, 0, 1 ],
    [ 'a missing plan',                  [ 'ok 1', 'ok 2' ],                                                 0, 0, 0 ],
    [ 'fewer tests than planned',        [ '1..3', 'ok 1' ],                                                 0, 0, 0 ],
    [ 'more tests than planned',         [ '1..1', 'ok 1', 'ok 2' ],                                         0, 0, 0 ],
    [ 'a nonzero exit status',           [ '1..1', 'ok 1' ],                                                 2, 0, 0 ],
    [ 'a failure inside a subtest only', [ '    not ok 1 - inner', '    1..1', 'ok 1 - outer', '1..1' ],     0, 1, 0 ],
    [ 'a failed subtest',                [ '    not ok 1 - inner', '    1..1', 'not ok 1 - outer', '1..1' ], 1, 0, 1 ],
    [ 'diagnostics are ignored',         [ '# not ok', 'TAP version 13', '1..1', 'ok 1', 'okay then' ],      0, 1, 0 ],
    [ 'no output',                       [],                                                                 0, 0, 0 ],
);

for my $case (@cases) {
    my ( $name, $lines, $exit, $passed, $early ) = $case->@*;
    my $state = fold( $lines->@* );
    is Test::Mutation::Tap::passed( $state, $exit ), $passed, "$name: passed";
    is Test::Mutation::Tap::failed_already($state),  $early,  "$name: failed already";
}

subtest 'an early failure never becomes a pass' => sub {
    my @lines  = ( '1..3', 'ok 1', 'not ok 2', 'ok 3', 'not ok 4 # TODO x', 'Bail out!', '1..5', 'ok' );
    my @broken = ();
    for my $first ( 0 .. $#lines ) {
        for my $second ( 0 .. $#lines ) {
            for my $third ( 0 .. $#lines ) {
                my @stream = @lines[ $first, $second, $third ];
                my $state  = Test::Mutation::Tap::start();
                my $early  = 0;
                for my $line (@stream) {
                    $state = Test::Mutation::Tap::feed( $state, $line );
                    $early ||= Test::Mutation::Tap::failed_already($state);
                }
                push @broken, "@stream" if $early && Test::Mutation::Tap::passed( $state, 0 );
            }
        }
    }
    is \@broken, [], 'every stream that fails early fails at the end';
};

subtest 'arguments are checked' => sub {
    my $state = Test::Mutation::Tap::start();
    like dies { Test::Mutation::Tap::start('extra') }, qr/Wrong number of parameters/, 'start takes no argument';
    like dies { Test::Mutation::Tap::feed( { planned => 1 }, 'ok 1' ) }, qr/did not pass type constraint/,
      'feed needs a whole state';
    like dies { Test::Mutation::Tap::failed_already('state') }, qr/did not pass type constraint/,
      'failed_already needs a state';
    like dies { Test::Mutation::Tap::passed( $state, 'zero' ) }, qr/did not pass type constraint/,
      'passed needs a numeric status';
    is Test::Mutation::Tap::feed( $state, '1..12' )->{planned}, 12, 'the plan is a number';
};

subtest 'feed returns a new state' => sub {
    my $before = Test::Mutation::Tap::start();
    my $after  = Test::Mutation::Tap::feed( $before, 'not ok 1' );
    is $before->{failed}, 0, 'the earlier state is unchanged';
    is $after->{failed},  1, 'the later state has the failure';
};

done_testing;
