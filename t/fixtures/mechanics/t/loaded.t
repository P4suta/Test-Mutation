use strict;
use warnings;
use Test::More tests => 2;

use_ok('Loaded');
is eval { Loaded::value() }, 7, 'the value';
