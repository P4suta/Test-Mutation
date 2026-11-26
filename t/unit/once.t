use v5.36;
use Test2::V0;
use Test::Mutation::Once;

my @pending = ( [ first => 'source' ], [ waiting => 'source' ], [ other => undef ] );
my @observed;
my $calls = Test::Mutation::Once::coalesce(
    sub { return shift @pending },
    sub ( $task, $result ) {
        push @observed, [ $task->[0], $result ];
        return [ follow => 'source' ] if $task->[0] eq 'other';
        return;
    },
    sub ($task) { return $task->[1] },
);
my $first = $calls->{next}->();
my $other = $calls->{next}->();
is [ $first->[0], $other->[0] ], [qw(first other)], 'the different request can proceed while its peer waits';
$calls->{done}->( $first, 23 );
$calls->{done}->( $other, 42 );
push @pending, [ later => 'source' ];
is scalar $calls->{next}->(), undef, 'all remaining requests use the observed result';
is \@observed, [ [ first => 23 ], [ waiting => 23 ], [ other => 42 ], [ follow => 23 ], [ later => 23 ] ],
  'every task receives its own callback and the result of its key';
subtest 'false-valued keys and results are shared and unkeyed tasks remain independent' => sub {
    for my $key ( q{}, '0' ) {
        my @requests = ( [ 'initial', $key ], [ 'peer', $key ], [ 'other', undef ] );
        my @delivered;
        my $callbacks = Test::Mutation::Once::coalesce(
            sub { return shift @requests },
            sub ( $task, $result ) { push @delivered, [ $task->[0], $result ]; return },
            sub ($task) { return $task->[1] }
        );
        my $initial  = $callbacks->{next}->();
        my $uncached = $callbacks->{next}->();
        is [ $initial->[0], $uncached->[0] ], [qw(initial other)],
          'the keyed peer waits while an unrelated task can start';
        $callbacks->{done}->( $initial,  undef );
        $callbacks->{done}->( $uncached, 0 );
        push @requests, [ 'later', $key ], [ 'independent', undef ];
        my $fresh = $callbacks->{next}->();
        is $fresh->[0], 'independent', 'the completed false-valued key serves a later request';
        $callbacks->{done}->( $fresh, 1 );
        is \@delivered,
          [ [ 'initial', undef ], [ 'peer', undef ], [ 'other', 0 ], [ 'later', undef ], [ 'independent', 1 ] ],
          'every caller receives the original result for its request';
    }
    like dies {
        Test::Mutation::Once::coalesce( sub { return }, sub { return }, 'missing' )
    }, qr/type constraint "CodeRef"/, 'a missing key callback fails when the pool is constructed';
};

done_testing;
