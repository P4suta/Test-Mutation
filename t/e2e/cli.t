use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Cwd        ();
use File::Temp ();
use JSON::PP   ();
use Fixture    qw(copy_of permutl permutl_from write_file);

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

subtest 'run reports its progress on standard error' => sub {
    my $run = permutl( copy_of('calc'), '--jobs', 2, '--format', 'terminal' );
    like $run->{stderr},   qr/^The unmodified run passed: 2 tests, 2 jobs$/m,      'the unmodified run';
    like $run->{stderr},   qr/^\[19\/19\] 13 killed, 3 survived, 3 no coverage$/m, 'the last progress line';
    unlike $run->{stderr}, qr/\r/,                                                 'no carriage return in a log';
    unlike $run->{stderr}, qr/^permutl:/m,                                         'a complete run reports no problem';
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

subtest 'a score that equals --min-score passes' => sub {
    my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$root/lib/Half.pm",
        "package Half;\nuse strict;\nuse warnings;\nsub tested { return \$_[0] + 1 }\nsub untested { return \$_[0] + 1 }\n1;\n"
    );
    write_file( "$root/t/half.t", "use Test::More tests => 1;\nuse Half;\nis Half::tested(2), 3, 'the next one';\n" );
    my $run = permutl( $root, '--jobs', 2, '--format', 'terminal', '--min-score', 50 );
    like $run->{stdout}, qr/^Score: 50\.0% \(3 of 6 valid mutants\)$/m, 'half of the mutants are detected';
    is $run->{exit}, 0, 'a minimum of 50 is met';
    is permutl( $root, '--jobs', 2, '--format', 'terminal', '--min-score', 50.5 )->{exit}, 1,
      'a minimum of 50.5 is not';
};

subtest 'a run that cannot judge a mutant exits with status 4 and no error line' => sub {
    my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$root/lib/Slow.pm",
        "package Slow;\nuse strict;\nuse warnings;\nsub next_one { return \$_[0] + 1 }\n1;\n" );
    write_file( "$root/t/slow.t",
            "use Test::More tests => 1;\nBEGIN { select undef, undef, undef, 0.6 }\n"
          . "use Slow;\nis Slow::next_one(2), 3, 'the next one';\n" );
    my $run = permutl( $root, '--jobs', 2, '--format', 'terminal', '--timeout-factor', 0.1, '--timeout-floor', 0.1 );
    is $run->{exit}, 4, 'exit status';
    like $run->{stdout},   qr/^3 mutants: 3 runtime error$/m, 'every test ran out of time before it loaded a mutant';
    unlike $run->{stderr}, qr/^permutl:/m,                    'the report is the whole explanation';
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

    my $spaced = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) ) . '/with a space';
    mkdir $spaced or die "mkdir: $!";
    symlink Cwd::abs_path('lib'), "$spaced/lib" or die "symlink: $!";
    my $installed = permutl_from( "$spaced/lib", $root, '--jobs', 0 );
    is $installed->{stderr}, $invalid->{stderr}, 'a library under a directory with a space gives the same line';
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

    my $elsewhere = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $project   = copy_of('calc');
    my $named     = permutl( $project, '--jobs', 2, '--format', 'json', '--report-dir', "$elsewhere/out" );
    is $named->{exit}, 0, 'a directory named in full is accepted' or diag $named->{stderr};
    ok -f "$elsewhere/out/mutation.json", 'the report is in that directory';
    is $named->{stdout}, "Reports: $elsewhere/out/mutation.json\n", 'and the output names it';
    is [ grep { !/\A(?:lib|t|[.]permutl)\z/ } map { s{.*/}{}r } glob "$project/* $project/.permutl" ], [],
      'the project gets no directory for it';
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

