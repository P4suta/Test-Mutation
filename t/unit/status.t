use v5.36;
use Test2::V0;
use Test::Mutation::Status;
use Test::Mutation::Types qw(Entry Reason StatusName);

# The rows of the catalog as the readers of the reports, the score, and the cache rely on them.
my @EXPECTED = (
    [ 'Killed',   'Killed',   'killed',   undef,      'detected',   1, undef,     1, [] ],
    [ 'Survived', 'Survived', 'survived', 'Survived', 'undetected', 1, 'warning', 1, [] ],
    [
        'NoCoverage', 'NoCoverage', 'no coverage', 'No coverage', 'undetected', 1, 'warning', 0,
        [qw(unreached not-loaded)]
    ],
    [ 'Timeout', 'Ignored', 'timeout', 'Timeout', 'outside', 1, 'notice', 0, [qw(time-limit output-limit)] ],
    [
        'CompileError', 'CompileError', 'compile error',
        undef, 'outside', 1, undef, 1, [qw(parse compile-phase standalone)]
    ],
    [
        'NoVerdict',
        'RuntimeError',
        'no verdict',
        'No verdict',
        'outside',
        1, undef, 0,
        [
            qw(loaded-around-hook outside-copy no-record shim-error unstable-test conflicting-test project-changed),
            qw(build-copy-not-updated slot-not-restored)
        ]
    ],
    [
        'Ignored', 'Ignored', 'ignored', undef, 'outside', 0, undef, 1,
        [qw(suppressed same-code-as-original same-code-as-mutant)]
    ],
    [ 'Pending', 'Pending', 'pending', undef, 'outside', 0, undef, 0, ['interrupted'] ],
);
my @COLUMNS = qw(name schema word heading role progress annotation cached reasons);

my @rows = Test::Mutation::Status::rows()->@*;

subtest 'the catalog holds every status once, in the order of the reports' => sub {
    my @columns;
    for my $row (@rows) {
        push @columns, [ map { $row->$_ } @COLUMNS ];
    }
    is \@columns,                       \@EXPECTED,                    'every column of every row';
    is Test::Mutation::Status::names(), [ map { $_->[0] } @EXPECTED ], 'the names';
    ok( ( !grep { !length $_->description } @rows ), 'every status has a description' );
    my %described = map { $_->description => 1 } @rows;
    is scalar( keys %described ), scalar @rows, 'each description is its own';
};

subtest 'the schema name of every status is a status of the report schema' => sub {
    my %schema = map { $_ => 1 } qw(Killed Survived NoCoverage CompileError RuntimeError Timeout Ignored Pending);
    is [ grep { !$schema{ $_->schema } } @rows ],       [],             'no other name';
    is Test::Mutation::Status::of('Timeout')->schema,   'Ignored',      'a timeout is ignored in the schema';
    is Test::Mutation::Status::of('NoVerdict')->schema, 'RuntimeError', 'a mutant without a verdict is a runtime error';
};

subtest 'of returns the row of a name and refuses another name' => sub {
    is Test::Mutation::Status::of($_)->name, $_, "the row of $_" for map { $_->[0] } @EXPECTED;
    like dies { Test::Mutation::Status::of('RuntimeError') }, qr/did not pass type constraint/,
      'a name of the schema alone';
    like dies { Test::Mutation::Status::of('Dead') }, qr/did not pass type constraint/, 'an unknown name';
};

subtest 'a status other than Killed and Survived needs a reason of its own list' => sub {
    my @fitting;
    for my $row (@rows) {
        push @fitting, map { [ $row->name, $_ ] } $row->reasons->@* ? $row->reasons->@* : (undef);
    }
    is [ grep { !Test::Mutation::Status::fits( $_->@* ) } @fitting ], [], 'every reason of the catalog fits its status';
    is scalar @fitting,                                               22, 'the pairs of a status and a reason';
    my @wrong = (
        [ 'Killed',     'time-limit' ],
        [ 'Survived',   'unreached' ],
        [ 'NoCoverage', undef ],
        [ 'Timeout',    'unreached' ],
        [ 'NoVerdict',  'time-limit' ],
        [ 'NoVerdict',  'output-limit' ],
        [ 'Pending',    undef ],
    );
    is [ grep { Test::Mutation::Status::fits( $_->@* ) } @wrong ], [],
      'a reason of another status, and a missing reason';
};

subtest 'the shared types name the statuses, the reasons, and the entries of a result' => sub {
    ok StatusName->check($_),              "the status $_" for map { $_->[0] } @EXPECTED;
    ok !StatusName->check('RuntimeError'), 'a name of the schema alone is no status';
    is [ grep { !Reason->check($_) } map { $_->reasons->@* } @rows ], [], 'every reason';
    ok !Reason->check('slow'), 'no other reason';
    my %entry = (
        mutant     => bless( {}, 'Test::Mutation::Mutant' ),
        status     => 'Timeout',
        reason     => 'time-limit',
        detail     => 't/a.t exceeded its time limit',
        by         => 't/a.t',
        covered_by => ['t/a.t'],
        tests_run  => 1,
        duration   => 2,
    );
    ok Entry->check( \%entry ),                            'an entry with a reason of its status';
    ok !Entry->check( { %entry, reason => undef } ),       'an entry without its reason';
    ok !Entry->check( { %entry, reason => 'unreached' } ), 'an entry with the reason of another status';
    ok Entry->check( { %entry, status => 'Killed', reason => undef, detail => undef } ), 'a killed mutant without one';
};

done_testing;
