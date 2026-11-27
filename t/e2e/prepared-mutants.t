use v5.36;
use Test2::V0;
use List::Util   qw(max);
use Scalar::Util qw(weaken);
use lib 't/e2e/lib';
use Fixture qw(copy_of run_fixture);
use Test::Mutation::Verdict;

Test::Mutation::Verdict::start();
my $start = Test::Mutation::Verdict->can('start');
for my $jobs ( 1, 2 ) {
    my $root = copy_of('calc');
    for my $pass (qw(cold warm)) {
        my ( @states, $peak );
        no warnings 'redefine';
        local *Test::Mutation::Verdict::start = sub {
            my $state = $start->();
            push @states, $state;
            weaken $states[-1];
            $peak = max( $peak || 0, scalar grep { defined } @states );
            return $state;
        };
        my ($result) = run_fixture( $root, jobs => $jobs, equivalence => 0 );
        cmp_ok scalar $result->entries->@*, '>',  2 * $jobs, 'the fixture outgrows the queue';
        cmp_ok $peak,                       '>=', 1,         'the measurement allocated verdict states';
        cmp_ok $peak, '<=', 2 * $jobs, "$pass measurement peaks at $peak prepared states with $jobs jobs";
        cmp_ok $result->stats->{verifications}, '>', 0, 'the bound includes cache verification' if $pass eq 'warm';
    }
}

done_testing;
