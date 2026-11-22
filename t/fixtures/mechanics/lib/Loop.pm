package Loop;
use strict;
use warnings;

sub countdown {
    my ($n) = @_;
    my $steps = 0;
    while ( $n > 0 ) {
        $n--;
        $steps++;
    }
    return $steps;
}

1;
