use v5.36;
use Test2::V0;
use JSON::PP ();
use Permutl::Mutant;
use Permutl::Report::Json;
use Permutl::Result;

my $source = "sub is_positive {\n    my (\$n) = \@_;\n    return \$n > 0 ? 1 : 0;\n}\n";

sub entry ( $status, %fields ) {
    my $id     = delete $fields{id};
    my $mutant = Permutl::Mutant->new(
        id          => defined $id ? $id : 'abcdefabcdef',
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
    );
    return {
        mutant     => $mutant,
        status     => $status,
        reason     => undef,
        by         => undef,
        covered_by => [],
        tests_run  => 0,
        duration   => 0,
        %fields
    };
}

my $result = Permutl::Result->new(
    root    => '/project',
    sources => { 'lib/Calc.pm' => $source, 'lib/Unmutated.pm' => "1;\n" },
    tests   => [ { name => 't/sign.t', duration => 0.5 }, { name => 't/add.t', duration => 0.25 } ],
    entries => [
        entry(
            'Killed',
            id         => '000000000001',
            by         => 't/sign.t',
            reason     => 't/sign.t failed',
            covered_by => [ 't/add.t', 't/sign.t' ],
            tests_run  => 2,
            duration   => 0.75
        ),
        entry( 'Survived',   id => '000000000002', covered_by => ['t/sign.t'], tests_run => 1, duration => 0.5 ),
        entry( 'NoCoverage', id => '000000000003' ),
    ],
    problems          => [],
    warnings          => [],
    baseline_failures => [],
    jobs              => 2,
    parallel_safe     => 1,
    started           => 100,
    finished          => 103.5,
);

my $document = Permutl::Report::Json::document( $result, high => 80, low => 60 );

subtest 'the document has the required top-level fields' => sub {
    is $document->{schemaVersion}, '2', 'schema version';
    is $document->{thresholds}, { high => 80, low => 60 }, 'thresholds';
    is Permutl::Report::Json::document( $result, high => 79.5, low => 60.25 )->{thresholds}, { high => 80, low => 60 },
      'the schema takes whole thresholds, so the report rounds them';
    is $document->{projectRoot}, '/project', 'project root';
    is $document->{framework}, { name => 'permutl', version => Permutl::Report::Json->VERSION }, 'framework';
    is [ sort keys $document->{files}->%* ], ['lib/Calc.pm'], 'files with mutants';
};

subtest 'a file carries its language, source, and mutants' => sub {
    my $file = $document->{files}{'lib/Calc.pm'};
    is $file->{language}, 'perl',  'language';
    is $file->{source},   $source, 'source';
    is [ map { $_->{id} } $file->{mutants}->@* ], [ '000000000001', '000000000002', '000000000003' ],
      'mutants in order';
};

subtest 'a mutant maps to the schema' => sub {
    my ( $killed, $survived, $uncovered ) = $document->{files}{'lib/Calc.pm'}{mutants}->@*;
    is $killed,
      {
        id             => '000000000001',
        mutatorName    => 'comparison',
        replacement    => '>=',
        description    => 'replaced > with >=',
        location       => { start => { line => 3, column => 15 }, end => { line => 3, column => 16 } },
        status         => 'Killed',
        statusReason   => 't/sign.t failed',
        coveredBy      => [ 't/add.t', 't/sign.t' ],
        killedBy       => ['t/sign.t'],
        testsCompleted => 2,
        duration       => 750,
        static         => JSON::PP::false,
      },
      'a killed mutant';
    ok !exists $survived->{killedBy},     'a survived mutant has no killing test';
    ok !exists $survived->{statusReason}, 'an absent reason is left out';
    is $uncovered->{coveredBy}, [], 'an uncovered mutant has no tests';
};

subtest 'tests are listed as test files' => sub {
    is $document->{testFiles},
      {
        't/add.t'  => { tests => [ { id => 't/add.t',  name => 't/add.t' } ] },
        't/sign.t' => { tests => [ { id => 't/sign.t', name => 't/sign.t' } ] },
      },
      'one test per file';
};

subtest 'render writes canonical JSON with numbers as numbers' => sub {
    my $text = Permutl::Report::Json::render( $result, high => 80, low => 60 );
    is JSON::PP->new->decode($text), JSON::PP->new->decode( JSON::PP->new->canonical->encode($document) ),
      'the text decodes to the document';
    like $text, qr/"line"\s*:\s*3\b/,       'a line is a JSON number';
    like $text, qr/"duration"\s*:\s*750\b/, 'a duration is a JSON number';
    like $text, qr/"static"\s*:\s*false\b/, 'static is a JSON boolean';
    is $text, Permutl::Report::Json::render( $result, high => 80, low => 60 ), 'the output is stable';
};

done_testing;
