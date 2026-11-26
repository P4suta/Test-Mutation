use v5.36;
use Test2::V0;
use Test::Mutation::Score;
use Test::Mutation::Verdict;

sub outcome (%fields) {
    return {
        test        => 't/a.t',
        result      => 'pass',
        served      => 1,
        load_failed => 0,
        bypassed    => 0,
        syntax      => undef,
        %fields
    };
}

sub folded (@outcomes) {
    my $state = Test::Mutation::Verdict::start();
    $state = Test::Mutation::Verdict::step( $state, $_ ) for @outcomes;
    return $state;
}

sub verdict (@outcomes) {
    return Test::Mutation::Verdict::final( folded(@outcomes) );
}

# The status and the reason of the concluded state, as one text.
sub decided (@outcomes) {
    my $state = Test::Mutation::Verdict::conclude( folded(@outcomes) );
    return join q{ }, grep { defined } $state->@{qw(status reason)};
}

subtest 'two completed attempts name their evidence and count every test process' => sub {
    my $pass     = Test::Mutation::Verdict::conclude( folded( outcome(), outcome( test => 't/b.t' ) ) );
    my $a        = folded( outcome( result => 'fail' ) );
    my $b        = folded( outcome(), outcome( test => 't/b.t', result => 'fail' ) );
    my $lost     = folded( outcome( test => 't/c.t', bypassed => 1 ) );
    my $limited  = Test::Mutation::Verdict::conclude( folded( outcome( result => 'timeout' ) ) );
    my $unloaded = Test::Mutation::Verdict::conclude( folded( outcome( served => 0 ) ) );
    for my $case (
        [ $pass, $pass,     'Survived',  undef,                4 ],
        [ $a,    $a,        'Killed',    undef,                2 ],
        [ $b,    $b,        'Killed',    undef,                4 ],
        [ $pass, $a,        'NoVerdict', 'unstable-test',      3 ],
        [ $a,    $pass,     'NoVerdict', 'unstable-test',      3 ],
        [ $a,    $b,        'NoVerdict', 'unstable-test',      3 ],
        [ $b,    $a,        'NoVerdict', 'unstable-test',      3 ],
        [ $a,    $lost,     'NoVerdict', 'loaded-around-hook', 2 ],
        [ $pass, $limited,  'NoVerdict', 'unstable-test',      3 ],
        [ $pass, $unloaded, 'NoVerdict', 'unstable-test',      3 ],
      )
    {
        my ( $first, $repeat, @expected ) = $case->@*;
        my $state = Test::Mutation::Verdict::confirm( $first, $repeat );
        is [ $state->@{qw(status reason tests)} ], \@expected, "$first->{status} then $repeat->{status}";
    }
    is Test::Mutation::Verdict::confirm( $a, $b )->{detail},
      't/a.t failed on the first run, t/b.t failed on the second run', 'two different detecting tests';
    is Test::Mutation::Verdict::confirm( $pass, $unloaded )->{detail},
      'the covering tests passed on the first run, NoCoverage on the second run', 'coverage disappeared';
    is Test::Mutation::Verdict::confirm( $a, $lost )->{detail},
      't/a.t failed on the first run, t/c.t loaded the target without the hook on the second run',
      'a more specific anomaly keeps its cause and both observations';
    is $a->{tests}, 1, 'the first observation stays available';
    is $b->{tests}, 2, 'the second observation stays available';
};

subtest 'single outcomes over the whole input domain' => sub {
    my @rows;
    my %limit = ( timeout => 'time-limit', overflow => 'output-limit' );
    for my $result (qw(pass fail timeout overflow)) {
        for my $served ( 0, 1 ) {
            for my $load_failed ( 0, 1 ) {
                for my $bypassed ( 0, 1 ) {
                    for my $syntax (qw(ok compile-phase standalone)) {
                        my $expected =
                            $bypassed                       ? 'NoVerdict loaded-around-hook'
                          : $limit{$result} && $served      ? "Timeout $limit{$result}"
                          : $limit{$result}                 ? 'NoVerdict unstable-test'
                          : !$served                        ? 'NoCoverage not-loaded'
                          : $load_failed && $syntax ne 'ok' ? "CompileError $syntax"
                          : $result eq 'fail'               ? 'Killed'
                          :                                   'Survived';
                        my $got = decided(
                            outcome(
                                result      => $result,
                                served      => $served,
                                load_failed => $load_failed,
                                bypassed    => $bypassed,
                                syntax      => $syntax,
                            )
                        );
                        push @rows,
                          "$result served=$served load_failed=$load_failed bypassed=$bypassed syntax=$syntax: $got"
                          if $got ne $expected;
                    }
                }
            }
        }
    }
    is \@rows, [], 'every combination yields the specified status and reason';
};

