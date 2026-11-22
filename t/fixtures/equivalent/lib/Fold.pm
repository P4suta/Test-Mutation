package Fold;
use strict;
use warnings;
use Digest::SHA ();

sub minute { return 60 + 0 }

sub label {
    my ($count) = @_;
    return 'none' if !$count;
    return 'some';
}

1;
