use v5.36;
use Test2::V0;
use Permutl::Mutant;
use Permutl::Result;

my $mutant = Permutl::Mutant->new(
    id          => 'abcdefabcdef',
    path        => 'lib/A.pm',
    mutator     => 'arithmetic',
    start       => 0,
    end         => 1,
    original    => q{+},
    replacement => q{-},
    description => 'replaced + with -',
    from        => [ 1, 1 ],
    to          => [ 1, 2 ],
    scope       => [ 1, 1 ],
);

sub result ( $statuses, %fields ) {
    return Permutl::Result->new(
        root    => '/project',
        sources => { 'lib/A.pm' => 'a + b' },
        tests   => [ { name => 't/a.t', duration => 0.5 } ],
        entries => [
            map {
                {
                    mutant     => $mutant,
                    status     => $_,
                    reason     => undef,
                    by         => undef,
                    covered_by => [],
                    tests_run  => 0,
                    duration   => 0
                }
            } $statuses->@*
        ],
        problems          => [],
        warnings          => [],
        baseline_failures => [],
        jobs              => 1,
        parallel_safe     => 1,
        started           => 1,
        finished          => 2,
        %fields,
    );
}

subtest 'tally' => sub {
    my $tally = result( [qw(Killed Killed Survived Timeout)] )->tally;
    is $tally->{counts}{Killed}, 2, 'killed';
    is $tally->{valid},          3, 'valid';
    ok abs( $tally->{score} - 200 / 3 ) < 1e-9, 'score';
};

subtest 'conclusive' => sub {
    ok result( [qw(Killed Survived)] )->conclusive,       'valid mutants and nothing wrong';
    ok result( [] )->conclusive,                          'no mutant at all';
    ok result( [qw(Ignored Ignored)] )->conclusive,       'every mutant suppressed';
    ok !result( [qw(Killed RuntimeError)] )->conclusive,  'a runtime error';
    ok !result( [qw(Timeout CompileError)] )->conclusive, 'mutants ran and none is valid';
    ok !result( ['Killed'], baseline_failures => [ { test => 't/a.t', output => q{}, errors => q{} } ] )->conclusive,
      'the unmodified run failed';
};

subtest 'construction checks the entries' => sub {
    like dies { result( ['Dead'] ) }, qr/entries/, 'an unknown status is refused';
};

done_testing;
