use v5.36;
use Test2::V0;
use Test::Mutation::Mutant;
use Test::Mutation::Report::GitHub;
use Test::Mutation::Result;

sub entry ( $status, %fields ) {
    my %mutant = (
        id          => 'abcdefabcdef',
        path        => 'lib/Calc.pm',
        mutator     => 'comparison',
        start       => 50,
        end         => 51,
        original    => q{>},
        replacement => q{>=},
        description => 'replaced > with >=',
        from        => [ 3, 15 ],
        to          => [ 3, 16 ],
        scope       => [ 3, 3 ],
        ( $fields{mutant} ? ( delete $fields{mutant} )->%* : () ),
    );
    return {
        mutant     => Test::Mutation::Mutant->new(%mutant),
        status     => $status,
        reason     => undef,
        by         => undef,
        covered_by => [],
        tests_run  => 0,
        duration   => 0,
        %fields,
    };
}

sub result ($entries) {
    return Test::Mutation::Result->new(
        root              => '/project',
        sources           => {},
        tests             => [ { name => 't/a.t', duration => 1 } ],
        entries           => $entries,
        problems          => [],
        warnings          => [],
        baseline_failures => [],
        jobs              => 1,
        parallel_safe     => 1,
        started           => 1,
        finished          => 2,
    );
}

subtest 'annotations name the place of each undetected mutant' => sub {
    my $text = Test::Mutation::Report::GitHub::annotations(
        result(
            [
                entry('Killed'), entry('Survived'),
                entry( 'NoCoverage', mutant => { id => '000000000002', from => [ 9, 1 ], to => [ 11, 2 ] } ),
                entry( 'Timeout',    mutant => { id => '000000000003' } ),
            ]
        )
    );
    is [ split /\n/, $text ],
      [
        '::warning file=lib/Calc.pm,line=3,col=15,endLine=3,endColumn=16,title=Survived mutant::replaced > with >= (abcdefabcdef)',
        '::warning file=lib/Calc.pm,line=9,col=1,endLine=11,endColumn=2,title=Mutant without coverage::replaced > with >= (000000000002)',
        '::notice file=lib/Calc.pm,line=3,col=15,endLine=3,endColumn=16,title=Mutant timed out::replaced > with >= (000000000003)',
      ],
      'one command for each survived, uncovered, and timed-out mutant';
};

subtest 'annotation text is escaped' => sub {
    my $text = Test::Mutation::Report::GitHub::annotations(
        result( [ entry( 'Survived', mutant => { path => 'lib/A,B:C.pm', description => "100% of\nit" } ) ] ) );
    is $text,
      "::warning file=lib/A%2CB%3AC.pm,line=3,col=15,endLine=3,endColumn=16,title=Survived mutant::100%25 of%0Ait (abcdefabcdef)\n",
      'commas and colons in a property, percent signs and line feeds in the message';
};

subtest 'the summary states the score and the counts' => sub {
    my $text = Test::Mutation::Report::GitHub::summary(
        result( [ entry('Killed'), entry('Killed'), entry('Survived'), entry('Timeout') ] ) );
    like $text, qr/^## Mutation testing$/m,                                           'heading';
    like $text, qr/^Score: \*\*66\.7%\*\* \(2 of 3 valid mutants\)$/m,                'score';
    like $text, qr/^\| Killed \| Survived \| No coverage \| Timeout \|$/m,            'table heading';
    like $text, qr/^\| 2 \| 1 \| 0 \| 1 \|$/m,                                        'table row';
    like Test::Mutation::Report::GitHub::summary( result( [] ) ), qr/^Score: none$/m, 'no score without a valid mutant';
};

done_testing;
