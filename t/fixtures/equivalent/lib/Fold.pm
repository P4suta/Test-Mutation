package Fold;
use strict;
use warnings;

sub minute { return 60 + 0 }

sub label {
    my ($count) = @_;
    return 'none' if !$count;
    return 'some';
}

1;
