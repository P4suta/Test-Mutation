use v5.36;
use Test2::V0;
use IO::Select  ();
use Time::HiRes ();
use Test::Mutation::Clock;

my $clock = Test::Mutation::Clock->new;

subtest 'the time moves forward with the time of the machine' => sub {
    my $before = $clock->now;
    Time::HiRes::sleep(0.1);
    my $after = $clock->now;
    ok $after - $before >= 0.09, 'a tenth of a second passes on the clock';
    ok $after - $before < 30,    'and no more than a wait can explain';
};

subtest 'a wait ends at the first readable handle or at the end of its seconds' => sub {
    pipe my $read, my $write or die "pipe: $!";
    my $select = IO::Select->new($read);

    my $started = $clock->now;
    is $clock->wait_for( $select, 0.2 ), [], 'a silent pipe gives nothing';
    ok $clock->now - $started >= 0.15, 'after the seconds of the wait';

    syswrite $write, 'x' or die "write: $!";
    $started = $clock->now;
    is $clock->wait_for( $select, 30 ), [$read], 'a pipe with a byte is readable';
    ok $clock->now - $started < 10, 'at once';
};

subtest 'a wait refuses a negative number of seconds' => sub {
    like dies { $clock->wait_for( IO::Select->new, -1 ) }, qr/greater than or equal to zero/, 'refused';
};

done_testing;
