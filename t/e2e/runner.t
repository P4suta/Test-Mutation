use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(run_fixture statuses write_file);
use Permutl::Config;
use Permutl::Runner;
use Permutl::Tree;

my $MODULE = "package Small;\nuse strict;\nuse warnings;\nsub next_one { return \$_[0] + 1 }\n1;\n";
my $TEST   = "use Test::More tests => 1;\nuse Small;\nis Small::next_one(2), 3, 'the next one';\n";

sub project (%files) {
    my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$root/$_", $files{$_} ) for sort keys %files;
    return $root;
}

sub listened ( $root, %settings ) {
    my @events;
    my $config = Permutl::Config->new( root => $root, jobs => 1, %settings );
    my $result = Permutl::Runner::run( $config, sub ( $event, $data ) { push @events, [ $event, $data ] } );
    return ( $result, [ map { $_->[1] } grep { $_->[0] eq 'mutant' } @events ] );
}

subtest 'a project without a test gets a warning, and its mutants have no coverage' => sub {
    my $root = project( 'lib/Small.pm' => $MODULE );
    my ($result) = run_fixture($root);
    is $result->warnings,                             ['no test files match'], 'the warning';
    is [ map { $_->{status} } $result->entries->@* ], [ ('NoCoverage') x 3 ], 'every mutant is listed without coverage';
    ok !-e "$root/.permutl", 'and no work directory appears';
};

subtest 'the analysis keeps the files in the order of their paths and names each file it cannot use' => sub {
    my $second = $MODULE =~ s/Small/Second/r;
    my $root   = project(
        'lib/Bad.pm'    => "package Bad;\r\n1;\r\n",
        'lib/First.pm'  => $MODULE =~ s/Small/First/r,
        'lib/Odd.pm'    => "package Odd;\r\n1;\r\n",
        'lib/Second.pm' => $second,
    );
    my $analysis = Permutl::Runner::analyze( Permutl::Config->new( root => $root ) );
    is [ map { $_->{path} } $analysis->{problems}->@* ], [ 'lib/Bad.pm', 'lib/Odd.pm' ], 'the files with a problem';
    is [ map { $_->path } $analysis->{mutants}->@* ], [ ('lib/First.pm') x 3, ('lib/Second.pm') x 3 ],
      'the mutants of the other files';
    is [ sort keys $analysis->{sources}->%* ], [ 'lib/First.pm', 'lib/Second.pm' ], 'and their sources';
};

subtest 'a project without a test and without a mutant to run gets no warning' => sub {
    my $root = project( 'lib/Small.pm' => $MODULE =~ s/[+] 1 [}]/+ 1 }    ## no mutate/r );
    my ($result) = run_fixture($root);
    is $result->warnings, [], 'no test is missing where no mutant would run';
};

subtest 'a project whose mutants are all suppressed runs no test and gets no warning' => sub {
    my $root = project( 'lib/Small.pm' => $MODULE =~ s/[+] 1 [}]/+ 1 }    ## no mutate/r, 't/small.t' => $TEST );
    my ($result) = run_fixture($root);
    is $result->warnings, [], 'no warning';
    is [ map { [ $_->@{qw(status reason)} ] } $result->entries->@* ],
      [ ( [ 'Ignored', 'suppressed by a comment' ] ) x 3 ],
      'every mutant is ignored for the reason that the run with tests gives';
    is $result->tests, [], 'no test ran';
};

