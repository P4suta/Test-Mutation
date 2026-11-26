use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib', 't/lib';
use Fixture qw(run_fixture statuses write_file);
use Test::Mutation::Pool;

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
      work( copies => 2, walks => 5, spawns => 4, listings => 3, baseline_tests => 1 ),
      'one copy of the project and one of the job, two baseline walks, one walk and one test for each mutant, and no compile';
};

subtest 'an in-place run backs up the project and checks for changes before returning' => sub {
    my ($result) = run_fixture(
        project( 'lib/Small.pm' => $MODULE, 't/waits.t' => $WAITS ),
        jobs        => 1,
        equivalence => 0,
        in_place    => 1
    );
    is $result->stats, work( copies => 1, walks => 6, spawns => 4, listings => 3, baseline_tests => 1 ), 'the counts';
};

subtest 'an undetected mutant shares one original compile with all mutants of its file' => sub {
    my $module   = $MODULE =~ s/^1;$/sub size { return \$_[0] > 5 ? 'big' : 'small' }\n1;/mr;
    my $test     = "use Test::More tests => 2;\nuse Small;\nis Small::next_one(2), 3;\nis Small::size(9), 'big';\n";
    my ($result) = run_fixture(
        project( 'lib/Small.pm' => $module, 't/small.t' => $test ),
        jobs   => 1,
        enable => ['comparison-boundary']
    );
    my %count;
    $count{$_}++ for values statuses($result)->%*;
    is \%count, { Killed => 7, Survived => 1 }, 'one mutant survives';
    is [ $result->stats->@{qw(compiles spawns baseline_tests verifications)} ], [ 2, 1 + 8 + 2, 1, 0 ],
      'one original, one mutant, and one process per test or compile';
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
    is $result->jobs,                    2, 'the tests pass with one working directory per job';
    is $result->stats->{baseline_tests}, 2, 'each original test ran once in the shared directory';
    cmp_ok $result->stats->{verifications}, '>=', 3, 'the serial failure check and both private copies ran';
    is $result->stats->{spawns}, 2 + $result->stats->{verifications} + 3,
      'the count includes each verification and each mutant test';
};

subtest 'restoring the project after a mutant avoids rerunning unaffected tests' => sub {
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
    is [ $result->stats->@{qw(baseline_tests verifications)} ], [ 2, 4 ],
      'the reader is checked once and each of the three changes repeats only its original writer';
};

subtest 'uncovered changes are compared without renting a test slot' => sub {
    my $root = project(
        'lib/Idle.pm' => "package Idle;\nsub size { return 10 > 5 ? 'big' : 'small' }\n1;\n",
        't/idle.t'    => "use Test::More tests => 1;\npass 'an unrelated test';\n",
    );
    my ($result) = run_fixture( $root, enable => ['comparison-boundary'], jobs => 2 );
    is [ $result->stats->@{qw(copies walks)} ], [ 1, 2 ], 'only the shared original tree is copied and compared';
    ok + ( grep { $_->{reason} && $_->{reason} eq 'same-code-as-original' } $result->entries->@* ),
      'the folded comparison still has its original code';
    is [ grep { $_->{tests_run} } $result->entries->@* ], [], 'no mutant needed a test process';
};
subtest 'concurrent comparisons use one original and its measured duration' => sub {
    my $root = project(
        'lib/Idle.pm' => "package Idle;\nsub size { return 10 > 5 ? 'big' : 'small' }\n1;\n",
        't/idle.t'    => "use Test::More tests => 1;\npass 'an unrelated test';\n",
    );
    my $pool = \&Test::Mutation::Pool::run;
    for my $case ( [ 0.25, 10 ], [ 1.75, 17.5 ] ) {
        my ( @originals, @limits );
        no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        local *Test::Mutation::Pool::run = sub (%args) {
            my ( $next, $done ) = @args{qw(next done)};
            return $pool->(
                %args,
                next => sub {
                    my $task = $next->() or return;
                    if ( grep { $_ eq '-MO=Deparse' } $task->{command}->@* ) {
                        if   ( $task->{command}[-1] =~ m{/lib/Idle[.]pm\z} ) { push @originals, $task }
                        else                                                 { push @limits,    $task->{timeout} }
                    }
                    return $task;
                },
                done => sub ( $task, $result ) {
                    $result = { %$result, duration => $case->[0] } if grep { $_ == $task } @originals;
                    return $done->( $task, $result );
                },
            );
        };
        my ($result) = run_fixture( $root, enable => ['comparison-boundary'], jobs => 3 );
        is scalar @originals, 1, 'one child compiled the original file';
        cmp_ok scalar(@limits), '>', 1, 'several mutant compiles followed';
        is \@limits,                   [ ( $case->[1] ) x @limits ], 'each mutant uses the same measured deadline';
        is $result->stats->{compiles}, 1 + @limits, 'the work count matches the actual compiler processes';
    }
};

done_testing;
