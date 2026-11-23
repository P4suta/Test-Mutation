use v5.38;
use Test::More tests => 3;
use Counter;

is( Counter->new->bump->bump(2)->count, 3,  'bumps add up' );
is( Counter->new( count => 4 )->count,  4,  'a start value' );
is( Counter->new->size,                 'big', 'a size' );
