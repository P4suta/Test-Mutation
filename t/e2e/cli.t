use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use JSON::PP ();
use Fixture  qw(copy_of permutl write_file);

sub slurp ($path) {
    open my $handle, '<:raw', $path or die "read $path: $!";
    local $/ = undef;
    return scalar readline $handle;
}

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

subtest 'run writes the JSON and HTML reports' => sub {
    my $root = copy_of('calc');
    my $run  = permutl( $root, '--jobs', 2 );
    like $run->{stdout}, qr/^Reports: permutl-report\/mutation\.json, permutl-report\/mutation\.html$/m,
      'the report paths';

    my $document = JSON::PP->new->utf8->decode( slurp("$root/permutl-report/mutation.json") );
    is $document->{schemaVersion},                               '2', 'the JSON report has the schema version';
    is scalar( $document->{files}{'lib/Calc.pm'}{mutants}->@* ), 19,  'the JSON report has every mutant';
    like slurp("$root/permutl-report/mutation.html"), qr/<mutation-test-report-app\b/, 'the HTML report has the viewer';
};

subtest '--format and --report-dir choose the reports' => sub {
    my $root = copy_of('calc');
    my $run  = permutl( $root, '--jobs', 2, '--format', 'terminal', '--format', 'json', '--report-dir', 'out' );
    is $run->{exit}, 0, 'exit status' or diag $run->{stderr};
    ok -f "$root/out/mutation.json",  'the JSON report is in the named directory';
    ok !-e "$root/out/mutation.html", 'no HTML report';
    ok !-e "$root/permutl-report",    'the default directory is not created';
    like $run->{stdout}, qr/^Reports: out\/mutation\.json$/m, 'the report path';

    my $quiet = permutl( copy_of('calc'), '--jobs', 2, '--format', 'json' );
    unlike $quiet->{stdout}, qr/^Score:/m, 'no terminal report when the format is left out';
};

subtest 'permutl.toml configures the run' => sub {
    my $root = copy_of('calc');
    write_file( "$root/permutl.toml",
        "jobs = 2\n\n[mutators]\ndisable = [\"sub-body\", \"return-value\"]\n\n[report]\nformats = [\"terminal\"]\n" );
    my $run = permutl($root);
    is $run->{exit}, 0, 'exit status' or diag $run->{stderr};
    like $run->{stdout}, qr/^11 mutants: 7 killed, 3 survived, 1 no coverage$/m, 'the disabled mutators are left out';
    like $run->{stdout}, qr/^2 tests, 2 jobs,/m,                                 'jobs come from the file';
    ok !-e "$root/permutl-report", 'the formats come from the file';

    like permutl( $root, '--jobs', 1 )->{stdout}, qr/^2 tests, 1 job,/m, 'the command line beats the file';
};

subtest 'a broken configuration file is a usage error' => sub {
    my $root = copy_of('calc');
    write_file( "$root/permutl.toml", "[mutators]\nprofil = \"default\"\n" );
    my $unknown = permutl($root);
    is $unknown->{exit}, 2, 'an unknown key';
    like $unknown->{stderr}, qr/\Apermutl: unknown configuration key profil in \[mutators\]\n\z/, 'the key is named';

    write_file( "$root/permutl.toml", "jobs = = 2\n" );
    my $syntax = permutl($root);
    is $syntax->{exit}, 2, 'a syntax error';
    like $syntax->{stderr}, qr/\Apermutl: permutl\.toml: [^\n]+\n\z/, 'the file is named on one line';
};

subtest '--config names another configuration file' => sub {
    my $root = copy_of('calc');
    write_file( "$root/ci.toml", "[mutators]\ndisable = [\"sub-body\"]\n\n[report]\nformats = [\"terminal\"]\n" );
    like permutl( $root, '--jobs', 2, '--config', 'ci.toml' )->{stdout}, qr/^15 mutants:/m, 'the named file is read';
    my $missing = permutl( $root, '--config', 'absent.toml' );
    is $missing->{exit}, 2, 'a missing file named on the command line';
    like $missing->{stderr}, qr/\Apermutl: cannot read absent\.toml: /, 'the file is named';
};

done_testing;