subtest 'a suppressed mutant among others is ignored, and the others run in the order of the analysis' => sub {
    my $root = project(
        'lib/Small.pm' => "package Small;\nuse strict;\nuse warnings;\n"
          . "sub quiet { return \$_[0] - 1 }    ## no mutate\nsub next_one { return \$_[0] + 1 }\n1;\n",
        't/small.t' => $TEST,
    );
    my ( $result, $reported ) = listened($root);
    is statuses($result),
      {
        'lib/Small.pm:4 removed the body of quiet'    => 'Ignored',
        'lib/Small.pm:4 removed the return value'     => 'Ignored',
        'lib/Small.pm:4 replaced - with +'            => 'Ignored',
        'lib/Small.pm:5 removed the body of next_one' => 'Killed',
        'lib/Small.pm:5 removed the return value'     => 'Killed',
        'lib/Small.pm:5 replaced + with -'            => 'Killed',
      },
      'statuses';
    is [ map { $_->{reason} } grep { $_->{status} eq 'Ignored' } $result->entries->@* ],
      [ ('suppressed by a comment') x 3 ], 'the reason of an ignored mutant';
    is [ map { $_->{mutant}->id } $reported->@* ],
      [ map { $_->{mutant}->id } grep { $_->{status} eq 'Killed' } $result->entries->@* ],
      'the listener hears of each mutant that ran, once and in the order of the analysis';
    is [ grep { $_->{duration} <= 0 } $reported->@* ], [], 'each of them took some time';
};

subtest 'an error of the listener stops the run and leaves no work directory' => sub {
    my $root   = project( 'lib/Small.pm' => $MODULE, 't/small.t' => $TEST );
    my $config = Permutl::Config->new( root => $root, jobs => 1 );
    is dies {
        Permutl::Runner::run( $config, sub ( $event, $data ) { die "the listener broke\n" if $event eq 'mutant' } )
    }, "the listener broke\n", 'the error passes through unchanged';
    ok !glob("$root/.permutl/run-*"), 'the work directory is removed';
};

subtest 'tests that fail side by side run one at a time' => sub {
    my $guarded = sub ($name) {
        return
            "use Test::More tests => 2;\nuse Small;\n"
          . "ok mkdir('held'), '$name holds the directory';\nselect undef, undef, undef, 0.8;\nrmdir 'held';\n"
          . "is Small::next_one(2), 3, 'the next one';\n";
    };
    my $root =
      project( 'lib/Small.pm' => $MODULE, 't/first.t' => $guarded->('first'), 't/second.t' => $guarded->('second') );
    my ($result) = run_fixture($root);
    is $result->baseline_failures,                [],       'the unmodified run passes after the second attempt';
    is [ $result->parallel_safe, $result->jobs ], [ 0, 1 ], 'the result names one job and no safe parallel run';
    is $result->warnings, ['the tests fail when they run side by side, so the mutants run one test at a time'],
      'the warning';
    is [ sort values statuses($result)->%* ], [ ('Killed') x 3 ], 'and the mutants are measured';
};

subtest 'a test that fails on its own is not blamed on the parallel run' => sub {
    my $counted = "use Test::More tests => 1;\nuse Small;\nopen my \$log, '>>', \$ENV{RUN_LOG} or die \$!;\n"
      . "print {\$log} \"run\\n\";\nclose \$log;\nis Small::next_one(2), 4, 'never equal';\n";
    my $runs = sub ($log) {
        open my $handle, '<', $log->filename or die "read: $!";
        my @lines = readline $handle;
        return scalar @lines;
    };

    my $alone = project( 'lib/Small.pm' => $MODULE, 't/small.t' => $counted );
    my $first = File::Temp->new;
    local $ENV{RUN_LOG} = $first->filename;
    my ($serial) = run_fixture( $alone, jobs => 1 );
    is [ map { $_->{test} } $serial->baseline_failures->@* ], ['t/small.t'], 'the failure is reported with one job';
    is $runs->($first),                                       1,             'and the test ran once';

    my $beside = project( 'lib/Small.pm' => $MODULE, 't/small.t' => $counted );
    my $second = File::Temp->new;
    local $ENV{RUN_LOG} = $second->filename;
    my ($parallel) = run_fixture( $beside, jobs => 2 );
    is [ map { $_->{test} } $parallel->baseline_failures->@* ], ['t/small.t'], 'the failure is reported with two jobs';
    is $runs->($second),                                        2,             'after a second attempt on its own';
    is [ $parallel->parallel_safe, $parallel->warnings ],       [ 1, [] ],     'and the parallel run gets no blame';
};