subtest 'a reproduced failure can detect a source that the test reads as data' => sub {
    my %unloaded = ( result => 'fail', served => 0, syntax => 'ok' );
    is decided( outcome( %unloaded, read_check => 'fail' ) ),    'Killed', 'two failed reads detect the change';
    is decided( outcome( %unloaded, read_check => 'pass' ) ),    'NoVerdict unstable-test', 'the second read passed';
    is decided( outcome( %unloaded, read_check => 'timeout' ) ), 'NoVerdict unstable-test', 'the second read timed out';
    is decided( outcome( %unloaded, read_check => 'overflow' ) ), 'NoVerdict unstable-test',
      'the second read exceeded its output limit';
    is decided( outcome( %unloaded, syntax => 'compile-phase', read_check => 'compile-error' ) ),
      'CompileError compile-phase',
      'only the changed source failed to compile';
    is decided( outcome( %unloaded, syntax => 'standalone', read_check => 'fail' ) ), 'Killed',
      'an unmodified source that also fails standalone can still be tested as data';
};

subtest 'sequences' => sub {
    is decided(), 'NoCoverage unreached', 'no test at all';
    is decided( outcome( served => 0 ), outcome( served => 0, result => 'fail' ) ), 'NoCoverage not-loaded',
      'failures of tests that never loaded the mutant say nothing';
    is verdict( outcome(), outcome() ), 'Survived',                                         'every loading test passes';
    is verdict( outcome( served => 0 ), outcome(), outcome( result => 'fail' ) ), 'Killed', 'a later test detects it';
    is verdict( outcome( result => 'fail' ), outcome( bypassed => 1 ) ),          'Killed', 'a decided verdict stays';
    is verdict(
        outcome( load_failed => 1, syntax => 'ok' ),
        outcome( result => 'fail', load_failed => 1, syntax => 'ok' )
      ),
      'Killed', 'a load failure that a test tolerates leaves the decision to later tests';
};