subtest 'options choose mutators, files, and selection' => sub {
    my $root   = copy_of('calc');
    my @common = ( '--jobs', 2, '--format', 'terminal' );
    like permutl( $root, @common, '--disable', 'sub-body', '--disable', 'return-value' )->{stdout}, qr/^11 mutants:/m,
      '--disable';
    like permutl( $root, @common, '--disable', 'arithmetic', '--enable', 'number-literal' )->{stdout},
      qr/^\d+ mutants:.*\n(?:.*\n)*.*replaced 0 with 1/m, '--enable adds an extended mutator';
    my ($extended) = permutl( $root, @common, '--profile', 'extended' )->{stdout} =~ /^(\d+) mutants:/m;
    ok $extended > 19, "--profile extended yields more mutants ($extended)";
    like permutl( $root, @common, '--coverage', 'file' )->{stdout}, qr/^19 mutants: 13 killed, 6 survived$/m,
      '--coverage file runs every loading test';
    like permutl( $root, @common, '--test',   't/add.t' )->{stdout},         qr/^1 test, /m,   '--test';
    like permutl( $root, @common, '--source', 'lib/Nothing*.pm' )->{stdout}, qr/^0 mutants$/m, '--source';
};

subtest 'options choose the interpreter, the time limits, and the work directory' => sub {
    my $root   = copy_of('calc');
    my @common = ( '--jobs', 2, '--format', 'terminal' );
    is permutl( $root, @common, '--perl', $^X, '--timeout-factor', 3, '--timeout-floor', 5 )->{exit}, 0, 'valid values';
    is permutl( $root, @common, '--perl', "$root/no-such-perl" )->{exit}, 3,
      'an interpreter that cannot start fails the unmodified run';
    is permutl( $root, @common, '--timeout-factor', 0 )->{exit}, 2, 'a factor of zero is refused';

    ok !-e "$root/.permutl" || !glob("$root/.permutl/run-*"), 'the work directory is removed by default';
    permutl( $root, @common, '--keep-work' );
    ok scalar( glob "$root/.permutl/run-*" ), '--keep-work keeps it';
};

subtest '--mutant limits the run to the named mutants' => sub {
    my $root = copy_of('calc');
    my ($id) =
      permutl( $root, '--jobs', 2, '--format', 'terminal' )->{stdout} =~ /replaced > with >=  \[([0-9a-f]{12})\]/;
    my $run = permutl( $root, '--jobs', 2, '--format', 'terminal', '--mutant', $id );
    like $run->{stdout}, qr/^1 mutant: 1 survived$/m, 'one mutant ran';
};

subtest 'GitHub Actions gets annotations and a job summary' => sub {
    my $root   = copy_of('calc');
    my $format = permutl( $root, '--jobs', 2, '--format', 'github' );
    like $format->{stdout},
      qr/^::warning file=lib\/Calc\.pm,line=12,col=15,endLine=12,endColumn=16,title=Survived mutant::/m,
      '--format github prints annotations';
    unlike $format->{stdout}, qr/^Score:/m, 'and nothing else';

    local $ENV{GITHUB_ACTIONS}      = 'true';
    local $ENV{GITHUB_STEP_SUMMARY} = "$root/summary.md";
    my $detected = permutl( $root, '--jobs', 2 );
    like $detected->{stdout},       qr/^Score: 68\.4%/m,                 'the terminal report stays';
    like $detected->{stdout},       qr/^::warning file=lib\/Calc\.pm,/m, 'annotations are added inside GitHub Actions';
    like slurp("$root/summary.md"), qr/^Score: \*\*68\.4%\*\*/m,         'the job summary is appended';
    is $detected->{exit}, 0, 'the run succeeds' or diag $detected->{stderr};

    local $ENV{GITHUB_STEP_SUMMARY} = q{};
    my $unnamed = permutl( $root, '--jobs', 2 );
    is $unnamed->{exit}, 0, 'an empty name for the job summary is no error' or diag $unnamed->{stderr};
    like $unnamed->{stdout}, qr/^::warning file=lib\/Calc\.pm,/m, 'and the annotations stay';
};

done_testing;