subtest 'the work files of a finished task are removed while the run goes on' => sub {
    my $root = project(
        'lib/Small.pm' => "package Small;\nuse strict;\nuse warnings;\nBEGIN { die \"broken\\n\" if 3 - 1 != 2 }\n"
          . "sub next_one { return \$_[0] + 1 }\nsub spare { return 10 > 5 ? 'big' : 'small' }\n1;\n",
        't/small.t' => $TEST,
    );
    my ($result) = run_fixture( $root, keep_work => 1 );
    my %count;
    $count{$_}++ for values statuses($result)->%*;
    is \%count, { CompileError => 3, Killed => 3, NoCoverage => 3, Survived => 1, Ignored => 1 },
      'the run has compile errors, detected mutants, and mutants whose code is compared';
    my ($work) = glob "$root/.permutl/run-*";
    ok defined $work && -d "$work/shim", 'the work directory stays on request';
    is [ map { s{\A\Q$work\E/}{}r } map { glob "$work/$_/*" } qw(records tmp stderr mutants) ], [],
      'and it holds no record, no temporary directory, no error output, and no mutant file';
};

subtest 'the time limit grows with the duration of the unmodified test' => sub {
    my $slow = "use Test::More tests => 1;\nselect undef, undef, undef, 0.6;\nuse Small;\n"
      . "is Small::next_one(2), 3, 'the next one';\n";
    my $root = project( 'lib/Small.pm' => $MODULE, 't/small.t' => $slow );
    my ($result) = run_fixture( $root, timeout_factor => 4, timeout_floor => 0.1 );
    is [ sort values statuses($result)->%* ], [ ('Killed') x 3 ], 'four times the duration is enough for each mutant';
};

subtest 'the tests inherit the library path and the options of the interpreter' => sub {
    my $environment =
        "use Test::More tests => 3;\nuse Small;\nis Small::next_one(2), 3, 'the next one';\n"
      . "like \$ENV{PERL5OPT}, qr/\\A%s-MPermutl::Shim::G\\d+\\z/, 'the options';\n"
      . "like \$ENV{PERL5LIB}, qr{\\A[^:]+/shim%s\\z}, 'the library path';\n";
    my $run = sub ( $options, $library, @expected ) {
        my $root = project( 'lib/Small.pm' => $MODULE, 't/small.t' => sprintf $environment, @expected );
        local $ENV{PERL5OPT} = $options;
        local $ENV{PERL5LIB} = $library;
        my ($result) = run_fixture($root);
        return [ map { $_->{output} } $result->baseline_failures->@* ];
    };
    is $run->( q{}, q{}, q{}, q{} ), [], 'empty variables add nothing';
    is $run->( '-MFile::Spec', '/elsewhere', '-MFile::Spec ', ':/elsewhere' ), [],
      'set variables stay after the additions';
};

subtest 'warnings come once each and in the order of their text' => sub {
    my $direct = "use Test::More tests => 1;\nuse Cwd ();\nrequire( Cwd::getcwd() . '/lib/Small.pm' );\n"
      . "is Small::next_one(2), 3, 'the next one';\n";
    my $bound =
        "package Bound;\nuse strict;\nuse warnings;\nBEGIN { die \"no application\\n\" if !\$main::APPLICATION }\n"
      . "sub size { return 10 > 5 ? 'big' : 'small' }\nsub spare { return 1 }\nsub other { return 2 }\n1;\n";
    my $root = project(
        'lib/Small.pm' => $MODULE,
        'lib/Bound.pm' => $bound,
        't/second.t'   => $direct,
        't/first.t'    => $direct,
        't/bound.t'    => "use Test::More tests => 1;\nBEGIN { \$main::APPLICATION = 1 }\nuse Bound;\n"
          . "is Bound::size(), 'big', 'a size';\n",
    );
    my ($result) = run_fixture( $root, jobs => 1 );
    is $result->warnings,
      [
        'lib/Bound.pm does not pass a standalone syntax check, so its load failures count as compile errors',
        'lib/Bound.pm: B::Deparse gives no stable output, so the run compares no compiled code of the file',
        't/first.t loads lib/Small.pm around the hook and cannot detect its mutants',
        't/second.t loads lib/Small.pm around the hook and cannot detect its mutants',
      ],
      'four warnings';
    my %status = statuses($result)->%*;
    is {
        map { $_ => $status{$_} } grep { /lib\/Bound[.]pm:4 / } keys %status
    },
      {
        'lib/Bound.pm:4 removed !'               => 'CompileError',
        'lib/Bound.pm:4 removed the statement'   => 'Survived',
        'lib/Bound.pm:4 replaced if with unless' => 'CompileError',
      },
      'a load failure of the file that fails the check counts as a compile error';
};

