use v5.36;
use Test2::V0;
use lib 't/e2e/lib', 't/lib';
use Cwd        ();
use File::Temp ();
use JSON::PP   ();
use Fixture    qw(copy_of ran ran_from write_file);
use Gate;

sub slurp ($path) {
    open my $handle, '<:raw', $path or die "read $path: $!";
    local $/ = undef;
    return scalar readline $handle;
}

subtest 'a first run identifies a missing assertion and a new test detects the survivor' => sub {
    my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$root/lib/Total.pm", 'package Total; sub sum { return $_[0] + $_[1] } 1;' );
    my $zero = "use Test::More tests => 1;\nuse Total;\nis Total::sum(4, 0), 4, 'adding zero';\n";
    write_file( "$root/t/zero.t", $zero );
    my @options = ( '--jobs', 1, '--format', 'terminal', '--min-score', 100 );
    my $initial = ran( 1, $root, @options );
    my ($id)    = $initial->{stdout} =~ /^  ([0-9a-f]{12})  [^\n]+  replaced \+ with -  \[Survived\]$/m;
    ok $id, 'the report names the surviving arithmetic change';
    like ran( 0, $root, 'show', $id )->{stdout}, qr/return \$_\[0\] - \$_\[1\]/,
      'the patch shows the missing distinction';
    write_file( "$root/t/nonzero.t",
        "use Test::More tests => 1;\nuse Total;\nis Total::sum(4, 2), 6, 'adding a nonzero value';\n" );
    like ran( 0, $root, @options, '--mutant', $id )->{stdout}, qr/^1 mutant: 1 killed$/m,
      'the new test detects the same mutant on a fresh run';
    like ran( 0, $root, @options )->{stdout}, qr/^Score: 100[.]0%/m, 'the project meets its score threshold';
};

subtest 'run prints the summary and succeeds' => sub {
    my $root = copy_of('calc');
    my $run  = ran( 0, $root, 'run', '--jobs', 2 );
    like $run->{stdout}, qr/^21 mutants: 15 killed, 3 survived, 3 no coverage$/m, 'the counts';
    like $run->{stdout}, qr/^Score: 71\.4% \(15 of 21 valid mutants\)$/m,         'the score';
    like $run->{stdout},
      qr/^  [0-9a-f]{12}  lib\/Calc\.pm:12:15  comparison-boundary  replaced > with >=  \[Survived\]$/m,
      'a survived mutant';
    like $run->{stderr}, qr/^21 mutants in 1 file, 2 tests$/m, 'the analysis is announced on standard error';
};

subtest 'run reports its progress on standard error' => sub {
    my $run = ran( 0, copy_of('calc'), '--jobs', 2, '--format', 'terminal' );
    like $run->{stderr}, qr/^The unmodified run passed: 2 tests, 2 jobs$/m, 'the unmodified run';
    like $run->{stderr}, qr/^\[21\/21\] 15 killed, 3 survived, 3 no coverage [|] \d+s elapsed$/m,
      'the last progress line';
    unlike $run->{stderr}, qr/\r/,          'no carriage return in a log';
    unlike $run->{stderr}, qr/^mutation:/m, 'a complete run reports no problem';
};

subtest 'run is the default command' => sub {
    my $run = ran( 0, copy_of('calc'), '--jobs', 2 );
    like $run->{stdout}, qr/^Score: 71\.4%/m, 'the score';
};

subtest 'a score below --min-score fails the run' => sub {
    my $root = copy_of('calc');
    ran( 1, $root, '--jobs', 2, '--min-score', 90 );
    ran( 0, $root, '--jobs', 2, '--min-score', 60 );
};

subtest 'a score that equals --min-score passes' => sub {
    my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$root/lib/Half.pm",
        "package Half;\nuse strict;\nuse warnings;\nsub tested { return \$_[0] + 1 }\nsub untested { return \$_[0] + 1 }\n1;\n"
    );
    write_file( "$root/t/half.t", "use Test::More tests => 1;\nuse Half;\nis Half::tested(2), 3, 'the next one';\n" );
    my $run = ran( 0, $root, '--jobs', 2, '--format', 'terminal', '--min-score', 50 );
    like $run->{stdout}, qr/^Score: 50\.0% \(3 of 6 valid mutants\)$/m, 'half of the mutants are detected';
    ran( 1, $root, '--jobs', 2, '--format', 'terminal', '--min-score', 50.5 );
};

