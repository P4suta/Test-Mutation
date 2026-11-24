use v5.36;
use Test2::V0;
use Test::Mutation::Merge;
use Test::Mutation::Mutant;
use Test::Mutation::Result;

my $digest = 'ab' x 32;

sub entry ( $number, $status ) {
    my $mutant = Test::Mutation::Mutant->new(
        id          => sprintf( '%012d', $number ),
        path        => $number > 4 ? 'lib/B.pm' : 'lib/A.pm',
        mutator     => 'arithmetic',
        start       => $number,
        end         => $number + 1,
        original    => q{+},
        replacement => q{-},
        description => 'replaced + with -',
        from        => [ 1, $number + 1 ],
        to          => [ 1, $number + 2 ],
        scope       => [ 1, 1 ],
    );
    return {
        mutant     => $mutant,
        status     => $status,
        reason     => undef,
        by         => undef,
        covered_by => [],
        tests_run  => 0,
        duration   => 0
    };
}

sub part ( $shard, $entries, %fields ) {
    return Test::Mutation::Result->new(
        root              => '/project',
        sources           => { map { $_->{mutant}->path => "1 + 2 + 3 + 4 + 5;\n" } $entries->@* },
        tests             => [ { name => 't/a.t', duration => 0.5 } ],
        entries           => $entries,
        problems          => [],
        warnings          => [],
        baseline_failures => [],
        jobs              => 2,
        parallel_safe     => 1,
        shard             => $shard,
        inventory         => { mutants => 6, digest => $digest },
        started           => 100,
        finished          => 110,
        %fields,
    );
}

sub merged (@parts) {
    my $number = 0;
    return Test::Mutation::Merge::merge( [ map { { name => 'report ' . ++$number, result => $_ } } @parts ] );
}

my @first = ( entry( 1, 'Killed' ),  entry( 3, 'Survived' ), entry( 5, 'Killed' ) );
my @rest  = ( entry( 2, 'Timeout' ), entry( 4, 'Killed' ),   entry( 6, 'NoCoverage' ) );

subtest 'the parts of one run merge into the result of the whole run' => sub {
    my $whole = merged(
        part(
            '2/2',
            \@rest,
            tests => [
                { name => 't/b.t', duration => 2 },
                { name => 't/a.t', duration => 0.75 },
                { name => 't/c.t', duration => 1 }
            ],
            warnings => [ 'shared warning', 'second warning' ],
            problems => [ { path => 'lib/Odd.pm', problem => 'the file has carriage returns' } ],
            jobs     => 4,
            reused   => 2,
            started  => 90,
            finished => 105,
        ),
        part(
            '1/2', \@first,
            tests    => [ { name => 't/a.t', duration => 0.5 }, { name => 't/c.t', duration => 3 } ],
            warnings => ['shared warning'],
            problems => [ { path => 'lib/Odd.pm', problem => 'the file has carriage returns' } ],
            reused   => 1,
        ),
    );
    is [ map { $_->{mutant}->id + 0 } $whole->entries->@* ], [ 1 .. 6 ],
      'the mutants return to the order of the whole run';
    is [ map { $_->{status} } $whole->entries->@* ], [qw(Killed Timeout Survived Killed Killed NoCoverage)],
      'each mutant keeps its status';
    is $whole->tally->{score},                                 60,    'the score covers every part';
    is $whole->shard,                                          undef, 'the result is a whole run';
    is $whole->inventory, { mutants => 6, digest => $digest }, 'the inventory stays';
    is [ sort keys $whole->sources->%* ],                      [ 'lib/A.pm', 'lib/B.pm' ], 'the sources of every part';
    is $whole->tests,
      [ { name => 't/a.t', duration => 0.75 }, { name => 't/b.t', duration => 2 }, { name => 't/c.t', duration => 3 } ],
      'each test appears once with its longest duration';
    is $whole->warnings, [ 'shared warning', 'second warning' ], 'each warning appears once';
    is $whole->problems, [ { path => 'lib/Odd.pm', problem => 'the file has carriage returns' } ],
      'each problem appears once';
    is [ $whole->jobs, $whole->reused, $whole->started, $whole->finished, $whole->parallel_safe ], [ 4, 3, 90, 110, 1 ],
      'the largest job count, the sum of the reused results, and the whole time span';
};

subtest 'a part that is unsafe side by side or interrupted marks the whole' => sub {
    my $whole = merged( part( '1/2', \@first, parallel_safe => 0 ), part( '2/2', \@rest, interrupted => 'TERM' ) );
    is [ $whole->parallel_safe, $whole->interrupted ], [ 0, 'TERM' ], 'the weaker fact wins';
};

subtest 'a set that is not one complete run is refused' => sub {
    my $one = part( '1/2', \@first );
    my $two = part( '2/2', \@rest );
    like dies { merged() },             qr/\Amerge needs at least one report/,             'no report';
    like dies { merged($one) },         qr/\Apart 2 of 2 is missing/,                      'a missing part';
    like dies { merged( $one, $one ) }, qr/\Areport 1 and report 2 both hold part 1 of 2/, 'a repeated part';
    like dies { merged( $one, part( '2/3', \@rest ) ) },
      qr/\Areport 1 holds part 1 of 2, and report 2 holds part 2 of 3/,
      'parts of different splits';
    like dies { merged( part( '1/3', \@first ), part( '3/3', \@rest ) ) }, qr/\Apart 2 of 3 is missing/,
      'a missing middle part';
    like dies { merged( part( '1/4', \@first ), part( '2/4', \@rest ) ) }, qr/\Aparts 3 and 4 of 4 are missing/,
      'two missing parts';
    like dies { merged( $one, part( '2/2', \@rest, inventory => { mutants => 6, digest => 'cd' x 32 } ) ) },
      qr/\Areport 2 covers other mutants than report 1/, 'a part of another source state';
    like dies { merged( $one, part( '2/2', \@rest, shard => undef ) ) },
      qr/\Areport 2 is the report of a whole run, not of a part/, 'a whole run';
    like dies { merged( $one, part( '2/2', \@rest, inventory => undef ) ) }, qr/\Areport 2 names no inventory/,
      'a report without an inventory';
    like dies {
        merged( $one, part( '2/2', [], baseline_failures => [ { test => 't/a.t', output => q{}, errors => q{} } ] ) )
    }, qr/\Areport 2 has failing tests in its unmodified run, so its part measured nothing/, 'a part that never ran';
    like dies { merged( $one, part( '2/2', [ @rest[ 0, 1 ] ] ) ) },
      qr/\Areport 2 holds 2 mutants, and part 2 of 2 has 3/, 'a part that lost a mutant';
    like dies { merged( $one, part( '2/2', [ @rest[ 0, 1 ], $first[0] ] ) ) },
      qr/\Amutant 000000000001 appears in more than one part/, 'a mutant in two parts';
};

done_testing;
