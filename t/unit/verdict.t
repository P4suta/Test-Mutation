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
        syntax_ok   => undef,
        %fields
    };
}

sub verdict (@outcomes) {
    my $state = Test::Mutation::Verdict::start();
    $state = Test::Mutation::Verdict::step( $state, $_ ) for @outcomes;
    return Test::Mutation::Verdict::final($state);
}

subtest 'single outcomes over the whole input domain' => sub {
    my @rows;
    for my $result (qw(pass fail timeout)) {
        for my $served ( 0, 1 ) {
            for my $load_failed ( 0, 1 ) {
                for my $bypassed ( 0, 1 ) {
                    for my $syntax_ok ( 0, 1 ) {
                        my $expected =
                            $bypassed                       ? 'RuntimeError'
                          : $result eq 'timeout' && $served ? 'Timeout'
                          : $result eq 'timeout'            ? 'RuntimeError'
                          : !$served                        ? 'NoCoverage'
                          : $load_failed && !$syntax_ok     ? 'CompileError'
                          : $result eq 'fail'               ? 'Killed'
                          :                                   'Survived';
                        my $got = verdict(
                            outcome(
                                result      => $result,
                                served      => $served,
                                load_failed => $load_failed,
                                bypassed    => $bypassed,
                                syntax_ok   => $syntax_ok,
                            )
                        );
                        push @rows,
                          "$result served=$served load_failed=$load_failed bypassed=$bypassed syntax_ok=$syntax_ok: $got"
                          if $got ne $expected;
                    }
                }
            }
        }
    }
    is \@rows, [], 'every combination yields the specified status';
};

subtest 'sequences' => sub {
    is verdict(), 'NoCoverage', 'no test at all';
    is verdict( outcome( served => 0 ), outcome( served => 0, result => 'fail' ) ), 'NoCoverage',
      'failures of tests that never loaded the mutant say nothing';
    is verdict( outcome(), outcome() ), 'Survived',                                         'every loading test passes';
    is verdict( outcome( served => 0 ), outcome(), outcome( result => 'fail' ) ), 'Killed', 'a later test detects it';
    is verdict( outcome( result => 'fail' ), outcome( bypassed => 1 ) ),          'Killed', 'a decided verdict stays';
    is verdict(
        outcome( load_failed => 1, syntax_ok => 1 ),
        outcome( result => 'fail', load_failed => 1, syntax_ok => 1 )
      ),
      'Killed', 'a load failure that a test tolerates leaves the decision to later tests';
};

subtest 'a timeout waits for a later test to decide' => sub {
    my %timeout = ( result => 'timeout' );
    is verdict( outcome(%timeout), outcome( result => 'fail' ) ), 'Killed',  'a later failure detects the mutant';
    is verdict( outcome(%timeout), outcome() ),                   'Timeout', 'a later pass leaves the timeout';
    is verdict( outcome(%timeout), outcome( served => 0, result => 'fail' ) ), 'Timeout',
      'a failure of a test that never loaded the mutant leaves the timeout';
    is verdict( outcome(%timeout), outcome( load_failed => 1, syntax_ok => 0 ) ), 'CompileError',
      'a later compile error decides';
    is verdict( outcome(%timeout), outcome( bypassed => 1 ) ), 'RuntimeError', 'a later bypass decides';
    is verdict( outcome(%timeout), outcome(%timeout), outcome( result => 'fail' ) ), 'Timeout',
      'the second timeout ends the work';
    is verdict( outcome(%timeout), outcome(), outcome(%timeout), outcome( result => 'fail' ) ), 'Timeout',
      'also with a pass between the two';

    my %early = ( result => 'timeout', served => 0 );
    is verdict( outcome(%early), outcome( result => 'fail' ) ), 'Killed', 'a failure after a timeout before the load';
    is verdict( outcome(%early), outcome() ), 'RuntimeError', 'a pass leaves the timeout before the load unexplained';
    is verdict( outcome(%early), outcome(%timeout) ), 'Timeout',
      'a timeout after the load says more than one before it';
    is verdict( outcome(%timeout), outcome(%early) ), 'Timeout', 'in either order';

    my $twice = sub ( $first, $second ) {
        my $state = Test::Mutation::Verdict::start();
        $state = Test::Mutation::Verdict::step( $state, outcome( test => 't/first.t',  $first->%* ) );
        $state = Test::Mutation::Verdict::step( $state, outcome( test => 't/second.t', $second->%* ) );
        return [ $state->@{qw(status by reason)} ];
    };
    is $twice->( \%timeout, \%timeout ), [ 'Timeout', 't/first.t', 't/first.t exceeded its time limit' ],
      'two timeouts after the load name the first test';
    is $twice->( \%early, \%early ),
      [ 'RuntimeError', 't/first.t', 't/first.t exceeded its time limit before it loaded the mutant' ],
      'two timeouts before the load name the first test';
    is $twice->( \%early, \%timeout ), [ 'Timeout', 't/second.t', 't/second.t exceeded its time limit' ],
      'a timeout after the load takes the place of one before it';
    is $twice->( \%timeout, \%early ), [ 'Timeout', 't/first.t', 't/first.t exceeded its time limit' ],
      'and keeps its place against a later one before the load';

    my $state = Test::Mutation::Verdict::start();
    $state = Test::Mutation::Verdict::step( $state, outcome( test => 't/slow.t', %timeout ) );
    is [ $state->@{qw(status tests)} ], [ undef, 1 ], 'the state stays open after the first timeout';
    is Test::Mutation::Verdict::conclude($state), hash {
        field status => 'Timeout';
        field by     => 't/slow.t';
        field reason => 't/slow.t exceeded its time limit';
        etc
    }, 'the conclusion names the test that ran out of time';
    $state = Test::Mutation::Verdict::step( $state, outcome( test => 't/sure.t', result => 'fail' ) );
    is Test::Mutation::Verdict::conclude($state), hash {
        field status => 'Killed';
        field by     => 't/sure.t';
        field reason => 't/sure.t failed';
        field tests  => 2;
        etc
    }, 'and after a failure the test that failed';
    is Test::Mutation::Verdict::conclude( Test::Mutation::Verdict::start() ),
      hash { field status => 'NoCoverage'; field by => undef; etc },
      'a state without a decision concludes by what the tests loaded';
    is Test::Mutation::Verdict::conclude( Test::Mutation::Verdict::step( Test::Mutation::Verdict::start(), outcome() ) )
      ->{status},
      'Survived',
      'a loaded mutant that every test passes survives';
};

