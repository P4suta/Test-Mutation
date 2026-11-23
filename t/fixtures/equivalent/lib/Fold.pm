package Fold;
use strict;
use warnings;
use Digest::SHA ();

sub size { return 10 > 5 ? 'big' : 'small' }

sub label {
    my ($count) = @_;
    return 'none' if !$count;
    return 'some';
}

1;
