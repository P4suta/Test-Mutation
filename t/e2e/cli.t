use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Fixture qw(copy_of permutl write_file);

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

subtest 'a score below --min-score fails the run' => sub {
    my $root = copy_of('calc');
    is permutl( $root, '--jobs', 2, '--min-score', 90 )->{exit}, 1, 'the score is below 90';
    is permutl( $root, '--jobs', 2, '--min-score', 60 )->{exit}, 0, 'the score is above 60';
};

subtest 'a test that fails without any mutant stops the run' => sub {
    my $root = copy_of('calc');
    write_file( "$root/t/broken.t", "use Test::More tests => 1;\nis 1, 2, 'never equal';\n" );
    my $run = permutl( $root, '--jobs', 2 );
    is $run->{exit}, 3, 'exit status';
    like $run->{stdout},   qr/^The unmodified run fails, so no mutant ran\.$/m, 'the reason';
    like $run->{stdout},   qr/^  t\/broken\.t$/m,                               'the failing test';
    like $run->{stdout},   qr/^    not ok 1 - never equal$/m,                   'its output';
    unlike $run->{stdout}, qr/^Score:/m,                                        'no score';
};

subtest 'a usage error exits with status 2 and one line' => sub {
    my $root    = copy_of('calc');
    my $unknown = permutl( $root, '--no-such-option' );
    is $unknown->{exit}, 2, 'an unknown option';
    like $unknown->{stderr}, qr/Unknown option: no-such-option/, 'the option is named';

    my $invalid = permutl( $root, '--jobs', 0 );
    is $invalid->{exit}, 2, 'a value outside its type';
    like $invalid->{stderr}, qr/\Apermutl: [^\n]*jobs[^\n]*\n\z/, 'one line that names the setting';
    is $invalid->{stdout}, q{}, 'no report';
};

done_testing;
