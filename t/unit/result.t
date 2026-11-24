use v5.36;
use Test2::V0;
use Test::Mutation::Mutant;
use Test::Mutation::Result;
use Test::Mutation::Status;

my $mutant = Test::Mutation::Mutant->new(
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

sub entry ( $status, %fields ) {
    return {
        mutant     => $mutant,
        status     => $status,
        reason     => Test::Mutation::Status::of($status)->reasons->[0],
        detail     => undef,
        by         => undef,
        covered_by => [],
        tests_run  => 0,
        duration   => 0,
        %fields
    };
}

sub result ( $statuses, %fields ) {
    return Test::Mutation::Result->new(
        root              => '/project',
        sources           => { 'lib/A.pm' => 'a + b' },
        tests             => [ { name => 't/a.t', duration => 0.5 } ],
        entries           => [ map { entry($_) } $statuses->@* ],
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
    ok !result( [qw(Killed NoVerdict)] )->conclusive,     'a mutant without a verdict';
    ok !result( [qw(Timeout CompileError)] )->conclusive, 'mutants ran and none is valid';
    ok !result( ['Killed'], baseline_failures => [ { test => 't/a.t', output => q{}, errors => q{} } ] )->conclusive,
      'the unmodified run failed';
};

subtest 'construction checks the entries' => sub {
    my $made = sub (@entries) {
        return dies { result( [], entries => \@entries ) };
    };
    like $made->( { entry('Killed')->%*, status => 'Dead' } ), qr/entries/, 'an unknown status is refused';
    like $made->( { entry('Killed')->%*, status => 'RuntimeError' } ), qr/entries/,
      'and so is a name of the schema alone';
    like $made->( entry( 'Timeout', reason => undef ) ),        qr/entries/, 'a timeout without its reason';
    like $made->( entry( 'Timeout', reason => 'unreached' ) ),  qr/entries/, 'a reason of another status';
    like $made->( entry( 'Killed',  reason => 'time-limit' ) ), qr/entries/, 'a killed mutant with a reason';
    is $made->( entry( 'NoVerdict', reason => 'project-changed', detail => 't/a.t fails without a mutant' ) ), undef,
      'a reason of the status, with a detail';
};

done_testing;
