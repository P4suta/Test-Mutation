package Corpus::Heredoc;
use v5.36;

sub banner ($name) {
    my $text = <<~EOT;
        Hello, $name
          1 + 1 == 2
        EOT
    return $text . ( 1 + 1 );
}

sub pair {
    my @both = ( <<'FIRST', <<"SECOND" );
first - literal
FIRST
second + interpolated
SECOND
    return scalar(@both) - 1;
}

sub after {
    my $raw = <<'RAW';
if ($x == 1) { $y++ }
RAW
    my $n = length($raw) + 1;
    return $n;
}

1;