subtest 'a run that cannot judge a mutant exits with status 4 and one line that says so' => sub {
    my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$root/lib/Slow.pm",
        "package Slow;\nuse strict;\nuse warnings;\nsub next_one { return \$_[0] + 1 }\n1;\n" );
    write_file( "$root/t/slow.t",
            "use Test::More tests => 1;\n"
          . q{BEGIN { sleep 30 if $ENV{"TEST_MUTATION_SPEC_G$ENV{TEST_MUTATION_GENERATION}"} =~ m{/mutants/} }} . "\n"
          . "use Slow;\nis Slow::next_one(2), 3, 'the next one';\n" );
    my $run = ran( 4, $root, '--jobs', 2, '--format', 'terminal', '--timeout-factor', 4, '--timeout-floor', 1 );
    like $run->{stdout}, qr/^3 mutants: 3 no verdict$/m, 'every test ran out of time before it loaded a mutant';
    like $run->{stdout},
      qr{^lib/Slow[.]pm\n.*?  \[NoVerdict\]\n.*?^    t/slow[.]t exceeded its time limit before it loaded the mutant$}ms,
      'the file details identify the test that exceeded its limit before loading the mutant';
    like $run->{stderr}, qr/\nmutation: the run states no score\n\z/,
      'the last line of standard error names the outcome';
};

subtest 'a test that fails without any mutant stops the run' => sub {
    my $root = copy_of('calc');
    write_file( "$root/t/broken.t", "use Test::More tests => 1;\nis 1, 2, 'never equal';\n" );
    my $run = ran( 3, $root, '--jobs', 2 );
    like $run->{stdout},   qr/^The unmodified run fails, so no mutant ran\.$/m, 'the reason';
    like $run->{stdout},   qr/^  t\/broken\.t$/m,                               'the failing test';
    like $run->{stdout},   qr/^    not ok 1 - never equal$/m,                   'its output';
    unlike $run->{stdout}, qr/^Score:/m,                                        'no score';
};

subtest 'tests that need the repository data fail in a copy and pass in the project itself' => sub {
    my $root = copy_of('calc');
    write_file( "$root/.git/HEAD", "ref: refs/heads/main\n" );
    write_file( "$root/t/repository.t",
        "use Test::More tests => 1;\nok -e '.git', 'the repository data is at hand';\n" );
    my $run = ran( 3, $root, '--jobs', 2 );
    like $run->{stdout}, qr/^    not ok 1 - the repository data is at hand$/m, 'the output of the test';
    like $run->{stdout},
      qr/^The tests ran in a copy of the project, which holds no [.]git directory[.]\n--in-place runs them in the project itself[.]$/m,
      'the report names the other place for the tests';

    my $inside = ran( 0, $root, '--jobs', 2, '--in-place' );
    like $inside->{stdout}, qr/^21 mutants: 15 killed, 3 survived, 3 no coverage$/m, 'and the mutants are measured';
};

subtest 'a usage error exits with status 2 and one line' => sub {
    my $root    = copy_of('calc');
    my $unknown = ran( 2, $root, '--no-such-option' );
    like $unknown->{stderr}, qr/\Amutation: --no-such-option names no option; the nearest is --\S+\n\z/,
      'the option is named with the nearest one';

    my $invalid = ran( 2, $root, '--jobs', 0 );
    like $invalid->{stderr}, qr/\Amutation: [^\n]*jobs[^\n]*\n\z/, 'one line that names the setting';
    is $invalid->{stdout}, q{}, 'no report';

    my $spaced = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) ) . '/with a space';
    mkdir $spaced or die "mkdir: $!";
    symlink Cwd::abs_path('lib'), "$spaced/lib" or die "symlink: $!";
    my $installed = ran_from( "$spaced/lib", 2, $root, '--jobs', 0 );
    is $installed->{stderr}, $invalid->{stderr}, 'a library under a directory with a space gives the same line';
};

