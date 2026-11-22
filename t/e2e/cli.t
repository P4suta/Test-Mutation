use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Fixture qw(copy_of permutl);

subtest 'run prints the summary and succeeds' => sub {
    my $root = copy_of('calc');
    my $run  = permutl( $root, 'run', '--jobs', 2 );
    is $run->{exit}, 0, 'exit status' or diag $run->{stderr};
    like $run->{stdout}, qr/^19 mutants: 13 killed, 3 survived, 3 no coverage$/m,            'the counts';
    like $run->{stdout}, qr/^Score: 68\.4% \(13 of 19 valid mutants\)$/m,                    'the score';
    like $run->{stdout}, qr/^  lib\/Calc\.pm:12:15  replaced > with >=  \[[0-9a-f]{12}\]$/m, 'a survived mutant';
    like $run->{stderr}, qr/^19 mutants in 1 file, 2 tests$/m, 'the analysis is announced on standard error';
};

subtest 'run is the default command' => sub {
    my $run = permutl( copy_of('calc'), '--jobs', 2 );
    is $run->{exit}, 0, 'exit status' or diag $run->{stderr};
    like $run->{stdout}, qr/^Score: 68\.4%/m, 'the score';
};

done_testing;
