use v5.36;
use Test2::V0;

# The arithmetic mutator yields no mutant for zero added or subtracted, or for one as a factor, a divisor, or an exponent.
# That rule is sound when the operator and its replacement give the same value for every operand.

no warnings qw(numeric uninitialized);

my $infinity      = 9**9**9;
my $not_a_number  = -$infinity / $infinity;
my $negative_zero = -0.0;
my @values        = (
    0,       1, -1, 7, 9_007_199_254_740_993, -9_007_199_254_740_993, 1.5, -2.25, 1e308, 1e-308, $infinity, -$infinity,
    '12abc', 'abc', q{}, undef, '0 but true', '0E0', '1e3', 18_446_744_073_709_551_615, ' 42 ', '0x10', $not_a_number,
);

sub shown ($value) {
    return sprintf '%s|%.17g', $value, $value;
}

for my $value ( @values, $negative_zero ) {
    my $name = defined $value ? "'$value'" : 'undef';
    is shown( $value + 0 ), shown( $value - 0 ), "$name plus zero equals $name minus zero";
    is shown( $value**1 ),  shown( $value * 1 ), "$name to the power of one equals $name times one";
}

for my $value (@values) {
    my $name = defined $value ? "'$value'" : 'undef';
    is shown( $value * 1 ), shown( $value / 1 ), "$name times one equals $name over one";
}

is [ sprintf( '%g', $negative_zero * 1 ), sprintf( '%g', $negative_zero / 1 ) ], [ '0', '-0' ],
  'negative zero is the one operand that tells a factor of one from a divisor of one';

done_testing;