# A module with two subs, a test that writes files when the first sub goes wrong, and a test that trips over one of them.
sub writing_project () {
    my $module = "package Small;\nuse strict;\nuse warnings;\nsub next_one { return \$_[0] + 1 }\n"
      . "sub size { return \$_[0] > 5 ? 'big' : 'small' }\n1;\n";
    my $writer =
        "use Test::More tests => 1;\nuse Small;\nmy \$next = Small::next_one(2);\n"
      . "if ( \$next != 3 ) { for my \$name ( 'left-behind.txt', map { \"more-\$_.txt\" } 1 .. 6 ) {"
      . " open my \$out, '>', \$name or die \$!; close \$out } }\n"
      . "is \$next, 3, 'the next one';\n";
    my $reader = "use Test::More tests => 2;\nuse Small;\nok !-e 'left-behind.txt', 'no file is in the way';\n"
      . "is Small::size(9), 'big', 'a size';\n";
    return project( 'lib/Small.pm' => $module, 't/reader.t' => $reader, 't/writer.t' => $writer );
}

sub status_by_line ($result) {
    return { map { $_->{mutant}->from->[0] . q{ } . $_->{mutant}->description => $_->{status} } $result->entries->@* };
}

sub project_state ($root) {
    return Permutl::Tree::snapshot( root => $root, skip => ['.permutl'] );
}

subtest 'a mutant that leaves a file changes a copy, and the project and the later mutants stay clear of it' => sub {
    for my $jobs ( 1, 4 ) {
        my $root     = writing_project();
        my $before   = project_state($root);
        my ($result) = run_fixture( $root, jobs => $jobs );
        is $result->warnings, [], "no warning with $jobs side by side";
        is status_by_line($result),
          {
            '4 removed the body of next_one' => 'Killed',
            '4 removed the return value'     => 'Killed',
            '4 replaced + with -'            => 'Killed',
            '5 removed the body of size'     => 'Killed',
            '5 removed the return value'     => 'Killed',
            '5 replaced > with <='           => 'Killed',
            '5 replaced > with >='           => 'Survived',
          },
          'every mutant has the verdict of its own tests';
        ok $result->conclusive, 'the run is conclusive';
        is Permutl::Tree::changes( $before, project_state($root) ), [], 'the project is as it was';
    }
};

subtest 'the tests of each mutant start from the state that the unmodified run left' => sub {
    my $counting =
        "use Test::More tests => 1;\nuse Small;\nopen my \$count, '>>', 'count.txt' or die \$!;\n"
      . "print {\$count} \"run\\n\";\nclose \$count;\nopen my \$log, '>>', \$ENV{RUN_LOG} or die \$!;\n"
      . "print {\$log} -s 'count.txt', \"\\n\";\nclose \$log;\nis Small::next_one(2), 3, 'the next one';\n";
    my $root = project( 'lib/Small.pm' => $MODULE, 't/small.t' => $counting );
    my $log  = File::Temp->new;
    local $ENV{RUN_LOG} = $log->filename;
    my ($result) = run_fixture( $root, jobs => 1 );
    open my $handle, '<', $log->filename or die "read: $!";
    chomp( my @sizes = readline $handle );
    is \@sizes, [ 4, 8, 8, 8 ], 'each mutant finds the one line that the unmodified run wrote';
    ok !-e "$root/count.txt", 'and the project gets no such file';

    my $place = project( 'lib/Small.pm' => $MODULE, 't/small.t' => $counting );
    my $other = File::Temp->new;
    local $ENV{RUN_LOG} = $other->filename;
    run_fixture( $place, jobs => 1, in_place => 1 );
    open my $read, '<', $other->filename or die "read: $!";
    chomp( my @grown = readline $read );
    is \@grown, [ 4, 8, 12, 16, 20 ],
      'in the project itself, the file grows with every run and with the check at the end';
    ok -e "$place/count.txt", 'and stays there';
};

