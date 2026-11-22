use v5.36;
use Test2::V0;
use Cwd ();
use lib 't/e2e/lib';
use Fixture qw(copy_of write_file);

my $library = Cwd::abs_path('lib');

sub run_test ( $root, $file ) {
    my $output = qx{cd '$root' && '$^X' '-I$library' '$file' 2>&1};
    return ( $? >> 8, $output );
}

my $root = copy_of('calc');

subtest 'the assertion passes when the score reaches the minimum' => sub {
    write_file( "$root/xt/mutation.t",
        "use Test::More tests => 1;\nuse Test::Permutl;\nmutation_score_ok( min => 60, jobs => 2 );\n" );
    my ( $status, $output ) = run_test( $root, 'xt/mutation.t' );
    is $status, 0, 'the test passes' or diag $output;
    like $output, qr/^ok 1 - the mutation score is at least 60%$/m, 'the default name states the minimum';
};

subtest 'the assertion fails below the minimum and shows the undetected mutants' => sub {
    write_file( "$root/xt/strict.t",
        "use Test::More tests => 1;\nuse Test::Permutl;\nmutation_score_ok( min => 90, jobs => 2, name => 'strong tests' );\n"
    );
    my ( $status, $output ) = run_test( $root, 'xt/strict.t' );
    isnt $status, 0, 'the test fails';
    like $output, qr/^not ok 1 - strong tests$/m,                    'the given name';
    like $output, qr/^# Score: 68\.4% \(13 of 19 valid mutants\)$/m, 'the diagnostics state the score';
    like $output, qr/^#   lib\/Calc\.pm:12:15  replaced > with >=/m, 'and list a survived mutant';
};

subtest 'settings pass through to the run' => sub {
    write_file( "$root/xt/narrow.t",
        "use Test::More tests => 1;\nuse Test::Permutl;\nmutation_score_ok( min => 100, jobs => 2, disable => [ 'comparison', 'sub-body', 'return-value' ], source_include => ['lib/Calc.pm'], coverage => 'file' );\n"
    );
    my ( $status, $output ) = run_test( $root, 'xt/narrow.t' );
    isnt $status, 0, 'the mutants without a detecting test still fail the assertion' or diag $output;
    like $output, qr/^# \d+ mutants: \d+ killed, \d+ survived$/m, 'file selection runs the tests for every mutant';
};

done_testing;
