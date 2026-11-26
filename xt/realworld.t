use v5.36;
use Test2::V0;
use JSON::PP ();
use lib 't/lib', 'xt/lib';
use Gate;
use RealWorld;

# The real-world harness runs for minutes inside a container, so the fast gate checks its logic here.
# The judge gets one observation to reject for every kind of finding, and the table of the runs is read as it stands.

my $TABLE = <<'TOML';
[Example]
name = "Example"
version = "1.0"
pathname = "A/AU/AUTHOR/Example-1.0.tar.gz"
sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
shape = "pure Perl"
build = [["perl", "Makefile.PL"]]
tests = ["prove", "-lr", "t"]
options = ["--shard", "1/2"]

[Example.expect]
mutants = [3, 5]
score = [40, 70]
warnings = []
seconds = 60
TOML

sub table (%change) {
    my $text = $TABLE;
    for my $key ( sort keys %change ) {
        my $line = defined $change{$key} ? "$key = $change{$key}\n" : q{};
        $text =~ s/^\Q$key\E = .*\n/$line/m
          or $text =~ s/(?=\n\[Example[.]expect\])/\n$line/
          or die "no place for $key";
    }
    return $text;
}

sub copy ($data) {
    return JSON::PP->new->decode( JSON::PP->new->encode($data) );
}

subtest 'default mutators must load in at least nine tenths of the real distribution sample' => sub {
    my $archives = [ { run => 'Example', name => 'Example' }, { run => 'Other', name => 'Other' } ];
    my $records  = {
        Example => { loads => { edge => [ 1, 5 ], over => [ 0, 4 ], extra => [ 1, 1 ] } },
        Other   => { loads => { edge => [ 0, 5 ], over => [ 1, 5 ] } },
    };
    my $counts = RealWorld::load_counts( $archives, $records );
    is $counts, { edge => [ 1, 10 ], over => [ 1, 9 ], extra => [ 1, 1 ] },
      'the numerator counts failed loads and the denominator counts all probes';
    is RealWorld::load_findings( $counts, [qw(edge missing over)] ),
      [ 'missing has no real distribution load sample', 'over failed to load in 1 of 9 real distribution probes' ],
      'the bound includes ten percent and a mutator without a sample cannot enter the default profile';
    like dies { RealWorld::load_counts( $archives, { Example => $records->{Example} } ) }, qr/Other.*load sample/,
      'an archive without observations fails the gate';
    like dies { RealWorld::load_counts( $archives, { %$records, Other => { loads => { edge => [ 2, 1 ] } } } ) },
      qr/Other.*edge/, 'a failed count larger than the number of probes is refused';
};