subtest 'a copy has the name of the project, links the installed modules, and holds no repository data' => sub {
    my $looking =
        "use Test::More tests => 1;\nuse Cwd ();\nuse lib 'local/lib/perl5';\nuse Helper;\nuse Small;\n"
      . "open my \$log, '>', \$ENV{RUN_LOG} or die \$!;\n"
      . "print {\$log} join \"\\n\", Cwd::getcwd(), ( -e '.git' ? 'git' : 'no git' ), ( -l 'local' ? 'link' : 'no link' ),"
      . " ( -e 'permutl-report' ? 'report' : 'no report' ), Helper::name(),"
      . " ( \$ENV{PWD} eq Cwd::getcwd() ? 'named' : 'not named' ), q{};\nclose \$log;\n"
      . "is Small::next_one(2), 3, 'the next one';\n";
    my $root = project(
        'lib/Small.pm'              => $MODULE,
        't/small.t'                 => $looking,
        '.git/HEAD'                 => "ref: refs/heads/main\n",
        'permutl-report/old.json'   => '{}',
        'local/lib/perl5/Helper.pm' => "package Helper;\nsub name { return 'helper' }\n1;\n",
    );
    my $log = File::Temp->new;
    local $ENV{RUN_LOG} = $log->filename;
    my ($result) = run_fixture( $root, jobs => 1 );
    is statuses($result), hash { all_vals 'Killed'; etc }, 'the tests pass in the copy and detect the mutants';
    open my $handle, '<', $log->filename or die "read: $!";
    chomp( my ( $directory, @facts ) = readline $handle );
    is \@facts, [ 'no git', 'link', 'no report', 'helper', 'named' ],
      'what a test finds in its directory, which the environment names';
    isnt $directory,                       $root, 'the directory of a test is another one than the project';
    is [ ( split m{/}, $directory )[-1] ], [ ( split m{/}, $root )[-1] ], 'and has its name';
    ok !-e $directory,     'the copies are gone after the run';
    ok $result->in_copies, 'the result names the copies';
    my ($inside) = run_fixture( $root, jobs => 1, in_place => 1 );
    ok !$inside->in_copies, 'and a run in the project itself names none';
};

subtest 'a temporary directory inside the project is no part of a copy' => sub {
    my $root = project( 'lib/Small.pm' => $MODULE, 't/small.t' => $TEST, 'tmp/kept.txt' => 'kept' );
    local $ENV{TMPDIR} = "$root/tmp";
    my $before = project_state($root);
    my ($result) = run_fixture( $root, jobs => 2 );
    is [ sort values statuses($result)->%* ],                   [ ('Killed') x 3 ], 'the mutants are measured';
    is Permutl::Tree::changes( $before, project_state($root) ), [],                 'and the project is as it was';
};

subtest 'a project that cannot be copied stops the run with the name of the other place' => sub {
    skip_all 'the superuser reads every file' if $> == 0;
    my $root = project( 'lib/Small.pm' => $MODULE, 't/small.t' => $TEST, 'private/key.txt' => 'secret' );
    chmod 0, "$root/private/key.txt" or die "chmod: $!";
    my $scratch = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    local $ENV{TMPDIR} = $scratch;
    like dies { run_fixture( $root, jobs => 1 ) },
      qr{\Acannot copy the project: cannot copy \Q$root\E/private/key[.]txt to \S+: [^;]+; --in-place runs the tests in the project itself\n\z},
      'the error names the file and the option';
    is [ glob "$scratch/*" ], [], 'and no copy is left';
    my ($inside) = run_fixture( $root, jobs => 1, in_place => 1 );
    is [ sort values statuses($inside)->%* ], [ ('Killed') x 3 ], 'the run in the project itself measures the mutants';
    chmod oct '600', "$root/private/key.txt" or die "chmod: $!";
};

