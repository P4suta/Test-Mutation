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

subtest 'the small workload exercises the same four measurements and five lookups' => sub {
    open my $results, q{-|}, $^X, 'xt/bin/benchmark-measurement', '--smoke' or die "start the workload: $!";
    my $text = join q{}, readline $results;
    ok close($results), 'the workload completed' or diag $text;
    like $text, qr/^workload\tmutants\tseconds\tpeak_MiB\ttests_started$/m, 'the units accompany the readings';
    for my $state (qw(cold warm source-change test-change)) {
        like $text, qr/^$state\t12\t\d+\.\d+\t[1-9]\d*\.\d+\t\d+$/m, "$state measured twelve mutants";
    }
    is scalar( () = $text =~ /^show-\d\t1\t\d+\.\d+\t[1-9]\d*\.\d+\t0$/mg ), 5, 'five single-mutant lookups ran';
    like $text, qr/^show median \d+\.\d+ s, peak \d+\.\d+ MiB$/m, 'the aggregate uses the five actual readings';
};

Gate::checked( 'lookup trials', scalar @samples, at_least => 5 );
done_testing;
