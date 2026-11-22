use strict;
use warnings;
use lib 't/lib';
use lib 'lib';
use Test::More tests => 1;
use Shelf;

is Shelf::next_slot(4), 5, 'the next slot';