subtest 'a change of the project during the run reaches no test' => sub {

    # The test stands for an edit of the user: after its first run, the test file of the project fails at once.
    my $module  = "package Small;\nuse strict;\nuse warnings;\nsub size { return \$_[0] > 5 ? 'big' : 'small' }\n1;\n";
    my $editing = "use Test::More tests => 1;\nuse Small;\nis Small::size(9), 'big', 'a size';\n"
      . "open my \$out, '>', \"\$ENV{PROJECT}/t/small.t\" or die \$!;\nprint {\$out} \"die 'edited';\\n\";\nclose \$out;\n";
    my $root = project( 'lib/Small.pm' => $module, 't/small.t' => $editing );
    local $ENV{PROJECT} = $root;
    my ($result) = run_fixture( $root, jobs => 1 );
    is status_by_line($result),
      {
        '4 removed the body of size' => 'Killed',
        '4 removed the return value' => 'Killed',
        '4 replaced > with <='       => 'Killed',
        '4 replaced > with >='       => 'Survived',
      },
      'the copied test decides, so the mutant that it misses survives';
    is $result->warnings, [], 'without a warning';

    my $place = project( 'lib/Small.pm' => $module, 't/small.t' => $editing );
    local $ENV{PROJECT} = $place;
    my ($inside) = run_fixture( $place, jobs => 1, in_place => 1 );
    is [ sort values status_by_line($inside)->%* ], [ ('NoCoverage') x 4 ],
      'in the project itself, the edited test runs for every mutant and loads none';
};

subtest 'in the project itself, a mutant that leaves a file takes the verdict from the tests it breaks' => sub {
    my $module = "package Small;\nuse strict;\nuse warnings;\nsub next_one { return \$_[0] + 1 }\n"
      . "sub size { return \$_[0] > 5 ? 'big' : 'small' }\n1;\n";

    # The first test stands for code that writes a file when it goes wrong, and the second test trips over that file.
    my $writer =
        "use Test::More tests => 1;\nuse Small;\nmy \$next = Small::next_one(2);\n"
      . "if ( \$next != 3 ) { for my \$name ( 'left-behind.txt', map { \"more-\$_.txt\" } 1 .. 6 ) {"
      . " open my \$out, '>', \$name or die \$!; close \$out } }\n"
      . "is \$next, 3, 'the next one';\n";
    my $reader = "use Test::More tests => 2;\nuse Small;\nok !-e 'left-behind.txt', 'no file is in the way';\n"
      . "is Small::size(9), 'big', 'a size';\n";
    my $root = project( 'lib/Small.pm' => $module, 't/reader.t' => $reader, 't/writer.t' => $writer );
    my ($result) = run_fixture( $root, jobs => 1, in_place => 1 );

    is $result->warnings,
      [
        't/reader.t fails without a mutant now, so the mutants it detected have no verdict',
        'the project changed while the mutants ran: created left-behind.txt, created more-1.txt, created more-2.txt, '
          . 'created more-3.txt, created more-4.txt and 2 more',
      ],
      'the warnings name the change and the test that it breaks';
    my %entry = map { $_->{mutant}->from->[0] . q{ } . $_->{mutant}->description => $_ } $result->entries->@*;
    is {
        map { $_ => $entry{$_}{status} } sort keys %entry
    },
      {
        '4 removed the body of next_one' => 'Killed',
        '4 removed the return value'     => 'Killed',
        '4 replaced + with -'            => 'Killed',
        '5 removed the body of size'     => 'RuntimeError',
        '5 removed the return value'     => 'RuntimeError',
        '5 replaced > with <='           => 'RuntimeError',
        '5 replaced > with >='           => 'RuntimeError',
      },
      'a kill by the broken test is no kill, and a kill by a sound test stays';
    is $entry{'5 replaced > with >='}{reason},
      't/reader.t fails without a mutant since the project changed',
      'the reason of a mutant without a verdict';
    ok !$result->conclusive,       'the run is not conclusive';
    ok -e "$root/left-behind.txt", 'the file stays for the user to judge';
};

