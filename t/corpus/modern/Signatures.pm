package Corpus::Signatures;
use v5.36;

sub add ($x, $y = 1 + 2) {
    return $x + $y;
}

sub clamp ($value, $low, $high) {
    return $low  if $value < $low;
    return $high if $value > $high;
    return $value;
}

my $double = sub ($n) { $n * 2 };

sub total (@numbers) {
    my $sum = 0;
    $sum += $_ for @numbers;
    return $sum;
}

1;
