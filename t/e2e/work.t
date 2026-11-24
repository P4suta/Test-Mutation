use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib', 't/lib';
use Fixture qw(run_fixture statuses write_file);

# The result of a run counts its work, and each project here knows the exact count of each kind.
# A test that fails under a mutant waits afterwards, so the pool always meets it alive and lists its processes once.

my $MODULE = "package Small;\nuse strict;\nuse warnings;\nsub next_one { return \$_[0] + 1 }\n1;\n";
my $WAITS  = <<'PERL';
use Small;
$| = 1;
print "1..1\n";
if ( Small::next_one(2) == 3 ) { print "ok 1\n" }
else                           { print "not ok 1\n"; sleep 30 }
PERL

sub project (%files) {
    my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$root/$_", $files{$_} ) for sort keys %files;
    return $root;
}

sub work (%counts) {
    return {
        copies         => 0,
        walks          => 0,
        compiles       => 0,
        spawns         => 0,
        listings       => 0,
        baseline_tests => 0,
        verifications  => 0,
        %counts
    };
}

subtest 'a run in copies counts each copy, walk, process, and listing' => sub {
    my ($result) =
      run_fixture( project( 'lib/Small.pm' => $MODULE, 't/waits.t' => $WAITS ), jobs => 1, equivalence => 0 );
    is [ sort values statuses($result)->%* ], [ ('Killed') x 3 ], 'the test detects the three mutants';
    is $result->stats,
      work( copies => 2, walks => 6, spawns => 4, listings => 3, baseline_tests => 1 ),
      'one copy of the project and one of the job, two walks and one test for each mutant, and no compile';
};

subtest 'a run in the project itself makes no copy and walks the project before and after the mutants' => sub {
    my ($result) = run_fixture(
        project( 'lib/Small.pm' => $MODULE, 't/waits.t' => $WAITS ),
        jobs        => 1,
        equivalence => 0,
        in_place    => 1
    );
    is $result->stats, work( walks => 2, spawns => 4, listings => 3, baseline_tests => 1 ), 'the counts';
};

subtest 'an undetected mutant costs a compile of its code, and the original costs two' => sub {
    my $module   = $MODULE =~ s/^1;$/sub size { return \$_[0] > 5 ? 'big' : 'small' }\n1;/mr;
    my $test     = "use Test::More tests => 2;\nuse Small;\nis Small::next_one(2), 3;\nis Small::size(9), 'big';\n";
    my ($result) = run_fixture( project( 'lib/Small.pm' => $module, 't/small.t' => $test ), jobs => 1 );
    my %count;
    $count{$_}++ for values statuses($result)->%*;
    is \%count, { Killed => 6, Survived => 1 }, 'one mutant survives';
    is [ $result->stats->@{qw(compiles spawns baseline_tests verifications)} ], [ 3, 1 + 7 + 3, 1, 0 ],
      'three compiles, and a process for each test and each compile';
};

# One of the two tests holds the directory, so the other one fails and runs once more.
subtest 'a test that fails side by side runs once more, alone' => sub {
    my $guarded = sub ($name) {
        return
            "use Test::More tests => 2;\nuse Small;\n"
          . "ok mkdir('held'), '$name holds the directory';\nselect undef, undef, undef, 0.8;\nrmdir 'held';\n"
          . "is Small::next_one(2), 3, 'the next one';\n";
    };
    my ($result) = run_fixture(
        project( 'lib/Small.pm' => $MODULE, 't/first.t' => $guarded->('first'), 't/second.t' => $guarded->('second') ),
        equivalence => 0
    );
    is $result->jobs, 1, 'the tests fail side by side';
    is [ $result->stats->@{qw(baseline_tests verifications spawns)} ], [ 2, 1, 2 + 1 + 3 ],
      'the two tests of the unmodified run and the run that verifies the failure';
};

subtest 'a mutant that changes the project makes every test run once more' => sub {
    my $writer =
        "use Test::More tests => 1;\nuse Small;\nmy \$next = Small::next_one(2);\n"
      . "if ( \$next != 3 ) { open my \$out, '>', 'left-behind.txt' or die \$!; close \$out }\n"
      . "is \$next, 3, 'the next one';\n";
    my $reader = "use Test::More tests => 1;\nok !-e 'left-behind.txt', 'no file is in the way';\n";
    my ($result) = run_fixture(
        project( 'lib/Small.pm' => $MODULE, 't/reader.t' => $reader, 't/writer.t' => $writer ),
        jobs        => 1,
        equivalence => 0,
        in_place    => 1
    );
    is [ $result->stats->@{qw(baseline_tests verifications)} ], [ 2, 2 ], 'the two tests of the unmodified run, twice';
};

done_testing;
