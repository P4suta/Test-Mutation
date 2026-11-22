use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Fixture qw(copy_of run_fixture);

# Selecting tests by line saves work, and it must never change which mutants the tests detect.

sub by_status ( $result, $status ) {
    return [ sort map { $_->{mutant}->id } grep { $_->{status} eq $status } $result->entries->@* ];
}

sub tests_run ($result) {
    my $total = 0;
    $total += $_->{tests_run} for $result->entries->@*;
    return $total;
}

for my $fixture (qw(calc mechanics)) {
    subtest $fixture => sub {
        my $root = copy_of($fixture);
        my %result;
        for my $mode (qw(line file)) {
            ( $result{$mode} ) = run_fixture( $root, coverage => $mode, timeout_floor => 1, timeout_factor => 2 );
            is $result{$mode}->baseline_failures, [], "$mode: the unmodified run passes";
        }
        for my $status (qw(Killed Timeout CompileError)) {
            is by_status( $result{line}, $status ), by_status( $result{file}, $status ), "the same mutants are $status";
        }
        my %undetected_by_file = map { $_ => 1 } by_status( $result{file}, 'Survived' )->@*,
          by_status( $result{file}, 'NoCoverage' )->@*;
        my @extra = grep { !$undetected_by_file{$_} } by_status( $result{line}, 'Survived' )->@*,
          by_status( $result{line}, 'NoCoverage' )->@*;
        is \@extra, [], 'every mutant that line selection leaves undetected is undetected by file selection';
        ok tests_run( $result{line} ) <= tests_run( $result{file} ), 'line selection runs no more tests';
    };
}

done_testing;
