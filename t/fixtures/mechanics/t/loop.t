use strict;
use warnings;
use Test::More tests => 2;
use Loop;

is Loop::countdown(3), 3, 'counts three steps';
is Loop::countdown(0), 0, 'counts no step';
