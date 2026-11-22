use v5.36;
use Test2::V0;
use Permutl::Mutant;
use Permutl::Report::Terminal;
use Permutl::Result;

my $source = "sub is_positive {\n    my (\$n) = \@_;\n    return \$n > 0 ? 1 : 0;\n}\n";

sub mutant (%fields) {
    return Permutl::Mutant->new(
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
        %fields,
    );
}

sub entry ( $status, %fields ) {
    return {
        mutant     => mutant(),
        status     => $status,
        reason     => undef,
        by         => undef,
        covered_by => ['t/sign.t'],
        tests_run  => 1,
        duration   => 0.1,
        %fields,
    };
}

sub result ( $entries, %fields ) {
    return Permutl::Result->new(
        root              => '/project',
        sources           => { 'lib/Calc.pm' => $source },
        tests             => [ { name => 't/sign.t', duration => 0.5 } ],
        entries           => $entries,
        problems          => [],
        warnings          => [],
        baseline_failures => [],
        jobs              => 2,
        parallel_safe     => 1,
        started           => 100,
        finished          => 103.5,
        %fields,
    );
}

subtest 'the summary counts every status and states the score' => sub {
    my $text = Permutl::Report::Terminal::render(
        result( [ entry('Killed'), entry('Killed'), entry('Survived'), entry('Timeout') ] ),
        color => 0 );
    like $text, qr/^4 mutants: 2 killed, 1 survived, 1 timeout$/m, 'counts leave out statuses with no mutant';
    like $text, qr/^Score: 66\.7% \(2 of 3 valid mutants\)$/m,     'score';
    like $text, qr/^Timeouts are inconclusive and count toward neither side\.$/m, 'the timeout note';
    like $text, qr/^1 test, 2 jobs, 3\.5 s$/m,                                    'the run facts';
};

subtest 'a survived mutant shows its place, change, and tests' => sub {
    my $text = Permutl::Report::Terminal::render( result( [ entry('Survived') ] ), color => 0 );
    like $text, qr/^Survived \(1\)$/m,                                             'section heading';
    like $text, qr/^  lib\/Calc\.pm:3:15  replaced > with >=  \[abcdefabcdef\]$/m, 'place, description, identifier';
    like $text, qr/^    -     return \$n > 0 \? 1 : 0;$/m,                         'the original line';
    like $text, qr/^    \+     return \$n >= 0 \? 1 : 0;$/m,                       'the mutated line';
    like $text, qr/^    reached by t\/sign\.t$/m,                                  'the tests that reached it';
};

