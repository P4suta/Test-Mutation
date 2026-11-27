use v5.36;
use Test2::V0;
use Digest::SHA ();
use Encode      ();
use JSON::PP    ();
use Test::Mutation::Mutant;
use Test::Mutation::Report::Html;
use Test::Mutation::Report::Json;
use Test::Mutation::Result;

my $source = "my \$tag = '</script><script>alert(1)</script>';\nmy \$n = 1 + 2;\n";
my $mutant = Test::Mutation::Mutant->new(
    id          => 'abcdefabcdef',
    path        => 'lib/Page.pm',
    mutator     => 'arithmetic',
    start       => 57,
    end         => 58,
    original    => q{+},
    replacement => q{-},
    description => 'replaced + with -',
    from        => [ 2, 12 ],
    to          => [ 2, 13 ],
    scope       => [ 2, 2 ],
);
my $result = Test::Mutation::Result->new(
    root    => '/project',
    sources => { 'lib/Page.pm' => $source },
    tests   => [ { name => 't/page.t', duration => 0.5 } ],
    entries => [
        {
            mutant     => $mutant,
            status     => 'Survived',
            reason     => undef,
            detail     => undef,
            by         => undef,
            covered_by => ['t/page.t'],
            tests_run  => 1,
            duration   => 0.5
        }
    ],
    problems          => [],
    warnings          => [],
    baseline_failures => [],
    jobs              => 1,
    parallel_safe     => 1,
    started           => 1,
    finished          => 2,
);

my $html = Test::Mutation::Report::Html::render( $result, high => 80, low => 60 );

subtest 'the writer escapes source text inside the embedded report' => sub {
    my @chunks;
    Test::Mutation::Report::Html::stream(
        $result,
        high  => 80,
        low   => 60,
        write => sub ($chunk) { push @chunks, $chunk }
    );
    my $text   = join q{}, @chunks;
    my ($data) = $text =~ m{<script id="report" type="application/json">(.+?)</script>}s;
    is JSON::PP->new->decode($data)->{files}{'lib/Page.pm'}{source}, $source, 'the embedded JSON round-trips';
    ok scalar( grep { /00000000000|abcdefabcdef/ && !/<script/ } @chunks ), 'the file is emitted apart from the viewer';
};

subtest 'the visible report states its measured scope, gap count, score, and gate' => sub {
    my $gated = Test::Mutation::Result->new(
        $result->%*,
        min_score => 70,
        selection => { paths => { 'lib/<Page>.pm' => [] } }
    );
    my $page = Test::Mutation::Report::Html::render( $gated, high => 80, low => 60 );
    my ($summary) = $page =~ m{<header>(.*?)</header>}s;
    like $summary, qr/Scope: lib\/&lt;Page&gt;\.pm/, 'the source path is escaped as HTML text';
    like $summary, qr/Undetected: 1/,                'the count is visible without running the viewer';
    like $summary, qr/Score: 0\.0%/,                 'the visible score matches the selected entries';
    like $summary, qr/Gate: failed \(minimum 70%\)/, 'the requested threshold is separate from the viewer colors';
};

subtest 'the page is one self-contained document' => sub {
    like $html,   qr/\A<!DOCTYPE html>\n<html lang="en">/, 'doctype and language';
    like $html,   qr/<meta charset="utf-8">/,              'character set';
    like $html,   qr/<title>Mutation report<\/title>/,     'title';
    like $html,   qr/<mutation-test-report-app\b/,         'the viewer element';
    unlike $html, qr/<script[^>]*\bsrc=/,                  'no script is loaded from elsewhere';
    unlike $html, qr/https?:\/\/[^"'\s]*\.js\b/,           'no script address';
};

subtest 'the viewer is the pinned build' => sub {
    my $bundle = Test::Mutation::Report::Html::viewer_script();
    is Digest::SHA::sha256_hex( Encode::encode( 'UTF-8', $bundle ) ), Test::Mutation::Report::Html::viewer_digest(),
      'the bundled file has the recorded digest';
    is Test::Mutation::Report::Html::viewer_version(), '3.9.0', 'the recorded version';
    ok index( $html, $bundle ) >= 0, 'the page embeds the bundle';
};

subtest 'the report data is embedded without ending its script element' => sub {
    my ($data) = $html =~ m{<script id="report" type="application/json">(.*?)</script>}s;
    ok defined $data, 'a data element holds the report';
    unlike $data, qr/</, 'no left angle bracket appears in the data';
    is JSON::PP->new->decode($data), Test::Mutation::Report::Json::document( $result, high => 80, low => 60 ),
      'the data decodes to the report document';
    is JSON::PP->new->decode($data)->{files}{'lib/Page.pm'}{source}, $source, 'the source survives the escaping';
};

done_testing;
