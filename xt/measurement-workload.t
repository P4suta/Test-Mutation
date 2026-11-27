use v5.36;
use Test2::V0;
use lib 't/lib', 'xt/lib';
use Gate;
use MeasurementBenchmark;

my $limit   = 128 * 1024 * 1024;
my @samples = map { { seconds => $_, bytes => $limit } } ( 2, 1, 0.2, 1.5, 0.3 );
is MeasurementBenchmark::lookup( \@samples ), { median => 1, peak => $limit, passed => 1 },
  'a median of one second and a peak of 128 MiB meet both limits';

subtest 'the lookup budget rejects slow or memory-intensive measurements' => sub {
    local $samples[1]{seconds} = 1.01;
    ok !MeasurementBenchmark::lookup( \@samples )->{passed}, 'three slow lookups exceed the time budget';
    local $samples[1]{seconds} = 0.5;
    local $samples[2]{bytes}   = $limit + 1;
    ok !MeasurementBenchmark::lookup( \@samples )->{passed}, 'one peak exceeds the memory budget';
    like dies { MeasurementBenchmark::lookup( [ @samples[ 0 .. 3 ] ] ) }, qr/five lookups/,
      'fewer trials cannot establish the median';
};

Gate::checked( 'lookup trials', scalar @samples, at_least => 5 );
done_testing;
