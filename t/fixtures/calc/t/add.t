use strict;
use warnings;
use Test::More tests => 2;
use Calc;

is Calc::add( 2, 3 ), 5, 'adds';
is Calc::add( 2, 0 ), 2, 'adds zero';