subtest 'run writes the JSON and HTML reports' => sub {
    my $root = copy_of('calc');
    my $run  = ran( 0, $root, '--jobs', 2 );
    like $run->{stdout}, qr/^Reports: mutation-report\/mutation\.json, mutation-report\/mutation\.html$/m,
      'the report paths';

    my $document = JSON::PP->new->utf8->decode( slurp("$root/mutation-report/mutation.json") );
    is $document->{schemaVersion},                               '2', 'the JSON report has the schema version';
    is scalar( $document->{files}{'lib/Calc.pm'}{mutants}->@* ), 21,  'the JSON report has every mutant';
    like slurp("$root/mutation-report/mutation.html"), qr/<mutation-test-report-app\b/,
      'the HTML report has the viewer';
};

subtest '--format and --report-dir choose the reports' => sub {
    my $root = copy_of('calc');
    my $run  = ran( 0, $root, '--jobs', 2, '--format', 'terminal', '--format', 'json', '--report-dir', 'out' );
    ok -f "$root/out/mutation.json",  'the JSON report is in the named directory';
    ok !-e "$root/out/mutation.html", 'no HTML report';
    ok !-e "$root/mutation-report",   'the default directory is not created';
    like $run->{stdout}, qr/^Reports: out\/mutation\.json$/m, 'the report path';

    my $quiet = ran( 0, copy_of('calc'), '--jobs', 2, '--format', 'json' );
    unlike $quiet->{stdout}, qr/^Score:/m, 'no terminal report when the format is left out';

    my $elsewhere = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $project   = copy_of('calc');
    my $named     = ran( 0, $project, '--jobs', 2, '--format', 'json', '--report-dir', "$elsewhere/out" );
    ok -f "$elsewhere/out/mutation.json", 'the report is in that directory';
    is $named->{stdout}, "Reports: $elsewhere/out/mutation.json\n", 'and the output names it';
    is [ grep { !/\A(?:lib|t|[.]mutation|mutation[.]toml)\z/ } map { s{.*/}{}r } glob "$project/* $project/.mutation" ],
      [],
      'the project gets no directory for it';
};

subtest 'mutation.toml configures the run' => sub {
    my $root = copy_of('calc');
    write_file( "$root/mutation.toml",
        "jobs = 2\ndisable = [\"sub-body\", \"return-value\"]\nformat = [\"terminal\"]\n" );
    my $run = ran( 0, $root );
    like $run->{stdout}, qr/^10 mutants: 9 killed, 1 no coverage$/m, 'the disabled mutators are left out';
    like $run->{stdout}, qr/^2 tests, 2 jobs,/m,                     'jobs come from the file';
    ok !-e "$root/mutation-report", 'the formats come from the file';

    like ran( 0, $root, '--jobs', 1 )->{stdout}, qr/^2 tests, 1 job,/m, 'the command line beats the file';
};

subtest 'a broken configuration file is a usage error' => sub {
    my $root = copy_of('calc');
    write_file( "$root/mutation.toml", "profil = \"default\"\n" );
    my $unknown = ran( 2, $root );
    like $unknown->{stderr}, qr/\Amutation: mutation\.toml: profil names no setting; the nearest is profile\n\z/,
      'the key is named';

    write_file( "$root/mutation.toml", "jobs = = 2\n" );
    my $syntax = ran( 2, $root );
    like $syntax->{stderr}, qr/\Amutation: mutation\.toml: [^\n]+\n\z/, 'the file is named on one line';
};

subtest '--config names another configuration file' => sub {
    my $root = copy_of('calc');
    write_file( "$root/ci.toml", "disable = [\"sub-body\"]\nformat = [\"terminal\"]\n" );
    like ran( 0, $root, '--jobs', 2, '--config', 'ci.toml' )->{stdout}, qr/^14 mutants:/m, 'the named file is read';
    my $missing = ran( 2, $root, '--config', 'absent.toml' );
    like $missing->{stderr}, qr/\Amutation: cannot read absent\.toml: /, 'the file is named';
};

