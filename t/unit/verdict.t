use v5.36;
use Test2::V0;
use Permutl::Score;
use Permutl::Verdict;

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
    my $state = Permutl::Verdict::start();
    $state = Permutl::Verdict::step( $state, $_ ) for @outcomes;
    return Permutl::Verdict::final($state);
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

subtest 'the state records the deciding test' => sub {
    my $state = Permutl::Verdict::start();
    $state = Permutl::Verdict::step( $state, outcome( test => 't/one.t' ) );
    $state = Permutl::Verdict::step( $state, outcome( test => 't/two.t',   result => 'fail' ) );
    $state = Permutl::Verdict::step( $state, outcome( test => 't/three.t', result => 'fail' ) );
    is $state->{by},    't/two.t', 'the deciding test';
    is $state->{tests}, 2,         'outcomes after the decision are not counted';
    like $state->{reason}, qr{t/two\.t failed}, 'the reason names the test';
};

subtest 'a load failure without a syntax check is a contract violation' => sub {
    like dies { verdict( outcome( load_failed => 1 ) ) }, qr/needs a syntax check/, 'refused';
};

subtest 'arguments are checked' => sub {
    like dies { Permutl::Verdict::start('extra') }, qr/Wrong number of parameters/, 'start takes no argument';
    like dies { Permutl::Verdict::step( {}, outcome() ) }, qr/did not pass type constraint/, 'step needs a whole state';
    like dies { Permutl::Verdict::step( Permutl::Verdict::start(), { test => 't/a.t' } ) },
      qr/did not pass type constraint/, 'step needs a whole outcome';
    like dies { Permutl::Verdict::final('state') }, qr/did not pass type constraint/, 'final needs a state';
    like dies { Permutl::Score::tally('Killed') },  qr/did not pass type constraint/, 'tally needs a list of statuses';
};

subtest 'score' => sub {
    my $tally =
      Permutl::Score::tally( [qw(Killed Killed Killed Survived NoCoverage Timeout CompileError RuntimeError Ignored)] );
    is $tally->{total},           9,  'total';
    is $tally->{valid},           5,  'valid mutants';
    is $tally->{score},           60, 'score leaves out inconclusive and invalid mutants';
    is $tally->{counts}{Timeout}, 1,  'timeouts are counted on their own';
    is $tally->{counts}{Pending}, 0,  'absent statuses count zero';
    is Permutl::Score::tally( [qw(Timeout CompileError)] )->{score}, undef, 'no valid mutant, no score';
    is Permutl::Score::tally( [] )->{score},                         undef, 'no mutant, no score';
};

done_testing;
