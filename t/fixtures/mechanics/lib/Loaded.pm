package Loaded;
use strict;
use warnings;

BEGIN {
    die "arithmetic is broken\n" if 3 - 1 != 2;
}

sub value { return 7 }

1;
