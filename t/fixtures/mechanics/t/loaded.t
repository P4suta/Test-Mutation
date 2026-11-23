use strict;
use warnings;
use Test::More tests => 2;

# A test that goes on after a failed load is stopped at its first failure, before its END blocks run.
use_ok('Loaded') or select undef, undef, undef, 2;
is eval { Loaded::value() }, 7, 'the value';