subtest 'pairs of outcomes over the whole input domain' => sub {
    my @domain = map {
        my $bits = $_;
        map {
            outcome(
                result      => $_,
                served      => $bits & 1,
                load_failed => $bits >> 1 & 1,
                bypassed    => $bits >> 2 & 1,
                syntax_ok   => $bits >> 3 & 1
            )
        } qw(pass fail timeout)
    } 0 .. 15;
    my $kind = sub ($o) {
        return
            $o->{bypassed}                        ? 'RuntimeError'
          : $o->{result} eq 'timeout'             ? ( $o->{served} ? 'late' : 'early' )
          : !$o->{served}                         ? 'unloaded'
          : $o->{load_failed} && !$o->{syntax_ok} ? 'CompileError'
          : $o->{result} eq 'fail'                ? 'Killed'
          :                                         'passed';
    };
    my %decides = map { $_ => 1 } qw(RuntimeError CompileError Killed);
    my @wrong;
    for my $first (@domain) {
        for my $second (@domain) {
            my ( $one, $two ) = ( $kind->($first), $kind->($second) );
            my $expected =
                $decides{$one}                       ? $one
              : $decides{$two}                       ? $two
              : $one eq 'late' || $two eq 'late'     ? 'Timeout'
              : $one eq 'early' || $two eq 'early'   ? 'RuntimeError'
              : $one eq 'passed' || $two eq 'passed' ? 'Survived'
              :                                        'NoCoverage';
            my $got = verdict( $first, $second );
            push @wrong, "$one then $two: $got, not $expected" if $got ne $expected;
        }
    }
    is \@wrong,            [],   'every pair yields the specified status';
    is scalar(@domain)**2, 2304, 'the pairs of 48 outcomes';
};

subtest 'the state records the deciding test' => sub {
    my $state = Test::Mutation::Verdict::start();
    $state = Test::Mutation::Verdict::step( $state, outcome( test => 't/one.t' ) );
    $state = Test::Mutation::Verdict::step( $state, outcome( test => 't/two.t',   result => 'fail' ) );
    $state = Test::Mutation::Verdict::step( $state, outcome( test => 't/three.t', result => 'fail' ) );
    is $state->{by},    't/two.t', 'the deciding test';
    is $state->{tests}, 2,         'outcomes after the decision are not counted';
    like $state->{reason}, qr{t/two\.t failed}, 'the reason names the test';
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
    like dies { Test::Mutation::Verdict::final('state') }, qr/did not pass type constraint/, 'final needs a state';
    like dies { Test::Mutation::Verdict::conclude('state') }, qr/did not pass type constraint/,
      'conclude needs a state';
    like dies { Test::Mutation::Verdict::final() },    qr/Wrong number of parameters/, 'final takes one argument';
    like dies { Test::Mutation::Verdict::conclude() }, qr/Wrong number of parameters/, 'and so does conclude';
    like dies { Test::Mutation::Score::tally('Killed') }, qr/did not pass type constraint/,
      'tally needs a list of statuses';
};

subtest 'score' => sub {
    my $tally =
      Test::Mutation::Score::tally(
        [qw(Killed Killed Killed Survived NoCoverage Timeout CompileError RuntimeError Ignored)] );
    is $tally->{total},           9,  'total';
    is $tally->{valid},           5,  'valid mutants';
    is $tally->{score},           60, 'score leaves out inconclusive and invalid mutants';
    is $tally->{counts}{Timeout}, 1,  'timeouts are counted on their own';
    is $tally->{counts}{Pending}, 0,  'absent statuses count zero';
    is Test::Mutation::Score::tally( [qw(Timeout CompileError)] )->{score}, undef, 'no valid mutant, no score';
    is Test::Mutation::Score::tally( [] )->{score},                         undef, 'no mutant, no score';
};

done_testing;