subtest 'a timeout waits for a later test to decide' => sub {
    my %timeout = ( result => 'timeout' );
    is verdict( outcome(%timeout), outcome( result => 'fail' ) ), 'Killed',  'a later failure detects the mutant';
    is verdict( outcome(%timeout), outcome() ),                   'Timeout', 'a later pass leaves the timeout';
    is verdict( outcome(%timeout), outcome( served => 0, result => 'fail' ) ), 'Timeout',
      'a failure of a test that never loaded the mutant leaves the timeout';
    is decided( outcome(%timeout), outcome( load_failed => 1, syntax => 'compile-phase' ) ),
      'CompileError compile-phase', 'a later compile error decides';
    is decided( outcome(%timeout), outcome( bypassed => 1 ) ), 'NoVerdict loaded-around-hook', 'a later bypass decides';
    is verdict( outcome(%timeout), outcome(%timeout), outcome( result => 'fail' ) ), 'Timeout',
      'the second timeout ends the work';
    is verdict( outcome(%timeout), outcome(), outcome(%timeout), outcome( result => 'fail' ) ), 'Timeout',
      'also with a pass between the two';

    my %early = ( result => 'timeout', served => 0 );
    is verdict( outcome(%early), outcome( result => 'fail' ) ), 'Killed', 'a failure after a timeout before the load';
    is decided( outcome(%early), outcome() ), 'NoVerdict unstable-test',
      'a pass leaves the timeout before the load unexplained';
    is verdict( outcome(%early), outcome(%timeout) ), 'Timeout',
      'a timeout after the load says more than one before it';
    is verdict( outcome(%timeout), outcome(%early) ), 'Timeout', 'in either order';

    my $twice = sub ( $first, $later ) {
        my $state = Test::Mutation::Verdict::start();
        $state = Test::Mutation::Verdict::step( $state, outcome( test => 't/first.t',  $first->%* ) );
        $state = Test::Mutation::Verdict::step( $state, outcome( test => 't/second.t', $later->%* ) );
        return [ $state->@{qw(status reason by detail)} ];
    };
    is $twice->( \%timeout, \%timeout ),
      [ 'Timeout', 'time-limit', 't/first.t', 't/first.t exceeded its time limit' ],
      'two timeouts after the load name the first test';
    is $twice->( \%early, \%early ),
      [ 'NoVerdict', 'unstable-test', 't/first.t', 't/first.t exceeded its time limit before it loaded the mutant' ],
      'two timeouts before the load name the first test';
    is $twice->( \%early, \%timeout ),
      [ 'Timeout', 'time-limit', 't/second.t', 't/second.t exceeded its time limit' ],
      'a timeout after the load takes the place of one before it';
    is $twice->( \%timeout, \%early ),
      [ 'Timeout', 'time-limit', 't/first.t', 't/first.t exceeded its time limit' ],
      'and keeps its place against a later one before the load';

    my %overflow = ( result => 'overflow' );
    is $twice->( \%overflow, \%timeout ),
      [ 'Timeout', 'output-limit', 't/first.t', 't/first.t exceeded its output limit' ],
      'a test that the output limit ended counts as a timeout, with the reason of its own limit';
    is $twice->( { %timeout, served => 0 }, \%overflow ),
      [ 'Timeout', 'output-limit', 't/second.t', 't/second.t exceeded its output limit' ],
      'and takes the place of a time limit before the load';
    is [ map { Test::Mutation::Verdict::limit($_) } qw(timeout overflow pass fail) ],
      [ 'time-limit', 'output-limit', undef, undef ], 'the reason of each limit, and none for a test that ended';
    is $twice->( { %overflow, served => 0 }, { %overflow, served => 0 } ),
      [ 'NoVerdict', 'unstable-test', 't/first.t', 't/first.t exceeded its output limit before it loaded the mutant' ],
      'also before the load';
    is verdict( outcome(%overflow), outcome( result => 'fail' ) ), 'Killed', 'and a later failure detects the mutant';

    my $state = Test::Mutation::Verdict::start();
    $state = Test::Mutation::Verdict::step( $state, outcome( test => 't/slow.t', %timeout ) );
    is [ $state->@{qw(status tests)} ], [ undef, 1 ], 'the state stays open after the first timeout';
    is Test::Mutation::Verdict::conclude($state), hash {
        field status => 'Timeout';
        field reason => 'time-limit';
        field by     => 't/slow.t';
        field detail => 't/slow.t exceeded its time limit';
        etc
    }, 'the conclusion names the test that ran out of time';
    $state = Test::Mutation::Verdict::step( $state, outcome( test => 't/sure.t', result => 'fail' ) );
    is Test::Mutation::Verdict::conclude($state), hash {
        field status => 'Killed';
        field reason => undef;
        field by     => 't/sure.t';
        field detail => 't/sure.t failed';
        field tests  => 2;
        etc
    }, 'and after a failure the test that failed';
    is Test::Mutation::Verdict::conclude( Test::Mutation::Verdict::start() ),
      hash { field status => 'NoCoverage'; field reason => 'unreached'; field by => undef; etc },
      'a state without a decision concludes by what the tests loaded';
    is Test::Mutation::Verdict::conclude(
        Test::Mutation::Verdict::step( Test::Mutation::Verdict::start(), outcome() ) ),
      hash { field status => 'Survived'; field reason => undef; etc },
      'a loaded mutant that every test passes survives';
};

subtest 'a compile error names what failed to compile' => sub {
    is Test::Mutation::Verdict::conclude( folded( outcome( load_failed => 1, syntax => 'compile-phase' ) ) ), hash {
        field status => 'CompileError';
        field reason => 'compile-phase';
        field detail => 'the mutant does not compile';
        etc
    }, 'the mutant';
    is Test::Mutation::Verdict::conclude( folded( outcome( load_failed => 1, syntax => 'standalone' ) ) ), hash {
        field status => 'CompileError';
        field reason => 'standalone';
        field detail => 'the original source fails a syntax check of its own';
        etc
    }, 'the original source alone';
};

