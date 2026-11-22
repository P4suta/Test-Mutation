package Startup;
use strict;
use warnings;

BEGIN {
    die "arithmetic is broken\n" if 2 + 2 != 4;
}

my $limit = 10;
die "the limit is negative\n" if $limit < 0;

sub limit { return $limit }

1;
