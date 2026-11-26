use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(run_fixture write_file);

use Test::Mutation::Source;

my $source  = Test::Mutation::Source::read_bytes('t/fixtures/exclusive/lib/Exclusive.pm');
my $guarded = Test::Mutation::Source::read_bytes('t/fixtures/exclusive/t/resource.t');

sub project (%files) {
    my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$root/lib/Exclusive.pm", $source );
    write_file( "$root/$_",               $files{$_} ) for sort keys %files;
    return $root;
}

sub run_project ( $root, $jobs = 3, $overlap = 'mutants' ) {
    my $directory = File::Temp::tempdir( CLEANUP => 1 );
    local $ENV{MUTATION_TEST_LOCK}    = "$directory/resource";
    local $ENV{MUTATION_TEST_OVERLAP} = $jobs > 1 ? $overlap : q{};
    my ($result) = run_fixture( $root, jobs => $jobs, equivalence => 0, timeout_floor => 30 );
    return $result;
}

subtest 'overlapping failures require an isolated observation of the same mutant' => sub {
    my $root   = project( 't/resource.t' => $guarded );
    my $report = run_project($root);
    is $report->jobs,                                              3,  'another test can still occupy a spare job';
    is $report->baseline_failures,                                 [], 'the original test passes alone';
    is [ grep { $_->{status} eq 'Killed' } $report->entries->@* ], [], 'contention supplies no kill';
    ok $report->stats->{verifications} > 0, 'overlapping failures were repeated in isolation';
    is scalar $report->warnings->@*, 1, 'the resource test gives one warning';
    like $report->warnings->[0] || q{}, qr/t\/resource[.]t/, 'the warning names the locked test';
    my $serial = run_project( $root, 1 );
    is [ map { [ $_->{mutant}->id, $_->{status} ] } $report->entries->@* ],
      [ map { [ $_->{mutant}->id, 'Survived' ] } $serial->entries->@* ], 'every loaded mutant survives after isolation';
    is [ map { $_->{status} } $report->entries->@* ], [ map { $_->{status} } $serial->entries->@* ],
      'the reported verdicts match the serial control';
};

subtest 'an independent failing assertion still identifies its mutant after a conflict' => sub {
    my $root = project(
        't/a.t' => $guarded,
        't/z.t' => "use Test::More tests => 1;\nuse Exclusive;\nis Exclusive::number(2), 3;\n",
    );
    my $report = run_project($root);
    is [ map { [ $_->{status}, $_->{by} ] } $report->entries->@* ],
      [ ( [ 'Killed', 't/z.t' ] ) x 3 ], 'only the assertion with a reproducible failure detects each change';
};

subtest 'the project rules order ordinary tests and concurrent copies of one test' => sub {
    my $rules = "---\nseq:\n  - seq: 't/*.t'\n";
    for my $name (qw(testrules.yml t/testrules.yml)) {
        my $report = run_project( project( $name => $rules, 't/a.t' => $guarded, 't/b.t' => $guarded ), 3, q{} );
        is $report->baseline_failures,      [], "$name protects the shared resource";
        is $report->jobs,                   3,  'the configured number of jobs is available';
        is $report->stats->{verifications}, 0,  'the scheduler prevented every conflicting invocation';
        is $report->warnings,               [], 'the declared rule needed no recovery';
        is [ grep { $_->{status} ne 'Survived' } $report->entries->@* ], [], 'all covered mutants pass';
    }
};

subtest 'the declared serial order chooses the detecting test and bounds the number of copies' => sub {
    my $assertion = "use Test::More tests => 1;\nuse Exclusive;\nis Exclusive::number(2), 3;\n";
    my $root      = project(
        'testrules.yml' => "---\nseq:\n  - 't/z.t'\n  - 't/a.t'\n",
        't/a.t'         => $assertion,
        't/z.t'         => $assertion,
    );
    my $report = run_project( $root, 2 );
    is [ map { [ $_->{status}, $_->{by} ] } $report->entries->@* ],
      [ ( [ 'Killed', 't/z.t' ] ) x 3 ], 'the first detecting test follows the distribution rules';
    cmp_ok $report->stats->{copies}, '<=', 3, 'the two workers and their shared baseline bound private copies';
};

subtest 'an external baseline conflict persists across independent copies' => sub {
    my $report = run_project( project( 't/a.t' => $guarded, 't/b.t' => $guarded ), 3, 'originals' );
    is $report->baseline_failures,                [],       'the serial baseline passes';
    is [ $report->jobs, $report->parallel_safe ], [ 1, 0 ], 'the conflict requires a serial suite';
    like $report->warnings->[0] || q{}, qr/one test at a time/, 'the warning explains the serial run';
};

done_testing;
