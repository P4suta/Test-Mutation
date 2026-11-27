use v5.36;
use Test2::V0;
use Test::Mutation::Coverage;
use Test::Mutation::Mutant;
use Test::Mutation::Verdict;

sub mutant ( $path, $first, $last ) {
    return Test::Mutation::Mutant->new(
        id          => 'abcdefabcdef',
        path        => $path,
        mutator     => 'arithmetic',
        start       => 0,
        end         => 1,
        original    => q{+},
        replacement => q{-},
        description => 'replaced + with -',
        from        => [ $first, 1 ],
        to          => [ $first, 2 ],
        scope       => [ $first, $last ],
    );
}

sub file (%fields) {
    return { traced => 1, hits => {}, %fields };
}

my %tests = (
    't/slow.t'      => { duration => 3,   files => { 'lib/A.pm' => file( hits   => { 10 => 1, 11 => 1 } ) } },
    't/fast.t'      => { duration => 0.1, files => { 'lib/A.pm' => file( hits   => { 11 => 1 } ) } },
    't/other.t'     => { duration => 0.2, files => { 'lib/B.pm' => file( hits   => { 5  => 1 } ) } },
    't/elsewhere.t' => { duration => 0.3, files => { 'lib/A.pm' => file( hits   => { 40 => 1 } ) } },
    't/untraced.t'  => { duration => 0.4, files => { 'lib/A.pm' => file( traced => 0 ) } },
);
my %breakable = ( 'lib/A.pm' => { map { $_ => 1 } 10, 11, 20, 40 }, 'lib/B.pm' => { 5 => 1 } );

sub coverage ($mode) {
    return Test::Mutation::Coverage->new( mode => $mode, tests => \%tests, breakable => \%breakable );
}

subtest 'file mode selects every test that loaded the file' => sub {
    is coverage('file')->tests_for( mutant( 'lib/A.pm', 11, 11 ) ),
      [ 't/elsewhere.t', 't/fast.t', 't/slow.t', 't/untraced.t' ],
      'in project-relative path order';
    is coverage('file')->tests_for( mutant( 'lib/C.pm', 1, 1 ) ), [], 'a file that no test loaded';
};

subtest 'line mode selects the tests that ran the statement' => sub {
    my $coverage = coverage('line');
    is $coverage->tests_for( mutant( 'lib/A.pm', 11, 11 ) ), [ 't/fast.t', 't/slow.t', 't/untraced.t' ],
      'tests that hit the line, plus the untraced test';
    is $coverage->tests_for( mutant( 'lib/A.pm', 10, 10 ) ), [ 't/slow.t', 't/untraced.t' ],
      'a line that one traced test hit';
    is $coverage->tests_for( mutant( 'lib/A.pm', 9, 12 ) ), [ 't/fast.t', 't/slow.t', 't/untraced.t' ],
      'any line of a multi-line statement counts';
    is $coverage->tests_for( mutant( 'lib/A.pm', 20, 20 ) ), ['t/untraced.t'],
      'a breakable line that no traced test hit leaves the untraced test';
    is $coverage->tests_for( mutant( 'lib/B.pm', 5, 5 ) ), ['t/other.t'], 'another file';
};

subtest 'a statement without runtime lines falls back to the file' => sub {
    is coverage('line')->tests_for( mutant( 'lib/A.pm', 30, 31 ) ),
      [ 't/elsewhere.t', 't/fast.t', 't/slow.t', 't/untraced.t' ],
      'no breakable line and no hit in the scope';
};

subtest 'a line that a test ran is observable without the list of statement lines' => sub {
    my $coverage = Test::Mutation::Coverage->new( mode => 'line', tests => \%tests, breakable => {} );
    is $coverage->tests_for( mutant( 'lib/A.pm', 10, 10 ) ), [ 't/slow.t', 't/untraced.t' ],
      'the tests that ran the line, and no other test that loaded the file';
};

subtest 'unmodified test durations cannot move a failure behind two timeouts' => sub {
    my @names = qw(t/check.t t/lexer.t t/token.t);
    for my $durations ( [ 3, 1, 2 ], [ 1, 3, 2 ] ) {
        my %unmodified;
        @unmodified{@names} = map { { duration => $_, files => { 'lib/A.pm' => file() } } } $durations->@*;
        my $coverage = Test::Mutation::Coverage->new( mode => 'file', tests => \%unmodified, breakable => {} );
        my $state    = Test::Mutation::Verdict::start();
        for my $test ( $coverage->tests_for( mutant( 'lib/A.pm', 1, 1 ) )->@* ) {
            $state = Test::Mutation::Verdict::step(
                $state,
                {
                    test        => $test,
                    result      => $test eq 't/check.t' ? 'fail' : 'timeout',
                    served      => 1,
                    load_failed => 0,
                    bypassed    => 0,
                    syntax      => undef,
                }
            );
            last if defined $state->{status};
        }
        is [ $state->@{qw(status by tests)} ], [ 'Killed', 't/check.t', 1 ], "unmodified durations @$durations";
    }
};

subtest 'equal durations are ordered by name' => sub {
    my $coverage = Test::Mutation::Coverage->new(
        mode      => 'file',
        breakable => {},
        tests     => { map { $_ => { duration => 1, files => { 'lib/A.pm' => file() } } } 't/b.t', 't/a.t', 't/c.t' },
    );
    is $coverage->tests_for( mutant( 'lib/A.pm', 1, 1 ) ), [ 't/a.t', 't/b.t', 't/c.t' ], 'a stable order';
};

done_testing;
