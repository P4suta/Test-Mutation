use v5.36;
use Test2::V0;
use Cwd ();
use lib 't/e2e/lib';
use Fixture qw(copy_of run_fixture write_file);

my $library = Cwd::abs_path('lib');

sub run_test ( $root, $file ) {
    my $output = qx{cd '$root' && '$^X' '-I$library' '$file' 2>&1};
    return ( $? >> 8, $output );
}

my $root = copy_of('calc');

subtest 'the assertion passes when the score reaches the minimum' => sub {
    write_file( "$root/xt/mutation.t",
        "use Test::More tests => 1;\nuse Test::Mutation;\nprint q{# returned }, mutation_score_ok( min => 60, jobs => 2 ), qq{\\n};\n"
    );
    my ( $status, $output ) = run_test( $root, 'xt/mutation.t' );
    is $status, 0, 'the test passes' or diag $output;
    like $output, qr/^ok 1 - the mutation score is at least 60%$/m, 'the default name states the minimum';
    like $output, qr/^# returned 1$/m,                              'the assertion returns true';

    write_file( "$root/xt/exact.t",
        "use Test::More tests => 1;\nuse Test::Mutation;\nmutation_score_ok( min => 15 / 21 * 100, jobs => 2, name => q{exact} );\n"
    );
    ( $status, $output ) = run_test( $root, 'xt/exact.t' );
    is $status, 0, 'a score equal to the minimum passes' or diag $output;
};

subtest 'the assertion fails below the minimum and shows the undetected mutants' => sub {
    write_file( "$root/xt/strict.t",
        "use Test::More tests => 1;\nuse Test::Mutation;\nprint q{# returned }, mutation_score_ok( min => 90, jobs => 2, name => 'strong tests' ), qq{\\n};\n"
    );
    my ( $status, $output ) = run_test( $root, 'xt/strict.t' );
    isnt $status, 0, 'the test fails';
    like $output, qr/^not ok 1 - strong tests$/m,                    'the given name';
    like $output, qr/^# returned 0$/m,                               'the assertion returns false';
    like $output, qr/^# Score: 71\.4% \(15 of 21 valid mutants\)$/m, 'the diagnostics state the score';
    like $output, qr/^#   lib\/Calc\.pm:12:15  replaced > with >=/m, 'and list a survived mutant';
};

subtest 'settings pass through to the run' => sub {
    write_file( "$root/xt/narrow.t",
        "use Test::More tests => 1;\nuse Test::Mutation;\nmutation_score_ok( min => 100, jobs => 2, disable => [ 'comparison', 'sub-body', 'return-value' ], source => ['lib/Calc.pm'], coverage => 'file' );\n"
    );
    my ( $status, $output ) = run_test( $root, 'xt/narrow.t' );
    isnt $status, 0, 'the mutants without a detecting test still fail the assertion' or diag $output;
    like $output, qr/^# \d+ mutants: \d+ killed, \d+ survived$/m, 'file selection runs the tests for every mutant';
};

subtest 'the assertion reads mutation.toml, and a setting overrides the file' => sub {
    my $project = copy_of('calc');
    write_file( "$project/lib/Extra.pm",
        "package Extra;\nuse strict;\nuse warnings;\nsub twice { my (\$n) = \@_; return \$n * 2 + 1 - 1 }\n1;\n" );
    write_file( "$project/mutation.toml", "source-exclude = [\"lib/Extra.pm\"]\n" );
    write_file( "$project/xt/file.t",
        "use Test::More tests => 1;\nuse Test::Mutation;\nmutation_score_ok( min => 60, jobs => 2 );\n" );
    write_file( "$project/xt/override.t",
        "use Test::More tests => 1;\nuse Test::Mutation;\nmutation_score_ok( min => 60, jobs => 2, source_exclude => [] );\n"
    );
    my ( $status, $output ) = run_test( $project, 'xt/file.t' );
    is $status, 0, 'the excluded file leaves the score above the minimum' or diag $output;
    ( $status, $output ) = run_test( $project, 'xt/override.t' );
    isnt $status, 0, 'the setting brings the untested file back';
    like $output, qr/^#   lib\/Extra\.pm:/m, 'and the diagnostics list its mutants';

    write_file( "$project/mutation.toml", "[source\n" );
    ( $status, $output ) = run_test( $project, 'xt/file.t' );
    isnt $status, 0, 'a malformed file fails the test';
    like $output, qr/mutation[.]toml/, 'and the error names the file';
};

subtest 'the assertion is skipped inside a mutation run of the same project' => sub {
    {
        local $ENV{TEST_MUTATION_ROOT} = $root;
        my ( $status, $output ) = run_test( $root, 'xt/strict.t' );
        is $status, 0, 'the test passes';
        like $output, qr/^ok 1 # skip inside a mutation run$/m, 'with a skip that states the reason';
        like $output, qr/^# returned 1$/m,                      'and the assertion returns true';
    }
    {
        local $ENV{TEST_MUTATION_ROOT} = "$root/lib";
        my ( $status, $output ) = run_test( $root, 'xt/strict.t' );
        isnt $status, 0, 'a run of another project leaves the assertion active';
    }

    my $project = copy_of('calc');
    write_file( "$project/t/score.t",
        "use Test::More tests => 1;\nuse Test::Mutation;\nmutation_score_ok( min => 100, jobs => 2 );\n" );
    my ($result) = run_fixture( $project, switch => [ '-Ilib', "-I$library" ] );
    is $result->baseline_failures,       [], 'a copy among the tests of a run passes as a skip';
    is $result->tally->{counts}{Killed}, 15, 'and the run measures the project';
};

done_testing;
