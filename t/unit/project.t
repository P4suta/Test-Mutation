use v5.36;
use Test2::V0;
use File::Path ();
use File::Temp ();
use Permutl::Project;

sub matches ( $pattern, $path ) {
    return $path =~ Permutl::Project::pattern_regex($pattern) ? 1 : 0;
}

subtest 'patterns' => sub {
    my @cases = (
        [ 'lib/**/*.pm', 'lib/A.pm',          1 ],
        [ 'lib/**/*.pm', 'lib/A/B/C.pm',      1 ],
        [ 'lib/**/*.pm', 'lib/A.pl',          0 ],
        [ 'lib/**/*.pm', 'xlib/A.pm',         0 ],
        [ 'lib/**/*.pm', 'lib/A.pm.bak',      0 ],
        [ 'lib/*.pm',    'lib/A.pm',          1 ],
        [ 'lib/*.pm',    'lib/A/B.pm',        0 ],
        [ 't/??.t',      't/01.t',            1 ],
        [ 't/??.t',      't/001.t',           0 ],
        [ '**/*.pm',     'A.pm',              1 ],
        [ '**/*.pm',     'deep/down/A.pm',    1 ],
        [ 'lib/A+B.pm',  'lib/A+B.pm',        1 ],
        [ 'lib/A+B.pm',  'lib/AAB.pm',        0 ],
        [ 'lib/**',      'lib/any/thing.txt', 1 ],
    );
    for my $case (@cases) {
        my ( $pattern, $path, $expected ) = $case->@*;
        is matches( $pattern, $path ), $expected, "$pattern against $path";
    }
};

subtest 'files' => sub {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    for my $path (
        'lib/A.pm',        'lib/Deep/B.pm', 'lib/Deep/notes.txt', 'lib/.hidden/C.pm',
        'local/lib/D.pm',  't/one.t',       't/sub/two.t',        't/lib/Helper.pm',
        '.git/hooks/E.pm', 'blib/lib/A.pm', 'script/tool.pl',     'lib/local/F.pm',
      )
    {
        my ($directory) = $path =~ m{\A(.*)/};
        File::Path::make_path("$root/$directory");
        open my $handle, '>', "$root/$path" or die "open $path: $!";
        close $handle or die "close $path: $!";
    }

    is Permutl::Project::files( $root, ['lib/**/*.pm'], [] ), [ 'lib/A.pm', 'lib/Deep/B.pm', 'lib/local/F.pm' ],
      'sources, without hidden directories';
    is Permutl::Project::files( $root, ['t/**/*.t'], [] ), [ 't/one.t', 't/sub/two.t' ], 'tests';
    is Permutl::Project::files( $root, ['lib/**/*.pm'], ['lib/Deep/**'] ), [ 'lib/A.pm', 'lib/local/F.pm' ],
      'an exclude pattern';
    is Permutl::Project::files( $root, [ 'lib/*.pm', 'script/*.pl', 'lib/*.pm' ], [] ),
      [ 'lib/A.pm', 'script/tool.pl' ],
      'several patterns, each file once';
    is Permutl::Project::files( $root, ['**/*.pm'], [] ),
      [ 'lib/A.pm', 'lib/Deep/B.pm', 'lib/local/F.pm', 't/lib/Helper.pm' ],
      'a pattern without a directory skips vendor directories at the root';
    is Permutl::Project::files( $root, ['missing/**/*.pm'], [] ),      [], 'a directory that does not exist';
    is warnings { Permutl::Project::files( $root, ['**/*.pm'], [] ) }, [], 'a walk from the root raises no warning';
};

subtest 'processors reads the count from the text of the platform' => sub {
    my $cpuinfo = join "\n", "processor\t: 0", 'model name : A', 'Processor : B', "processor\t: 1", 'processor: 2', q{};
    my @cases   = (
        [ 'the processor lines of cpuinfo',         $cpuinfo,           undef,    3 ],
        [ 'cpuinfo before sysctl',                  $cpuinfo,           "8\n",    3 ],
        [ 'sysctl when cpuinfo is absent',          undef,              "8\n",    8 ],
        [ 'sysctl when cpuinfo lists no processor', "model name : A\n", "12\n",   12 ],
        [ 'one processor',                          undef,              "1\n",    1 ],
        [ 'a number with a suffix',                 undef,              "4 x\n",  4 ],
        [ 'no source',                              undef,              undef,    1 ],
        [ 'a count of zero',                        undef,              "0\n",    1 ],
        [ 'text without a number',                  undef,              "none\n", 1 ],
        [ 'a number after other text',              undef,              "x 4\n",  1 ],
        [ 'an empty answer',                        undef,              q{},      1 ],
    );
    for my $case (@cases) {
        my ( $name, $text, $answer, $expected ) = $case->@*;
        is Permutl::Project::processors( cpuinfo => $text, sysctl => $answer ), $expected, $name;
    }
};

subtest 'cpu_count asks the platform' => sub {
    my $expected = qx{getconf _NPROCESSORS_ONLN 2>/dev/null};
    skip_all 'getconf reports no processor count' if $expected !~ /\A[1-9][0-9]*\n\z/;
    is Permutl::Project::cpu_count(), $expected + 0, 'the count of the platform';
};

subtest 'default_jobs leaves one processor free' => sub {
    is [ map { Permutl::Project::default_jobs($_) } 1, 2, 3, 8 ], [ 1, 1, 2, 7 ], 'one less, and never below one';
};

done_testing;
