package MeasurementBenchmark;
use v5.36;
use List::Util qw(max);

sub lookup ($samples) {
    die "the workload requires five lookups\n" unless @$samples == 5;
    my @seconds = sort    { $a <=> $b } map { $_->{seconds} } @$samples;
    my $peak    = max map { $_->{bytes} } @$samples;
    return { median => $seconds[2], peak => $peak, passed => $seconds[2] <= 1 && $peak <= 128 * 1024 * 1024 ? 1 : 0 };
}

1;