subtest 'a mutant that spans lines shows its first line' => sub {
    my $body = mutant(
        start       => 17,
        end         => 63,
        original    => substr( $source, 17, 46 ),
        replacement => "\n\n\n",
        description => 'removed the body of is_positive',
        from        => [ 1, 18 ],
        to          => [ 4, 1 ],
        scope       => [ 1, 4 ]
    );
    my $text = Permutl::Report::Terminal::render( result( [ entry( 'Survived', mutant => $body ) ] ), color => 0 );
    like $text, qr/^    - sub is_positive \{ \.\.\.$/m, 'the first original line with an ellipsis';
    like $text, qr/^    \+ sub is_positive \{$/m,       'the first mutated line';
};

subtest 'sections appear for the statuses that need attention' => sub {
    my $text = Permutl::Report::Terminal::render(
        result(
            [
                entry('Killed'),
                entry( 'NoCoverage',   covered_by => [] ),
                entry( 'RuntimeError', reason     => 't/a.t loaded the target without the hook' )
            ]
        ),
        color => 0,
    );
    unlike $text, qr/^Killed \(/m,                                       'killed mutants are not listed';
    like $text,   qr/^No coverage \(1\)$/m,                              'no coverage section';
    like $text,   qr/^    reached by no test$/m,                         'a mutant without tests says so';
    like $text,   qr/^Runtime error \(1\)$/m,                            'runtime error section';
    like $text,   qr/^    t\/a\.t loaded the target without the hook$/m, 'the reason';
};

subtest 'warnings, problems, and baseline failures are reported' => sub {
    my $text = Permutl::Report::Terminal::render(
        result(
            [],
            warnings          => ['the tests fail when they run side by side'],
            problems          => [ { path => 'lib/Odd.pm', problem => 'the file has carriage returns' } ],
            baseline_failures => [ { test => 't/broken.t', output  => "1..1\nnot ok 1\n", errors => "# failed\n" } ],
        ),
        color => 0,
    );
    like $text,   qr/^The unmodified run fails, so no mutant ran\.$/m,        'the baseline failure heading';
    like $text,   qr/^  t\/broken\.t$/m,                                      'the failing test';
    like $text,   qr/^    not ok 1$/m,                                        'its output';
    like $text,   qr/^    # failed$/m,                                        'its errors';
    like $text,   qr/^warning: the tests fail when they run side by side$/m,  'a warning';
    like $text,   qr/^skipped lib\/Odd\.pm: the file has carriage returns$/m, 'a skipped file';
    unlike $text, qr/^Score:/m,                                               'no score without a measurement';
};

subtest 'color wraps the score when asked' => sub {
    my $plain = Permutl::Report::Terminal::render( result( [ entry('Killed') ] ), color => 0 );
    my $color = Permutl::Report::Terminal::render( result( [ entry('Killed') ] ), color => 1 );
    unlike $plain, qr/\e\[/,                  'no escape sequence without color';
    like $color,   qr/\e\[32mScore: 100\.0%/, 'a full score is green';
};

subtest 'the whole report keeps its order' => sub {
    my $text = Permutl::Report::Terminal::render(
        result(
            [
                entry('Killed'),
                entry( 'Survived',   covered_by => [qw(t/a.t t/b.t t/c.t t/d.t t/e.t)] ),
                entry( 'NoCoverage', covered_by => [] ),
                entry( 'Timeout',    reason     => 'slow' ),
            ],
            warnings    => [ 'first warning', 'second warning' ],
            problems    => [ { path => 'lib/Bad.pm', problem => 'unreadable' } ],
            interrupted => 'INT',
            reused      => 2,
        ),
        color => 0,
    );
    my $change = "    -     return \$n > 0 ? 1 : 0;\n    +     return \$n >= 0 ? 1 : 0;\n";
    my $place  = "  lib/Calc.pm:3:15  replaced > with >=  [abcdefabcdef]\n$change";
    is $text,
      join( "\n",
        "4 mutants: 1 killed, 1 survived, 1 no coverage, 1 timeout\nScore: 33.3% (1 of 3 valid mutants)\n"
          . "Timeouts are inconclusive and count toward neither side.\nThe run was interrupted by SIGINT.\n"
          . "1 test, 2 jobs, 3.5 s, 2 results from the cache\n",
        "Survived (1)\n$place    reached by t/a.t, t/b.t, t/c.t and 2 more\n",
        "No coverage (1)\n$place    reached by no test\n",
        "Timeout (1)\n$place    reached by t/sign.t\n    slow\n",
        "warning: first warning\nwarning: second warning\nskipped lib/Bad.pm: unreadable\n",
      ),
      'summary, sections, and notes';

    my $failed = Permutl::Report::Terminal::render(
        result(
            [],
            baseline_failures => [
                { test => 't/a.t', output => "not ok 1\n", errors => "died\n" },
                { test => 't/b.t', output => "not ok 2\n", errors => q{} },
            ],
        ),
        color => 0,
    );
    is $failed, "The unmodified run fails, so no mutant ran.\n  t/a.t\n    not ok 1\n    died\n  t/b.t\n    not ok 2\n",
      'baseline failures';
};

subtest 'the color follows the thresholds at their boundaries' => sub {
    my $at = sub ( $killed, %thresholds ) {
        my @entries = ( ( map { entry('Killed') } 1 .. $killed ), ( map { entry('Survived') } $killed + 1 .. 5 ) );
        my ($code) =
          Permutl::Report::Terminal::render( result( \@entries ), color => 1, %thresholds ) =~ /\e\[(\d+)mScore/;
        return $code;
    };
    is $at->(4),                          32, 'a score at the high threshold is green';
    is $at->(3),                          33, 'a score at the low threshold is yellow';
    is $at->(2),                          31, 'a score below the low threshold is red';
    is $at->( 4, high => 90 ),            33, 'a higher high threshold';
    is $at->( 4, high => 90, low => 85 ), 31, 'a higher low threshold';
    is $at->( 2, high => 50, low => 40 ), 33, 'a lower pair of thresholds';
};

done_testing;
