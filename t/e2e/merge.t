use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Fixture qw(copy_of run_fixture statuses);

my $root    = copy_of('calc');
my ($whole) = run_fixture($root);
my @parts   = map { ( run_fixture( $root, shard => "$_/2" ) )[0] } 1, 2;

subtest 'a result names its part and the mutants of the whole run' => sub {
    is $whole->shard,                undef,                         'a whole run has no part';
    is [ map { $_->shard } @parts ], [ '1/2', '2/2' ],              'a part names itself';
    is $whole->inventory->{mutants}, scalar( $whole->entries->@* ), 'the inventory counts every mutant';
    like $whole->inventory->{digest}, qr/\A[0-9a-f]{64}\z/, 'the inventory has a digest';
    is [ map { $_->inventory } @parts ], [ ( $whole->inventory ) x 2 ],
      'each part carries the inventory of the whole run';
};

done_testing;
