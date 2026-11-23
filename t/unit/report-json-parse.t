use v5.36;
use Test2::V0;
use Permutl::Mutant;
use Permutl::Report::Json;
use Permutl::Result;

my $source = "sub is_positive {\n    my (\$n) = \@_;\n    return \$n > 0 ? 1 : 0;\n}\n";

sub entry ( $status, %fields ) {
    my $mutant = Permutl::Mutant->new(
        id          => delete $fields{id},
        path        => 'lib/Calc.pm',
        mutator     => 'comparison',
        start       => 50,
        end         => 51,
        original    => q{>},
        replacement => q{>=},
        description => 'replaced > with >=',
        from        => [ 3, 15 ],
        to          => [ 3, 16 ],
        scope       => [ 2, 3 ],
        suppressed  => $status eq 'Ignored' ? 1 : 0,
        comparable  => $status eq 'Pending' ? 0 : 1,
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
    sources => { 'lib/Calc.pm' => $source },
    tests   => [ { name => 't/sign.t', duration => 0.5 } ],
    entries => [
        entry(
            'Killed',
            id         => '000000000001',
            by         => 't/sign.t',
            covered_by => ['t/sign.t'],
            tests_run  => 1,
            duration   => 0.25
        ),
        entry( 'Ignored', id => '000000000002', reason => 'suppressed by a comment' ),
        entry( 'Pending', id => '000000000003' ),
    ],
    problems          => [ { path => 'lib/Odd.pm', problem => 'the file has carriage returns' } ],
    warnings          => ['t/direct.t loads lib/Direct.pm around the hook and cannot detect its mutants'],
    baseline_failures => [ { test => 't/broken.t', output => 'not ok 1', errors => 'died' } ],
    jobs              => 3,
    parallel_safe     => 0,
    interrupted       => 'INT',
    reused            => 2,
    shard             => '2/4',
    inventory         => { mutants => 12, digest => 'ab' x 32 },
    started           => 100,
    finished          => 103.5,
);
my $text = Permutl::Report::Json::render( $result, high => 80, low => 60 );
my $back = Permutl::Report::Json::parse($text);

is Permutl::Report::Json::document( $back, high => 80, low => 60 ),
  Permutl::Report::Json::document( $result, high => 80, low => 60 ), 'the rebuilt result renders the same document';

my ( $killed, $ignored, $pending ) = map { $_->{mutant} } $back->entries->@*;
is [ $killed->start, $killed->end, $killed->original, $killed->path ], [ 50, 51, q{>}, 'lib/Calc.pm' ],
  'the span and the original text come from the source in the report';
is [ map { [ $_->suppressed, $_->comparable ] } $killed, $ignored, $pending ], [ [ 0, 1 ], [ 1, 1 ], [ 0, 0 ] ],
  'the flags of each mutant';
is $back->entries->[0], hash { field by => 't/sign.t'; field duration => 0.25; field tests_run => 1; etc },
  'the deciding test, the duration, and the test count';
is $back->baseline_failures, [ { test => 't/broken.t', output => q{}, errors => q{} } ],
  'a failing test of the unmodified run keeps its name';
is $back->sources, { 'lib/Calc.pm' => $source }, 'the sources';

like dies { Permutl::Report::Json::parse('{') }, qr/\Athe text is no JSON document/, 'broken JSON is refused';
like dies { Permutl::Report::Json::parse('{"schemaVersion":"2","thresholds":{"high":80,"low":60},"files":{}}') },
  qr/\Athe report holds no run facts of permutl/, 'a report of another tool is refused';
like dies { Permutl::Report::Json::parse( $text =~ s/"jobs" : 3/"jobs" : "many"/r ) }, qr/\Athe report is malformed: /,
  'a wrong type is refused';
like dies { Permutl::Report::Json::parse( $text =~ s/"line" : 3/"line" : 99/r ) }, qr/\Athe report is malformed: /,
  'a location outside the source is refused';

done_testing;