subtest 'the table rejects a run that lacks a field or misstates one' => sub {
    my ($run) = RealWorld::runs($TABLE)->@*;
    is $run,
      {
        run       => 'Example',
        name      => 'Example',
        version   => '1.0',
        pathname  => 'A/AU/AUTHOR/Example-1.0.tar.gz',
        sha256    => 'a' x 64,
        shape     => 'pure Perl',
        build     => [ [ 'perl', 'Makefile.PL' ] ],
        tests     => [ 'prove',   '-lr', 't' ],
        options   => [ '--shard', '1/2' ],
        config    => undef,
        hash_seed => undef,
        expect    => { mutants => [ 3, 5 ], score => [ 40, 70 ], warnings => [], seconds => 60 },
      },
      'a run with every field';
    is RealWorld::runs( table( score => undef ) )->[0]{expect}{score}, undef,
      'a run may leave out the band of the score';
    is RealWorld::runs( table( hash_seed => '"01"' ) )->[0]{hash_seed}, '01',
      'a distribution can pin the hash seed of its reference tests and mutation run';

    my @refused = (
        [ { hash_seed => '"not-hex"' }, qr/\AExample: hash_seed needs whole hexadecimal bytes\n/ ],
        [ { hash_seed => '"a"' },       qr/\AExample: hash_seed needs whole hexadecimal bytes\n/ ],
        [ { sha256    => undef },       qr/\AExample needs a sha256\n/ ],
        [ { sha256    => '"abc"' },     qr/\AExample: the sha256 is no digest of 64 hexadecimal digits\n/ ],
        [
            { pathname => '"A/AU/AUTHOR/Other-1.0.tar.gz"' },
            qr/\AExample: the pathname names no archive of Example 1[.]0\n/
        ],
        [ { tests    => '[]' },        qr/\AExample: tests is no command\n/ ],
        [ { build    => '["make"]' },  qr/\AExample: build is no list of commands\n/ ],
        [ { options  => '"--shard"' }, qr/\AExample: options is no list of words\n/ ],
        [ { mutants  => '[5, 3]' },    qr/\AExample: mutants is no band\n/ ],
        [ { score    => '[40]' },      qr/\AExample: score is no band\n/ ],
        [ { warnings => '["loud"]' },  qr/\AExample: no kind of warning is named loud\n/ ],
        [ { seconds  => undef },       qr/\AExample needs seconds\n/ ],
        [ { shard    => '"1/2"' },     qr/\AExample has no field named shard\n/ ],
    );
    like dies { RealWorld::runs( table( $_->[0]->%* ) ) }, $_->[1], 'refused: ' . join q{, }, sort keys $_->[0]->%*
      for @refused;

    my $other = $TABLE =~ s/\[Example/[Other/gr =~ s/sha256 = "a/sha256 = "b/r;
    like dies { RealWorld::runs( $TABLE . $other ) }, qr/\AOther names another digest for the archive of Example\n/,
      'two runs of one archive agree on its digest';
    like dies { RealWorld::runs('[Example') }, qr/\Athe table of the runs does not parse: /,
      'a broken table is refused';
};

subtest 'the observation of a run is read from what the tools print' => sub {
    is RealWorld::announced( [ 'noise', '80 mutants in 1 file, 11 tests' ] ),
      { mutants => 80, files => 1, tests => 11 },
      'the line that announces the run';
    is RealWorld::announced( ['1 mutant in 2 files, 1 test'] ), { mutants => 1, files => 2, tests => 1 },
      'the singular forms';
    is RealWorld::announced( ['mutation: cannot copy the project'] ), undef, 'a run that announces nothing';

    is RealWorld::harness("t/a.t .. ok\nAll tests successful.\nFiles=11, Tests=365,  0 wallclock secs\nResult: PASS\n"),
      { files => 11, tests => 365 }, 'the summary line of the test harness';
    is RealWorld::harness("Can't locate Module/Build.pm\n"), undef, 'an output without a summary';

    is RealWorld::warning_kind('t/a.t loads lib/A.pm around the hook and cannot detect its mutants'), 'around-the-hook',
      'a load around the hook';
    is RealWorld::warning_kind(
        'lib/A.pm: Perl decompiles the file to no stable text, so the run compares no compiled code of the file'),
      'no-stable-output', 'an unstable output of B::Deparse';
    is RealWorld::warning_kind('no test files match'), 'other', 'any other warning';

    my @lines = (
        '6 processors in the quota of the control group',
        '18 processors online',
        '4 processors in the affinity of the process',
        '1 processor by default',
        '80 mutants in 1 file, 11 tests',
        'The unmodified run passed: 11 tests, 6 jobs',
        '[ 8/80] 8 killed',
        '[80/80]',
        q{},
        'Use of uninitialized value in join',
        '6 processors in the quota of a container',
        'mutation: tests that fail without a mutant: 1',
    );
    is RealWorld::unexpected_lines( \@lines, 0 ),
      [
        'Use of uninitialized value in join',
        '6 processors in the quota of a container',
        'mutation: tests that fail without a mutant: 1'
      ],
      'every line outside the progress of a run, the count of processors with its source included';
    is RealWorld::unexpected_lines( \@lines, 3 ),
      [ 'Use of uninitialized value in join', '6 processors in the quota of a container' ],
      'and a run that fails ends with the one line of the tool that its manual promises';
    is RealWorld::unexpected_lines( [ 'mutation: first', 'mutation: second' ], 4 ), ['mutation: first'],
      'which comes once, at the end';

    my $source   = "package A;\nsub sum { return \$_[0] + \$_[1] }\nsub none {\n    return;\n}\n1;\n";
    my $document = {
        files => {
            'lib/A.pm' => {
                source  => $source,
                mutants => [
                    {
                        id           => 'b2',
                        mutatorName  => 'statement-removal',
                        description  => 'removed the statement',
                        replacement  => q{},
                        status       => 'NoCoverage',
                        coveredBy    => [],
                        location     => { start  => { line => 3, column => 11 }, end    => { line => 5, column => 1 } },
                        testMutation => { status => 'NoCoverage',                reason => 'unreached' },
                    },
                    {
                        id           => 'a1',
                        mutatorName  => 'arithmetic',
                        description  => 'replaced + with -',
                        replacement  => q{-},
                        status       => 'Killed',
                        statusReason => 'a sentence',
                        coveredBy    => [ 't/a.t', 't/b.t' ],
                        killedBy     => ['t/b.t'],
                        location     => { start  => { line => 2, column => 24 }, end => { line => 2, column => 25 } },
                        testMutation => { status => 'Killed',                    reason => undef },
                    },
                    {
                        id           => 'c3',
                        mutatorName  => 'arithmetic',
                        description  => 'replaced + with -',
                        replacement  => q{-},
                        status       => 'Ignored',
                        statusReason => 't/a.t exceeded its time limit',
                        coveredBy    => ['t/a.t'],
                        location     => { start  => { line => 2, column => 24 }, end => { line => 2, column => 25 } },
                        testMutation => { status => 'Timeout',                   reason => 'time-limit' },
                    },
                ],
            },
        },
        testMutation => {
            jobs             => 6,
            shard            => '1/2',
            warnings         => ['no test files match'],
            problems         => [ { path => 'lib/B.pm', problem => 'no parse' } ],
            baselineFailures => ['t/c.t'],
            tests            => [ { name => 't/a.t', duration => 0.1 }, { name => 't/b.t', duration => 0.2 } ],
        },
    };
    is RealWorld::report($document),
      {
        jobs              => 6,
        shard             => '1/2',
        warnings          => ['no test files match'],
        skipped           => ['lib/B.pm: no parse'],
        baseline_failures => ['t/c.t'],
        tests             => 2,
        mutants           => [
            {
                id          => 'a1',
                file        => 'lib/A.pm',
                line        => 2,
                column      => 24,
                mutator     => 'arithmetic',
                description => 'replaced + with -',
                status      => 'Killed',
                reason      => undef,
                detail      => 'a sentence',
                original    => q{+},
                replacement => q{-},
                source      => 'sub sum { return $_[0] + $_[1] }',
                covered_by  => 2,
                killed_by   => 't/b.t',
            },
            {
                id          => 'c3',
                file        => 'lib/A.pm',
                line        => 2,
                column      => 24,
                mutator     => 'arithmetic',
                description => 'replaced + with -',
                status      => 'Timeout',
                reason      => 'time-limit',
                detail      => 't/a.t exceeded its time limit',
                original    => q{+},
                replacement => q{-},
                source      => 'sub sum { return $_[0] + $_[1] }',
                covered_by  => 1,
                killed_by   => undef,
            },
            {
                id          => 'b2',
                file        => 'lib/A.pm',
                line        => 3,
                column      => 11,
                mutator     => 'statement-removal',
                description => 'removed the statement',
                status      => 'NoCoverage',
                reason      => 'unreached',
                detail      => undef,
                original    => "\n    return;\n",
                replacement => q{},
                source      => 'sub none {',
                covered_by  => 0,
                killed_by   => undef,
            },
        ],
      },
      'the report of a run, with the status of the run that the schema writes another way for a timeout';

    is RealWorld::tally( [ map { { status => $_ } } qw(Killed Killed Survived NoCoverage Timeout Ignored) ] ),
      {
        counts => { Killed => 2, Survived => 1, NoCoverage => 1, Timeout => 1, Ignored => 1 },
        total  => 6,
        score  => 50
      },
      'the counts and the score, which leaves out a timeout and an ignored mutant';
    is RealWorld::tally( [ { status => 'Timeout' } ] )->{score}, undef, 'a run without a valid mutant has no score';

    my @mutants = map {
        { id => $_->[0], file => 'lib/A.pm', line => $_->[1], column => 1, mutator => $_->[2], status => 'Survived' }
    } [ 'a', 1, 'arithmetic' ], [ 'b', 2, 'arithmetic' ], [ 'c', 3, 'comparison' ], [ 'd', 4, 'logical' ];
    is [ map { $_->{id} } RealWorld::sample( [ reverse @mutants ], 'Survived', 3 )->@* ], [ 'a', 'c', 'd' ],
      'a sample takes one mutant of each mutator before a second one of any';
    is RealWorld::sample( \@mutants, 'Killed', 3 ), [], 'a status without a mutant gives an empty sample';

    my $lines = qq[{"run":"A","sha256":"x"}\n{"run":"B","sha256":"y"}\n];
    is RealWorld::records($lines), { A => { run => 'A', sha256 => 'x' }, B => { run => 'B', sha256 => 'y' } },
      'the records of a run file, by the name of the run';
    like dies { RealWorld::records( $lines . qq[{"run":"A"}\n] ) }, qr/\Aline 3 repeats the run A\n/,
      'a repeated run is refused';
    like dies { RealWorld::records("not a record\n") }, qr/\Aline 1 is no record\n/,
      'a line without a record is refused';
};

my @KINDS    = RealWorld::kinds();
my ($RUN)    = RealWorld::runs($TABLE)->@*;
my $BANDLESS = { $RUN->%*, expect => { $RUN->{expect}->%*, score => undef } };
my $LOADS    = 't/a.t loads lib/Example.pm around the hook and cannot detect its mutants';
my $UNSTABLE =
  'lib/Example.pm: Perl decompiles the file to no stable text, so the run compares no compiled code of the file';

sub record () {
    my $tests =
      { command => [ 'prove', '-lr', 't' ], exit => 0, seconds => 1, files => 2, assertions => 7, tail => [] };
    my @mutants = map { { id => "m$_", file => 'lib/Example.pm', status => $_ < 2 ? 'Killed' : 'Survived' } } 0 .. 3;
    return copy(
        {
            run      => 'Example',
            sha256   => 'a' x 64,
            tests    => $tests,
            prove    => $tests,
            mutation => {
                exit    => 0,
                seconds => 2,
                limit   => 0,
                scratch => 12,
                stdout  => [],
                stderr  =>
                  [ '4 mutants in 1 file, 2 tests', 'The unmodified run passed: 2 tests, 6 jobs', '[4/4] 2 killed' ],
            },
            report => {
                jobs              => 6,
                shard             => undef,
                warnings          => [],
                skipped           => [],
                baseline_failures => [],
                tests             => 2,
                mutants           => \@mutants
            },
        }
    );
}

subtest 'the reference judge compares command exits with the completed observations' => sub {
    my $mismatch = 'Example: the exit status disagrees with the report';
    for my $case (
        [ [qw(CompileError)],         [],                  0 ],
        [ [qw(CompileError Timeout)], [],                  4 ],
        [ [qw(Killed Pending)],       [],                  4 ],
        [ [qw(Killed)],               ['lib/Unparsed.pm'], 4 ],
      )
    {
        my ( $statuses, $skipped, $expected ) = @$case;
        my $record = record();
        $record->{report}{mutants} =
          [ map { { id => "m$_", file => 'lib/Example.pm', status => $_, reason => 'compile-phase' } } @$statuses ];
        $record->{report}{skipped} = $skipped;
        for my $status ( 0, 4 ) {
            $record->{mutation}{exit} = $status;
            my @found = grep { $_ eq $mismatch } RealWorld::findings( $RUN, $record )->@*;
            is \@found, $status == $expected ? [] : [$mismatch],
              "the exit for @$statuses and " . scalar(@$skipped) . " skipped sources is $expected";
        }
    }
};

# A run that stops at its unmodified tests announces its mutants and gives none of them a status.
sub stopped ($record) {
    $record->{report}{baseline_failures} = ['t/a.t'];
    $record->{report}{mutants}           = [];
    $record->{mutation}{exit}            = 3;
    $record->{mutation}{stderr}          = ['4 mutants in 1 file, 2 tests'];
    return;
}

my $PINNED   = { $RUN->%*, hash_seed => '01' };
my @REJECTED = (
    [ $RUN, sub ($r) { $r->{sha256} = 'b' x 64 }, ['the record belongs to another archive'] ],
    [
        $PINNED,
        sub ($r) { $r->{environment} = { PERL_HASH_SEED => '02', PERL_PERTURB_KEYS => '0' } },
        ['the record uses another Perl hash traversal']
    ],
    [
        $PINNED, sub ($r) { $r->{environment} = { PERL_HASH_SEED => '01' } },
        ['the record uses another Perl hash traversal']
    ],
    [
        $RUN,
        sub ($r) { $r->{tests}{exit} = 1 },
        [
            'the tests of the distribution fail without the tool',
            'the unmodified run passes where the tests of the distribution fail'
        ],
    ],
    [ $BANDLESS, \&stopped, ['the unmodified run fails where the tests of the distribution pass'] ],
    [
        $BANDLESS,
        sub ($r) { $r->{mutation}->@{qw(limit exit)} = ( 1, 143 ); $r->{report} = undef },
        [ 'the run ends at the time limit of the harness', 'the run leaves no report' ],
    ],
    [
        $BANDLESS,
        sub ($r) {
            $r->{mutation}{exit} = 4;
            $r->{report} = undef;
            push $r->{mutation}{stderr}->@*, 'mutation: no room';
        },
        ['the run leaves no report'],
    ],
    [ $RUN, sub ($r) { $r->{mutation}{scratch} = 257 }, ['the run fills its scratch space'] ],
    [ $RUN, sub ($r) { $r->{mutation}{exit}    = 1 },   ['the exit status disagrees with the report'] ],
    [
        $RUN,
        sub ($r) { $r->{report}{mutants}[3]{status} = 'CompileError' },
        ['the compile errors differ from the expected mutants or causes']
    ],
    [
        $RUN,
        sub ($r) { $r->{report}{mutants}[3]{status} = 'NoVerdict'; $r->{mutation}{exit} = 4 },
        ['the run reports a mutant without a verdict'],
    ],
    [
        $RUN,
        sub ($r) { $r->{report}{mutants}[3]{status} = 'Pending'; $r->{mutation}{exit} = 4 },
        ['the run leaves a mutant pending']
    ],
    [
        $RUN,
        sub ($r) { $r->{report}{warnings} = [$LOADS] },
        ['the run warns that a test loads a source around the hook']
    ],
    [
        $RUN,
        sub ($r) { $r->{report}{warnings} = [$UNSTABLE] },
        ['the run warns that B::Deparse gives no stable output']
    ],
    [
        $RUN,
        sub ($r) { $r->{report}{warnings} = ['lib/App.pm does not pass a standalone syntax check'] },
        ['the run warns that a source requires its application to compile']
    ],
    [
        $RUN,
        sub ($r) { $r->{report}{warnings} = ['no test files match'] },
        ['the run gives a warning of another kind']
    ],
    [
        $RUN,
        sub ($r) { $r->{report}{skipped} = ['lib/B.pm: no parse']; $r->{mutation}{exit} = 4 },
        ['the run skips a source file']
    ],
    [
        $RUN,
        sub ($r) { push $r->{mutation}{stderr}->@*, 'Use of uninitialized value' },
        ['the run writes an unexpected line to standard error'],
    ],
    [
        $RUN,
        sub ($r) { $r->{mutation}{stderr}[0] = '9 mutants in 1 file, 2 tests' },
        ['the number of mutants lies outside its band']
    ],
    [ $RUN, sub ($r) { shift $r->{mutation}{stderr}->@* }, ['the number of mutants lies outside its band'] ],
    [ $RUN, sub ($r) { $_->{status} = 'Survived' for $r->{report}{mutants}->@* }, ['the score lies outside its band'] ],
    [ $BANDLESS, sub ($r) { }, ['the run gives a score, and the table states no band for it'] ],
    [
        $RUN,
        sub ($r) { $r->{prove} = { $r->{prove}->%*, files => 3 } },
        ['the run finds another number of test files than prove']
    ],
);

subtest 'the judge rejects an observation outside the expectation of its run' => sub {
    is RealWorld::findings( $RUN, record() ), [], 'an observation inside every expectation gives no finding';
    is RealWorld::findings( $RUN, undef ),    ['Example: the run has no record'], 'a run without a record';

    my %rejected = ( 'the run has no record' => 1 );
    for my $case (@REJECTED) {
        my ( $run, $change, $kinds ) = $case->@*;
        my $record = record();
        $change->($record);
        is RealWorld::findings( $run, $record ), [ map { "Example: $_" } $kinds->@* ], "rejected: $kinds->[-1]";
        $rejected{$_} = 1 for $kinds->@*;
    }
    is [ sort keys %rejected ], [ sort @KINDS ], 'every kind of finding has an observation that the judge rejects';

    my $listed =
      { $RUN->%*, expect => { $RUN->{expect}->%*, warnings => [ 'around-the-hook', 'no-stable-output', 'other' ] } };
    my $warned = record();
    $warned->{report}{warnings} = [ $LOADS, $UNSTABLE, 'no test files match' ];
    is RealWorld::findings( $listed, $warned ), [], 'a warning of a kind that the run lists gives no finding';

    my $id       = '5ebd8caa0236';
    my $expected = { %$RUN, expect => { $RUN->{expect}->%*, compile => { $id => 'compile-phase' } } };
    my $compiled = record();
    $compiled->{report}{mutants}[3]->@{qw(id status reason)} = ( $id, 'CompileError', 'compile-phase' );
    is RealWorld::findings( $expected, $compiled ), [], 'a known compile-time exception has its expected cause';
    $compiled->{report}{mutants}[3]{reason} = 'parse';
    $compiled->{mutation}{exit} = 6;
    is RealWorld::findings( $expected, $compiled ),
      ['Example: the compile errors differ from the expected mutants or causes'],
      'the same ID with invalid code fails the gate even when the exit status is correct';

    my $agreed = record();
    stopped($agreed);
    $agreed->{tests}{exit} = 1;
    is RealWorld::findings( $BANDLESS, $agreed ), ['Example: the tests of the distribution fail without the tool'],
      'an unmodified run that fails as the tests do agrees with them';

    my $other = { record()->%*, run => 'Other' };
    is RealWorld::judged( [$RUN], { Example => record(), Other => $other } ),
      ['Other: the table has no run for the record'], 'a record that names no run of the table';
    is RealWorld::judged( [ $RUN, { $RUN->%*, run => 'Other' } ], { Other => $other } ),
      ['Example: the run has no record'], 'the findings of every run, in the order of the table';
    is RealWorld::summary( record() ), 'exit 0; 4 mutants, 2 tests; 2 Killed, 2 Survived; score 50.0; 2 s; 12 MB',
      'one line about a run';

    my $fewer = record();
    $fewer->{prove}{files} = 3;
    is RealWorld::findings( { $RUN->%*, config => "test-exclude = [\"t/c.t\"]\n" }, $fewer ), [],
      'a run whose configuration chooses the test files may find another number of them than prove';

    my $slow = record();
    $slow->{mutation}{seconds} = 61;
    is RealWorld::findings( $RUN, $slow ), [], 'a run over its time gives no finding';
    like RealWorld::notes( $RUN, $slow ), bag { item match qr/\Athe run took 61 s, over the 60 s of the table\z/; etc },
      'and the notes name the time';
    my $split = record();
    $split->{prove} = { $split->{prove}->%*, exit => 1 };
    like RealWorld::notes( $RUN, $split ),
      bag { item match qr/\Aprove -lr t fails where the tests of the table pass\z/; etc },
      'the notes name a plain prove that disagrees with the tests of the table';
};

open my $handle, '<:encoding(UTF-8)', 'xt/realworld/distributions.toml' or die "read the table: $!";
my $runs = RealWorld::runs( do { local $/ = undef; readline $handle } );
close $handle or die "close the table: $!";
my %archives = map { $_->{pathname} => 1 } $runs->@*;
Gate::checked( 'runs of the table',                            scalar $runs->@*,      at_least => 11 );
Gate::checked( 'distributions of the table',                   scalar keys %archives, at_least => 8 );
Gate::checked( 'kinds of finding with a rejected observation', scalar @KINDS,         at_least => 21 );

done_testing;
