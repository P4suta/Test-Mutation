package Calc;
use strict;
use warnings;

sub add {
    my ( $x, $y ) = @_;
    return $x + $y;
}

sub is_positive {
    my ($n) = @_;
    return $n > 0 ? 1 : 0;
}

sub untested {
    my ($n) = @_;
    return $n * 2;
}

sub describe {
    my ($n) = @_;
    my $label = 'zero';
    if ( $n < 0 ) {
        $label = 'negative';
    }
    elsif ( $n > 0 ) {
        $label = 'positive';
    }
    return $label;
}

1;
