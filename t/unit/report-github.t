use v5.36;
use Test2::V0;
use Encode ();
use Test::Mutation::Mutant;
use Test::Mutation::Report::GitHub;
use Test::Mutation::Result;
use Test::Mutation::Status;

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
        reason     => Test::Mutation::Status::of($status)->reasons->[0],
        detail     => undef,
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
                entry('Killed'),
                entry('Survived'),
                entry( 'NoCoverage', mutant => { id => '000000000002', from => [ 9, 1 ], to => [ 11, 2 ] } ),
                entry( 'Timeout',    mutant => { id => '000000000003' } ),
                ( map { entry($_) } qw(CompileError NoVerdict Ignored Pending) ),
            ]
        )
    );
    is [ split /\n/, $text ],
      [
        '::warning file=lib/Calc.pm,line=3,col=15,endLine=3,endColumn=16,title=Survived::replaced > with >= (abcdefabcdef)',
        '::warning file=lib/Calc.pm,line=9,col=1,endLine=11,endColumn=2,title=No coverage::replaced > with >= (000000000002)',
        '::notice file=lib/Calc.pm,line=3,col=15,endLine=3,endColumn=16,title=Timeout::replaced > with >= (000000000003)',
      ],
      'one command for each survived, uncovered, and timed-out mutant, titled with the heading of its status';
    is [ grep { defined $_->annotation && !defined $_->heading } Test::Mutation::Status::rows()->@* ], [],
      'every status with an annotation has a heading for its title';
};

subtest 'annotation text is escaped' => sub {
    my $text = Test::Mutation::Report::GitHub::annotations(
        result( [ entry( 'Survived', mutant => { path => 'lib/A,B:C.pm', description => "100% of\nit" } ) ] ) );
    is $text,
      "::warning file=lib/A%2CB%3AC.pm,line=3,col=15,endLine=3,endColumn=16,title=Survived::100%25 of%0Ait (abcdefabcdef)\n",
      'commas and colons in a property, percent signs and line feeds in the message';
};

subtest 'the summary states the score and the count of every status' => sub {
    my $text = Test::Mutation::Report::GitHub::summary(
        result( [ entry('Killed'), entry('Killed'), entry('Survived'), entry('Timeout'), entry('NoVerdict') ] ) );
    like $text, qr/^## Mutation testing$/m,                            'heading';
    like $text, qr/^Score: \*\*66\.7%\*\* \(2 of 3 valid mutants\)$/m, 'score';
    like $text,
      qr/^\| Killed \| Survived \| No coverage \| Timeout \| Compile error \| No verdict \| Ignored \| Pending \|$/m,
      'table heading';
    like $text, qr/^\| --- \| --- \| --- \| --- \| --- \| --- \| --- \| --- \|$/m,    'table rule';
    like $text, qr/^\| 2 \| 1 \| 0 \| 1 \| 0 \| 1 \| 0 \| 0 \|$/m,                    'table row';
    like Test::Mutation::Report::GitHub::summary( result( [] ) ), qr/^Score: none$/m, 'no score without a valid mutant';
    like Test::Mutation::Report::GitHub::summary( result( [ entry('Killed') ] ) ),
      qr/^Score: \*\*100\.0%\*\* \(1 of 1 valid mutant\)$/m, 'one valid mutant';
};

subtest 'the summary names a sample of the gaps and the full report' => sub {
    my @entries;
    for my $status (qw(Survived Timeout)) {
        push @entries,
          map { entry( $status, mutant => { id => sprintf( '%012x', @entries + $_ ), path => 'lib/A|B.pm' } ) } 1 .. 12;
    }
    my $result   = result( \@entries );
    my $commands = Test::Mutation::Report::GitHub::annotations($result);
    is scalar( () = $commands =~ /^::warning /mg ), 10, 'ten warnings';
    is scalar( () = $commands =~ /^::notice /mg ),  10, 'ten notices';
    my $summary = Test::Mutation::Report::GitHub::summary( $result, 85, ['artifacts/mutation.json'] );
    like $summary,   qr/Gate: .*85%/,               'the summary includes the threshold decision';
    like $summary,   qr/^Undetected: 12$/m,         'the full count excludes timeouts';
    like $summary,   qr/000000000001/,              'the first undetected change is included';
    unlike $summary, qr/00000000000c/,              'the sample leaves room for the report location';
    like $summary,   qr{artifacts/mutation[.]json}, 'the summary names the published file';
    unlike $summary, qr/\| lib\/A\|B[.]pm \|/,      'a pipe in a filename cannot split a table cell';
};

subtest 'the step limit counts encoded bytes' => sub {
    my $huge    = "\x{65e5}" x 400_000;
    my $saved   = result( [ entry( 'Survived', mutant => { description => $huge } ) ] );
    my $summary = Test::Mutation::Report::GitHub::summary( $saved, 90, ['reports/mutation.html'] );
    cmp_ok length( Encode::encode( 'UTF-8', $summary ) ), '<=', 1024 * 1024, 'the Markdown fits one step';
    like $summary, qr/^Undetected: 1$/m,        'the count survives an oversized example';
    like $summary, qr{reports/mutation[.]html}, 'the file location survives an oversized example';
};

done_testing;
