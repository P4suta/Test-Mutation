use v5.36;
use Test2::V0;
use Digest::SHA ();
use Encode      ();
use JSON::PP    ();
use Permutl::Mutant;
use Permutl::Report::Html;
use Permutl::Report::Json;
use Permutl::Result;

my $source = "my \$tag = '</script><script>alert(1)</script>';\nmy \$n = 1 + 2;\n";
my $mutant = Permutl::Mutant->new(
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
my $result = Permutl::Result->new(
    root    => '/project',
    sources => { 'lib/Page.pm' => $source },
    tests   => [ { name => 't/page.t', duration => 0.5 } ],
    entries => [
        {
            mutant     => $mutant,
            status     => 'Survived',
            reason     => undef,
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

my $html = Permutl::Report::Html::render( $result, high => 80, low => 60 );

subtest 'the page is one self-contained document' => sub {
    like $html,   qr/\A<!DOCTYPE html>\n<html lang="en">/, 'doctype and language';
    like $html,   qr/<meta charset="utf-8">/,              'character set';
    like $html,   qr/<title>Mutation report<\/title>/,     'title';
    like $html,   qr/<mutation-test-report-app\b/,         'the viewer element';
    unlike $html, qr/<script[^>]*\bsrc=/,                  'no script is loaded from elsewhere';
    unlike $html, qr/https?:\/\/[^"'\s]*\.js\b/,           'no script address';
};

subtest 'the viewer is the pinned build' => sub {
    my $bundle = Permutl::Report::Html::viewer_script();
    is Digest::SHA::sha256_hex( Encode::encode( 'UTF-8', $bundle ) ), Permutl::Report::Html::viewer_digest(),
      'the bundled file has the recorded digest';
    is Permutl::Report::Html::viewer_version(), '3.9.0', 'the recorded version';
    ok index( $html, $bundle ) >= 0, 'the page embeds the bundle';
};

subtest 'the report data is embedded without ending its script element' => sub {
    my ($data) = $html =~ m{<script id="report" type="application/json">(.*?)</script>}s;
    ok defined $data, 'a data element holds the report';
    unlike $data, qr/</, 'no left angle bracket appears in the data';
    is JSON::PP->new->decode($data), Permutl::Report::Json::document( $result, high => 80, low => 60 ),
      'the data decodes to the report document';
    is JSON::PP->new->decode($data)->{files}{'lib/Page.pm'}{source}, $source, 'the source survives the escaping';
};

done_testing;