subtest 'options choose mutators, files, and selection' => sub {
    my $root   = copy_of('calc');
    my @common = ( '--jobs', 2, '--format', 'terminal' );
    like ran( 0, $root, @common, '--disable', 'sub-body', '--disable', 'return-value' )->{stdout}, qr/^13 mutants:/m,
      '--disable';
    like ran( 0, $root, @common, '--disable', 'arithmetic', '--enable', 'number-literal' )->{stdout},
      qr/^\d+ mutants:.*\n(?:.*\n)*.*replaced 0 with 1/m, '--enable adds an extended mutator';
    my ($extended) = ran( 0, $root, @common, '--profile', 'extended' )->{stdout} =~ /^(\d+) mutants:/m;
    ok $extended > 21, "--profile extended yields more mutants ($extended)";
    like ran( 0, $root, @common, '--coverage', 'file' )->{stdout}, qr/^21 mutants: 15 killed, 6 survived$/m,
      '--coverage file runs every loading test';
    like ran( 0, $root, @common, '--test', 't/add.t' )->{stdout}, qr/^1 test, /m, '--test';
    like ran( 2, $root, @common, '--source', 'lib/Nothing*.pm' )->{stderr}, qr{\Qlib/Nothing*.pm\E},
      'an unmatched explicit source names the pattern';
};

subtest 'options choose the interpreter, the time limits, and the work directory' => sub {
    my $root     = copy_of('calc');
    my @common   = ( '--jobs', 2, '--format', 'terminal' );
    my $ordinary = ran( 0, $root, @common, '--perl', $^X, '--timeout-factor', 3, '--timeout-floor', 5 );
    ran( 2, $root, @common, '--perl',           "$root/no-such-perl" );
    ran( 2, $root, @common, '--timeout-factor', 0 );

    is [ glob "$ordinary->{temporary}/mutation-*" ], [], 'the workspace is removed by default';
    my $kept;
    is Gate::outcomes( sub { $kept = ran( 0, $root, @common, '--keep-work' ) } ), [ 'pass', 'fail' ],
      'the helper reports the kept work directory';
    my @kept = glob "$kept->{temporary}/mutation-*/kept";
    is scalar @kept, 1, '--keep-work retains one marked workspace';
};

subtest '--mutant limits the run to the named mutants' => sub {
    my $root = copy_of('calc');
    my ($id) =
      ran( 0, $root, '--jobs', 2, '--format', 'terminal' )->{stdout} =~
      /^  ([0-9a-f]{12})  [^\n]+  replaced > with >=  \[Survived\]$/m;
    my $run = ran( 0, $root, '--jobs', 2, '--format', 'terminal', '--mutant', $id );
    like $run->{stdout}, qr/^1 mutant: 1 survived$/m, 'one mutant ran';
};

subtest 'GitHub Actions gets annotations and a job summary' => sub {
    my $root   = copy_of('calc');
    my $format = ran( 0, $root, '--jobs', 2, '--format', 'terminal', '--github' );
    like $format->{stderr},
      qr/^::warning file=lib\/Calc\.pm,line=12,col=15,endLine=12,endColumn=16,title=Survived::/m,
      '--github prints annotations on standard error';
    unlike $format->{stdout}, qr/^::warning/m, 'the terminal report is separate from workflow commands';

    local $ENV{GITHUB_ACTIONS}      = 'true';
    local $ENV{GITHUB_STEP_SUMMARY} = "$root/summary.md";
    my $detected = ran( 0, $root, '--jobs', 2 );
    like $detected->{stdout},       qr/^Score: 71\.4%/m,                 'the terminal report stays';
    like $detected->{stderr},       qr/^::warning file=lib\/Calc\.pm,/m, 'annotations are added inside GitHub Actions';
    like slurp("$root/summary.md"), qr/^Score: \*\*71\.4%\*\*/m,         'the job summary is appended';

    local $ENV{GITHUB_STEP_SUMMARY} = q{};
    my $unnamed = ran( 0, $root, '--jobs', 2 );
    like $unnamed->{stderr}, qr/^::warning file=lib\/Calc\.pm,/m, 'and the annotations stay';
};

done_testing;