subtest 'a project that the mutants leave alone is not checked again' => sub {
    my $counted = "use Test::More tests => 1;\nuse Small;\nopen my \$log, '>>', \"\$ENV{RUN_LOG}\" or die \$!;\n"
      . "print {\$log} \"run\\n\";\nclose \$log;\nis Small::next_one(2), 3, 'the next one';\n";
    my $root = project( 'lib/Small.pm' => $MODULE, 't/small.t' => $counted );
    my $log  = File::Temp->new;
    local $ENV{RUN_LOG} = $log->filename;
    my ($result) = run_fixture( $root, jobs => 1 );
    is $result->warnings, [], 'no warning';
    open my $handle, '<', $log->filename or die "read: $!";
    my @runs = readline $handle;
    is scalar(@runs), 1 + 3, 'one unmodified run and one run for each of the three mutants';
};

subtest 'a comparison with the version of Perl follows the interpreter of the tests' => sub {
    my $root = project( 'lib/Old.pm' => "package Old;\nsub era { return 'old' if \$] < 5.008; return 'new' }\n1;\n" );
    my $fake = sub ( $name, $script ) {
        write_file( "$root/$name", "#!/bin/sh\n$script\n" );
        chmod 0755, "$root/$name" or die "chmod: $!";
        return "$root/$name";
    };
    my $boundary = sub (%settings) {
        my $analysis = Permutl::Runner::analyze( Permutl::Config->new( root => $root, %settings ) );
        return scalar grep { $_->description eq 'replaced < with <=' } $analysis->{mutants}->@*;
    };
    is $boundary->(), 0, 'the interpreter of this test has another version, so the boundary yields no mutant';
    is $boundary->( perl => $fake->( 'same', 'printf 5.008' ) ), 1,
      'an interpreter of the named version keeps the mutant';
    is $boundary->( perl => $fake->( 'other', 'printf 5.010' ) ), 0, 'an interpreter of another version drops it';
    is $boundary->( perl => $fake->( 'failing', 'printf 5.010; exit 1' ) ), 1,
      'an interpreter that fails gives no version, so the mutant stays';
    is $boundary->( perl => $fake->( 'wordy', 'printf "no version here"' ) ), 1,
      'an answer that is no number gives no version';
    is $boundary->( perl => "$root/no-such-perl" ), 1, 'an interpreter that cannot start gives no version';

    $root = project( 'lib/Old.pm' => "package Old;\nsub era { return 'old' if \$] < $]; return 'new' }\n1;\n" );
    is $boundary->(), 1, 'a literal that equals the version of this interpreter keeps the mutant';
};

subtest 'a test that fails decides a mutant that ran another test into its time limit' => sub {
    my $stuck = "use Test::More tests => 1;\nuse Small;\nmy \$next = Small::next_one(2);\n"
      . "sleep 30 if \$next != 3;\nis \$next, 3, 'the next one';\n";
    my $sure = "use Test::More tests => 1;\nuse Small;\nselect undef, undef, undef, 0.3;\n"
      . "is Small::next_one(2), 3, 'the next one';\n";
    my $root = project( 'lib/Small.pm' => $MODULE, 't/stuck.t' => $stuck, 't/sure.t' => $sure );
    my ($result) = run_fixture( $root, jobs => 1, timeout_factor => 4, timeout_floor => 0.5 );
    is [ map { [ $_->@{qw(status by tests_run)} ] } $result->entries->@* ], [ ( [ 'Killed', 't/sure.t', 2 ] ) x 3 ],
      'the shorter test runs out of time, and the longer test detects each mutant';

    my $alone = project( 'lib/Small.pm' => $MODULE, 't/stuck.t' => $stuck );
    my ($only) = run_fixture( $alone, jobs => 1, timeout_factor => 4, timeout_floor => 0.5 );
    is [ map { [ $_->@{qw(status by reason)} ] } $only->entries->@* ],
      [ ( [ 'Timeout', 't/stuck.t', 't/stuck.t exceeded its time limit' ] ) x 3 ],
      'without a test that decides, the timeout stays with its test and its reason';
};

subtest 'a source that holds a single zero keeps its text' => sub {
    my $root     = project( 'lib/Zero.pm' => '0', 'lib/Small.pm' => $MODULE );
    my $analysis = Permutl::Runner::analyze( Permutl::Config->new( root => $root ) );
    is $analysis->{sources}{'lib/Zero.pm'}->text, '0', 'the text';
};

done_testing;