subtest 'pairs of outcomes over the whole input domain' => sub {
    my @domain;
    for my $bits ( 0 .. 7 ) {
        for my $syntax (qw(ok compile-phase standalone)) {
            for my $result (qw(pass fail timeout)) {
                push @domain,
                  outcome(
                    result      => $result,
                    served      => $bits & 1,
                    load_failed => $bits >> 1 & 1,
                    bypassed    => $bits >> 2 & 1,
                    syntax      => $syntax,
                  );
            }
        }
    }
    my $kind = sub ($o) {
        return
            $o->{bypassed}                            ? 'NoVerdict loaded-around-hook'
          : $o->{result} eq 'timeout'                 ? ( $o->{served} ? 'late' : 'early' )
          : !$o->{served}                             ? 'unloaded'
          : $o->{load_failed} && $o->{syntax} ne 'ok' ? "CompileError $o->{syntax}"
          : $o->{result} eq 'fail'                    ? 'Killed'
          :                                             'passed';
    };
    my $decides = sub ($kind) { return $kind =~ /\A(?:NoVerdict|CompileError|Killed)\b/ };
    my @wrong;
    for my $first (@domain) {
        for my $later (@domain) {
            my ( $one, $two ) = ( $kind->($first), $kind->($later) );
            my $expected =
                $decides->($one)                     ? $one
              : $decides->($two)                     ? $two
              : $one eq 'late' || $two eq 'late'     ? 'Timeout time-limit'
              : $one eq 'early' || $two eq 'early'   ? 'NoVerdict unstable-test'
              : $one eq 'passed' || $two eq 'passed' ? 'Survived'
              :                                        'NoCoverage not-loaded';
            my $got = decided( $first, $later );
            push @wrong, "$one then $two: $got, not $expected" if $got ne $expected;
        }
    }
    is \@wrong,            [],   'every pair yields the specified status and reason';
    is scalar(@domain)**2, 5184, 'the pairs of 72 outcomes';
};

subtest 'the state records the deciding test' => sub {
    my $state = Test::Mutation::Verdict::start();
    $state = Test::Mutation::Verdict::step( $state, outcome( test => 't/one.t' ) );
    $state = Test::Mutation::Verdict::step( $state, outcome( test => 't/two.t',   result => 'fail' ) );
    $state = Test::Mutation::Verdict::step( $state, outcome( test => 't/three.t', result => 'fail' ) );
    is $state->{by},    't/two.t', 'the deciding test';
    is $state->{tests}, 2,         'outcomes after the decision are not counted';
    like $state->{detail}, qr{t/two\.t failed}, 'the detail names the test';
};

subtest 'a load failure without a syntax check is a contract violation' => sub {
    like dies { verdict( outcome( load_failed => 1 ) ) }, qr/needs a syntax check/, 'refused';
};

subtest 'arguments are checked' => sub {
    like dies { Test::Mutation::Verdict::start('extra') }, qr/Wrong number of parameters/, 'start takes no argument';
    like dies { Test::Mutation::Verdict::step( {}, outcome() ) }, qr/did not pass type constraint/,
      'step needs a whole state';
    like dies { Test::Mutation::Verdict::step( Test::Mutation::Verdict::start(), { test => 't/a.t' } ) },
      qr/did not pass type constraint/, 'step needs a whole outcome';
    like dies { Test::Mutation::Verdict::step( Test::Mutation::Verdict::start(), outcome( syntax => 'parsed' ) ) },
      qr/did not pass type constraint/, 'a syntax check ends with ok or with the kind of a compile error';
    like dies { Test::Mutation::Verdict::final('state') }, qr/did not pass type constraint/, 'final needs a state';
    like dies { Test::Mutation::Verdict::conclude('state') }, qr/did not pass type constraint/,
      'conclude needs a state';
    like dies { Test::Mutation::Verdict::final() },    qr/Wrong number of parameters/, 'final takes one argument';
    like dies { Test::Mutation::Verdict::conclude() }, qr/Wrong number of parameters/, 'and so does conclude';
    like dies { Test::Mutation::Score::tally('Killed') }, qr/did not pass type constraint/,
      'tally needs a list of statuses';
    like dies { Test::Mutation::Score::tally( ['RuntimeError'] ) }, qr/did not pass type constraint/,
      'and a status of the catalog';
};

subtest 'score' => sub {
    my $tally =
      Test::Mutation::Score::tally(
        [qw(Killed Killed Killed Survived NoCoverage Timeout CompileError NoVerdict Ignored)] );
    is $tally->{total},             9,  'total';
    is $tally->{valid},             5,  'valid mutants';
    is $tally->{score},             60, 'score leaves out inconclusive and invalid mutants';
    is $tally->{counts}{Timeout},   1,  'timeouts are counted on their own';
    is $tally->{counts}{NoVerdict}, 1,  'and so are mutants without a verdict';
    is $tally->{counts}{Pending},   0,  'absent statuses count zero';
    is Test::Mutation::Score::tally( [qw(Timeout CompileError)] )->{score}, undef, 'no valid mutant, no score';
    is Test::Mutation::Score::tally( [] )->{score},                         undef, 'no mutant, no score';
    is Test::Mutation::Score::tally( [qw(Survived NoCoverage)] ),
      hash { field valid => 2; field score => 0; etc }, 'undetected mutants alone give a score of zero';
    is Test::Mutation::Score::tally( [qw(Killed)] ), hash { field valid => 1; field score => 100; etc },
      'a detected mutant alone gives the full score';
};

done_testing;
